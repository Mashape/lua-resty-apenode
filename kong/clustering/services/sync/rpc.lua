local _M = {}
local _MT = { __index = _M, }


local txn = require("resty.lmdb.transaction")
local declarative = require("kong.db.declarative")
local constants = require("kong.constants")
local concurrency = require("kong.concurrency")
local isempty = require("table.isempty")
local events = require("kong.runloop.events")


local insert_entity_for_txn = declarative.insert_entity_for_txn
local delete_entity_for_txn = declarative.delete_entity_for_txn
local DECLARATIVE_HASH_KEY = constants.DECLARATIVE_HASH_KEY
local CLUSTERING_DATA_PLANES_LATEST_VERSION_KEY = constants.CLUSTERING_DATA_PLANES_LATEST_VERSION_KEY
local DECLARATIVE_EMPTY_CONFIG_HASH = constants.DECLARATIVE_EMPTY_CONFIG_HASH
local DECLARATIVE_DEFAULT_WORKSPACE_KEY = constants.DECLARATIVE_DEFAULT_WORKSPACE_KEY
local CLUSTERING_SYNC_STATUS = constants.CLUSTERING_SYNC_STATUS
local SYNC_MUTEX_OPTS = { name = "get_delta", timeout = 0, }
local MAX_RETRY = 5


local assert = assert
local ipairs = ipairs
local ngx_null = ngx.null
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG


function _M.new(strategy)
  local self = {
    strategy = strategy,
  }

  return setmetatable(self, _MT)
end


local function empty_sync_result()
  return { default = { deltas = {}, wipe = false, }, }
end


local function full_sync_result()
  local deltas, err = declarative.export_config_sync()
  if not deltas then
    return nil, err
  end

  -- wipe dp lmdb, full sync
  return { default = { deltas = deltas, wipe = true, }, }
end


local function get_current_version()
  return declarative.get_current_hash() or DECLARATIVE_EMPTY_CONFIG_HASH
end


function _M:init_cp(manager)
  local purge_delay = manager.conf.cluster_data_plane_purge_delay

  -- CP
  -- Method: kong.sync.v2.get_delta
  -- Params: versions: list of current versions of the database
  -- example: { default = { version = "1000", }, }
  manager.callbacks:register("kong.sync.v2.get_delta", function(node_id, current_versions)
    ngx_log(ngx_DEBUG, "[kong.sync.v2] config push (connected client)")

    local rpc_peers
    if kong.rpc then
      rpc_peers = kong.rpc:get_peers()
    end

    local default_namespace = current_versions.default

    if not default_namespace then
      return nil, "default namespace does not exist inside params"
    end

    -- { default = { version = "1000", }, }
    local default_namespace_version = default_namespace.version
    local node_info = assert(kong.rpc:get_peer_info(node_id))

    -- follow update_sync_status() in control_plane.lua
    local ok, err = kong.db.clustering_data_planes:upsert({ id = node_id }, {
      last_seen = ngx.time(),
      hostname = node_id,
      ip = node_info.ip,   -- get the correct ip
      version = node_info.version,    -- get from rpc call
      labels = node_info.labels,    -- get from rpc call
      cert_details = node_info.cert_details,  -- get from rpc call
      sync_status = CLUSTERING_SYNC_STATUS.NORMAL,
      config_hash = default_namespace_version,
      rpc_capabilities = rpc_peers and rpc_peers[node_id] or {},
    }, { ttl = purge_delay, no_broadcast_crud_event = true, })
    if not ok then
      ngx_log(ngx_ERR, "unable to update clustering data plane status: ", err)
    end

    local latest_version, err = self.strategy:get_latest_version()
    if not latest_version then
      return nil, err
    end

    --  string comparison effectively does the same as number comparison
    if not self.strategy:is_valid_version(default_namespace_version) or
       default_namespace_version < latest_version then
      return full_sync_result()
    end

    return empty_sync_result()
  end)
end


function _M:init_dp(manager)
  local kong_shm = ngx.shared.kong
  -- DP
  -- Method: kong.sync.v2.notify_new_version
  -- Params: new_versions: list of namespaces and their new versions, like:
  -- { default = { new_version = "1000", }, }
  manager.callbacks:register("kong.sync.v2.notify_new_version", function(node_id, new_versions)
    -- TODO: currently only default is supported, and anything else is ignored
    local default_new_version = new_versions.default
    if not default_new_version then
      return nil, "default namespace does not exist inside params"
    end

    local version = default_new_version.new_version
    if not version then
      return nil, "'new_version' key does not exist"
    end

    local lmdb_ver = get_current_version()
    if lmdb_ver < version then
      -- set lastest version to shm
      kong_shm:set(CLUSTERING_DATA_PLANES_LATEST_VERSION_KEY, version)
      return self:sync_once()
    end

    return true
  end)
end


function _M:init(manager, is_cp)
  if is_cp then
    self:init_cp(manager)
  else
    self:init_dp(manager)
  end
end


-- check if rpc connection is ready
local function is_rpc_ready()
  -- TODO: find a better way to detect when the RPC layer, including caps list,
  --       has been fully initialized, instead of waiting for up to 5.5 seconds
  for i = 1, 10 do
    local res = kong.rpc:get_peers()

    -- control_plane is ready
    if res["control_plane"] then
      return true
    end

    -- retry later
    ngx.sleep(0.1 * i)
  end
end


local function do_sync()
  if not is_rpc_ready() then
    return nil, "rpc is not ready"
  end

  local msg = { default = { version = get_current_version(), }, }

  local ns_deltas, err = kong.rpc:call("control_plane", "kong.sync.v2.get_delta", msg)
  if not ns_deltas then
    ngx_log(ngx_ERR, "sync get_delta error: ", err)
    return true
  end

  -- ns_deltas should look like:
  -- { default = { deltas = { ... }, wipe = true, }, }

  local ns_delta = ns_deltas.default
  if not ns_delta then
    return nil, "default namespace does not exist inside params"
  end

  local deltas = ns_delta.deltas

  if not deltas then
    return nil, "sync get_delta error: deltas is null"
  end

  if isempty(deltas) then
    -- no delta to sync
    return true
  end

  -- we should find the correct default workspace
  -- and replace the old one with it
  local default_ws_changed
  for _, delta in ipairs(deltas) do
    if delta.type == "workspaces" and delta.entity.name == "default" and
      kong.default_workspace ~= delta.entity.id
    then
      kong.default_workspace = delta.entity.id
      default_ws_changed = true
      break
    end
  end
  assert(type(kong.default_workspace) == "string")

  local t = txn.begin(512)

  local wipe = ns_delta.wipe
  if wipe then
    t:db_drop(false)
  end

  local db = kong.db

  local version = ""
  local opts = {}
  local crud_events = {}
  local crud_events_n = 0

  -- delta should look like:
  -- { type = ..., entity = { ... }, version = "1", ws_id = ..., }
  for _, delta in ipairs(deltas) do
    local delta_version = delta.version
    local delta_type = delta.type
    local delta_entity = delta.entity
    local ev

    -- delta should have ws_id to generate the correct lmdb key
    -- if entity is workspaceable
    -- set the correct workspace for item
    opts.workspace = delta.ws_id

    if delta_entity ~= nil and delta_entity ~= ngx_null then
      -- upsert the entity
      -- does the entity already exists?
      local old_entity, err = db[delta_type]:select(delta_entity)
      if err then
        return nil, err
      end

      -- If we will wipe lmdb, we don't need to delete it from lmdb.
      if old_entity and not wipe then
        local res, err = delete_entity_for_txn(t, delta_type, old_entity, opts)
        if not res then
          return nil, err
        end
      end

      local res, err = insert_entity_for_txn(t, delta_type, delta_entity, opts)
      if not res then
        return nil, err
      end

      ngx_log(ngx_DEBUG,
              "[kong.sync.v2] update entity",
              ", version: ", delta_version,
              ", type: ", delta_type)

      -- wipe the whole lmdb, should not have events
      if not wipe then
        ev = { delta_type, old_entity and "update" or "create", delta_entity, old_entity, }
      end

    else
      -- delete the entity, opts for getting correct lmdb key
      local old_entity, err = db[delta_type]:select(delta.pk, opts) -- composite key
      if err then
        return nil, err
      end

      -- If we will wipe lmdb, we don't need to delete it from lmdb.
      if old_entity and not wipe then
        local res, err = delete_entity_for_txn(t, delta_type, old_entity, opts)
        if not res then
          return nil, err
        end
      end

      ngx_log(ngx_DEBUG,
              "[kong.sync.v2] delete entity",
              ", version: ", delta_version,
              ", type: ", delta_type)

      -- wipe the whole lmdb, should not have events
      if not wipe then
        ev = { delta_type, "delete", old_entity, }
      end
    end -- if delta_entity ~= nil and delta_entity ~= ngx_null

    -- wipe the whole lmdb, should not have events
    if not wipe then
      crud_events_n = crud_events_n + 1
      crud_events[crud_events_n] = ev
    end

    -- delta.version should not be nil or ngx.null
    assert(type(delta_version) == "string")

    if delta_version ~= version then
      version = delta_version
    end
  end -- for _, delta

  -- store current sync version
  t:set(DECLARATIVE_HASH_KEY, version)

  -- store the correct default workspace uuid
  if default_ws_changed then
    t:set(DECLARATIVE_DEFAULT_WORKSPACE_KEY, kong.default_workspace)
  end

  local ok, err = t:commit()
  if not ok then
    return nil, err
  end

  if wipe then
    kong.core_cache:purge()
    kong.cache:purge()

    -- Trigger other workers' callbacks like reconfigure_handler.
    --
    -- Full sync could rebuild route, plugins and balancer route, so their
    -- hashes are nil.
    local reconfigure_data = { kong.default_workspace, nil, nil, nil, }
    local ok, err = events.declarative_reconfigure_notify(reconfigure_data)
    if not ok then
      return nil, err
    end

  else
    for _, event in ipairs(crud_events) do
      -- delta_type, crud_event_type, delta.entity, old_entity
      db[event[1]]:post_crud_event(event[2], event[3], event[4])
    end
  end

  return true
end


local function sync_handler(premature)
  if premature then
    return
  end

  local res, err = concurrency.with_worker_mutex(SYNC_MUTEX_OPTS, do_sync)
  if not res and err ~= "timeout" then
    ngx_log(ngx_ERR, "unable to create worker mutex and sync: ", err)
  end
end


local sync_once_impl


local function start_sync_once_timer(retry_count)
  local ok, err = kong.timer:at(0, sync_once_impl, retry_count or 0)
  if not ok then
    return nil, err
  end

  return true
end


function sync_once_impl(premature, retry_count)
  if premature then
    return
  end

  sync_handler()

  -- check if "kong.sync.v2.notify_new_version" updates the latest version

  local latest_notified_version = ngx.shared.kong:get(CLUSTERING_DATA_PLANES_LATEST_VERSION_KEY)
  if not latest_notified_version then
    ngx_log(ngx_DEBUG, "no version notified yet")
    return
  end

  local current_version = get_current_version()
  if current_version >= latest_notified_version then
    ngx_log(ngx_DEBUG, "version already updated")
    return
  end

  -- retry if the version is not updated
  retry_count = retry_count or 0
  if retry_count > MAX_RETRY then
    ngx_log(ngx_ERR, "sync_once retry count exceeded. retry_count: ", retry_count)
    return
  end

  return start_sync_once_timer(retry_count + 1)
end


function _M:sync_once(delay)
  local name = "rpc_sync_v2_once"
  local is_managed = kong.timer:is_managed(name)

  -- we are running a sync handler
  if is_managed then
    return true
  end

  local ok, err = kong.timer:named_at(name, delay or 0, sync_once_impl, 0)
  if not ok then
    return nil, err
  end

  return true
end


function _M:sync_every(delay, stop)
  local name = "rpc_sync_v2_every"
  local is_managed = kong.timer:is_managed(name)

  -- we only start or stop once

  if stop then
    if is_managed then
      assert(kong.timer:cancel(name))
    end
    return true
  end

  if is_managed then
    return true
  end

  local ok, err = kong.timer:named_every(name, delay, sync_handler)
  if not ok then
    return nil, err
  end

  return true
end


return _M
