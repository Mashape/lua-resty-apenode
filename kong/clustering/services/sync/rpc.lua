local _M = {}
local _MT = { __index = _M, }


local txn = require("resty.lmdb.transaction")
local declarative = require("kong.db.declarative")
local constants = require("kong.constants")
local concurrency = require("kong.concurrency")
local isempty = require("table.isempty")
local events = require("kong.runloop.events")
local EMPTY = require("kong.tools.table").EMPTY


local validate_deltas = require("kong.clustering.services.sync.validate").validate_deltas
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
local ngx_WARN = ngx.WARN
local ngx_INFO = ngx.INFO
local ngx_DEBUG = ngx.DEBUG


function _M.new(strategy)
  local self = {
    strategy = strategy,
  }

  return setmetatable(self, _MT)
end


local function empty_sync_result()
  return { default = { deltas = {}, full_sync = false, }, }
end


local function full_sync_result()
  local deltas, err = declarative.export_config_sync()
  if not deltas then
    return nil, err
  end

  -- wipe dp lmdb, full sync
  return { default = { deltas = deltas, full_sync = true, }, }
end


local function get_current_version()
  return declarative.get_current_hash() or DECLARATIVE_EMPTY_CONFIG_HASH
end


function _M:init_cp(manager)
  local purge_delay = manager.conf.cluster_data_plane_purge_delay

  -- CP
  -- Method: kong.sync.v2.notify_validation_error
  -- Params: msg: error message reported by DP
  -- example: { version = <latest version of deltas>, error = <flatten error>, }
  manager.callbacks:register("kong.sync.v2.notify_validation_error", function(node_id, msg)
    ngx_log(ngx_DEBUG, "[kong.sync.v2] received validation error")
    -- TODO: We need a better error handling method, it might report this error
    -- to Konnect or or log it locally.
    return true
  end)

  -- CP
  -- Method: kong.sync.v2.get_delta
  -- Params: versions: list of current versions of the database
  -- example: { default = { version = "1000", }, }
  manager.callbacks:register("kong.sync.v2.get_delta", function(node_id, current_versions)
    kong.log.trace("[kong.sync.v2] config push (connected client)")

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
      rpc_capabilities = rpc_peers and rpc_peers[node_id] or EMPTY,
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
       default_namespace_version ~= latest_version then
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

    ngx_log(ngx_DEBUG, "no sync runs, version is ", version)

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


-- tell cp that the deltas validation failed
local function notify_error(ver, err_t)
  local msg = {
    version = ver or "v02_deltas_have_no_latest_version_field",
    error = err_t,
  }

  local ok, err = kong.rpc:notify("control_plane",
                                  "kong.sync.v2.notify_validation_error",
                                  msg)
  if not ok then
    ngx_log(ngx_ERR, "notifying validation errors failed: ", err)
  end
end


-- tell cp we already updated the version by rpc notification
local function update_status(ver)
  local msg = { default = { version = ver, }, }

  local ok, err = kong.rpc:notify("control_plane", "kong.sync.v2.get_delta", msg)
  if not ok then
    ngx_log(ngx_ERR, "update status notification failed: ", err)
  end
end


local function lmdb_update(db, t, delta, opts, is_full_sync)
  local delta_type = delta.type
  local delta_entity = delta.entity

  -- upsert the entity
  -- delete if exists
  local old_entity, err = db[delta_type]:select(delta_entity)
  if err then
    return nil, err
  end

  if old_entity and not is_full_sync then
    local res, err = delete_entity_for_txn(t, delta_type, old_entity, opts)
    if not res then
      return nil, err
    end
  end

  local res, err = insert_entity_for_txn(t, delta_type, delta_entity, opts)
  if not res then
    return nil, err
  end

  if is_full_sync then
    return nil
  end

  return { delta_type, old_entity and "update" or "create", delta_entity, old_entity, }
end


local function lmdb_delete(db, t, delta, opts, is_full_sync)
  local delta_type = delta.type

  local old_entity, err = db[delta_type]:select(delta.pk, opts)
  if err then
    return nil, err
  end

  -- full sync requires extra torlerance for missing entities
  if not old_entity then
    return nil
  end

  local res, err = delete_entity_for_txn(t, delta_type, old_entity, opts)
  if not res then
    return nil, err
  end

  if is_full_sync then
    return nil
  end

  return { delta_type, "delete", old_entity, }
end


local function preprocess_deltas(deltas)
  local default_ws_changed

  for _, delta in ipairs(deltas) do
    local delta_type = delta.type
    local delta_entity = delta.entity

    -- Update default workspace if delta is for workspace update
    if delta_type == "workspaces" and
      delta_entity ~= nil and
      delta_entity ~= ngx_null and
      delta_entity.name == "default" and
      kong.default_workspace ~= delta_entity.id
    then
      kong.default_workspace = delta_entity.id
      default_ws_changed = true
      break
    end
  end -- for _, delta

  assert(type(kong.default_workspace) == "string")

  return default_ws_changed
end


local function do_sync()
  if not is_rpc_ready() then
    return nil, "rpc is not ready"
  end

  local current_version = get_current_version()
  local msg = { default = { version = current_version, }, }

  local ns_deltas, err = kong.rpc:call("control_plane", "kong.sync.v2.get_delta", msg)
  if not ns_deltas then
    ngx_log(ngx_ERR, "sync get_delta error: ", err)
    return true
  end

  -- ns_deltas should look like:
  -- { default = { deltas = { ... }, full_sync = true, }, }

  local ns_delta = ns_deltas.default
  if not ns_delta then
    return nil, "default namespace does not exist inside params"
  end

  local is_full_sync = ns_delta.full_sync or ns_delta.wipe
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
  local default_ws_changed = preprocess_deltas(deltas)

  -- validate deltas and set the default values
  local ok, err, err_t = validate_deltas(deltas, is_full_sync)
  if not ok then
    notify_error(ns_delta.latest_version, err_t)
    return nil, err
  end

  local t = txn.begin(512)

  if is_full_sync then
    ngx_log(ngx_INFO, "[kong.sync.v2] full sync begins")

    t:db_drop(false)
  end

  local db = kong.db

  local version = current_version
  local opts = {}
  local crud_events = {}
  local crud_events_n = 0

  -- delta should look like:
  -- { type = ..., entity = { ... }, version = "1", ws_id = ..., }
  for _, delta in ipairs(deltas) do
    local delta_version = delta.version
    local delta_type = delta.type
    local delta_entity = delta.entity

    -- delta should have ws_id to generate the correct lmdb key
    -- if entity is workspaceable
    -- set the correct workspace for item
    opts.workspace = delta.ws_id

    local is_update = delta_entity ~= nil and delta_entity ~= ngx_null
    local operation_name = is_update and "update" or "delete"
    local operation = is_update and lmdb_update or lmdb_delete

    -- log the operation before executing it, so when failing we know what entity caused it
    ngx_log(ngx_DEBUG,
            "[kong.sync.v2] ", operation_name, " entity",
            ", version: ", delta_version,
            ", type: ", delta_type)

    local ev, err = operation(db, t, delta, opts, is_full_sync)
    if err then
      return nil, err
    end

    if ev then
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

  -- record the default workspace into LMDB for any of the following case:
  -- * the default workspace has been changed
  -- * full sync
  if default_ws_changed or is_full_sync then
    t:set(DECLARATIVE_DEFAULT_WORKSPACE_KEY, kong.default_workspace)
  end

  local ok, err = t:commit()
  if not ok then
    return nil, "failed to commit transaction: " .. err
  end

  if is_full_sync then
    ngx_log(ngx_INFO, "[kong.sync.v2] full sync ends")

    kong.core_cache:purge()
    kong.cache:purge()

    -- Trigger other workers' callbacks like reconfigure_handler.
    --
    -- Full sync could rebuild route, plugins and balancer route, so their
    -- hashes are nil.
    local reconfigure_data = { kong.default_workspace, nil, nil, nil, }
    return events.declarative_reconfigure_notify(reconfigure_data)
  end

  for _, event in ipairs(crud_events) do
    -- delta_type, crud_event_type, delta.entity, old_entity
    db[event[1]]:post_crud_event(event[2], event[3], event[4])
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

  return res, err
end


local function sync_once_impl(premature, retry_count)
  if premature then
    return
  end

  local version_before_sync = get_current_version()

  local _, err = sync_handler()

  -- check if "kong.sync.v2.notify_new_version" updates the latest version

  local latest_notified_version = ngx.shared.kong:get(CLUSTERING_DATA_PLANES_LATEST_VERSION_KEY)
  if not latest_notified_version then
    ngx_log(ngx_DEBUG, "no version notified yet")
    return
  end

  local current_version = get_current_version()
  if current_version >= latest_notified_version then
    ngx_log(ngx_DEBUG, "version already updated")

    -- version changed, we should update status
    if version_before_sync ~= current_version then
      update_status(current_version)
    end

    return
  end

  -- retry if the version is not updated
  retry_count = retry_count or 0

  if retry_count >= MAX_RETRY then
    ngx_log(ngx_WARN, "sync_once retry count exceeded. retry_count: ", retry_count)
    return
  end

  -- we do not count a timed out sync. just retry
  if err ~= "timeout" then
    retry_count = retry_count + 1
  end

  -- in some cases, the new spawned timer will be switched to immediately,
  -- preventing the coroutine who possesses the mutex to run
  -- to let other coroutines has a chance to run
  local ok, err = kong.timer:at(0.1, sync_once_impl, retry_count)
  -- this is a workaround for a timerng bug, where tail recursion causes failure
  -- ok could be a string so let's convert it to boolean
  if not ok then
    return nil, err
  end
  return true
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
