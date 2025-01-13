-- Kong, the biggest ape in town
--
--     /\  ____
--     <> ( oo )
--     <>_| ^^ |_
--     <>   @    \
--    /~~\ . . _ |
--   /~~~~\    | |
--  /~~~~~~\/ _| |
--  |[][][]/ / [m]
--  |[][][[m]
--  |[][][]|
--  |[][][]|
--  |[][][]|
--  |[][][]|
--  |[][][]|
--  |[][][]|
--  |[][][]|
--  |[][][]|
--  |[|--|]|
--  |[|  |]|
--  ========
-- ==========
-- |[[    ]]|
-- ==========

local pcall = pcall


assert(package.loaded["resty.core"], "lua-resty-core must be loaded; make " ..
                                     "sure 'lua_load_resty_core' is not "..
                                     "disabled.")


local constants = require "kong.constants"
do
  -- let's ensure the required shared dictionaries are
  -- declared via lua_shared_dict in the Nginx conf

  for _, dict in ipairs(constants.DICTS) do
    if not ngx.shared[dict] then
      return error("missing shared dict '" .. dict .. "' in Nginx "          ..
                   "configuration, are you using a custom template? "        ..
                   "Make sure the 'lua_shared_dict " .. dict .. " [SIZE];' " ..
                   "directive is defined.")
    end
  end

  -- if we're running `nginx -t` then don't initialize
  if os.getenv("KONG_NGINX_CONF_CHECK") then
    return {
      init = function() end,
    }
  end
end


require("kong.globalpatches")()


local kong_global = require "kong.global"
local PHASES = kong_global.phases


_G.kong = kong_global.new() -- no versioned PDK for plugins for now


local DB = require "kong.db"
local meta = require "kong.meta"
local lapis = require "lapis"
local runloop = require "kong.runloop.handler"
local stream_api = require "kong.tools.stream_api"
local declarative = require "kong.db.declarative"
local ngx_balancer = require "ngx.balancer"
local kong_resty_ctx = require "kong.resty.ctx"
local certificate = require "kong.runloop.certificate"
local concurrency = require "kong.concurrency"
local cache_warmup = require "kong.cache.warmup"
local balancer = require "kong.runloop.balancer"
local kong_error_handlers = require "kong.error_handlers"
local plugin_servers = require "kong.runloop.plugin_servers"
local lmdb_txn = require "resty.lmdb.transaction"
local instrumentation = require "kong.observability.tracing.instrumentation"
local process = require "ngx.process"
local tablepool = require "tablepool"
local table_new = require "table.new"
local emmy_debugger = require "kong.tools.emmy_debugger"
local get_ctx_table = require("resty.core.ctx").get_ctx_table
local admin_gui = require "kong.admin_gui"
local wasm = require "kong.runloop.wasm"
local reports = require "kong.reports"
local pl_file = require "pl.file"
local req_dyn_hook = require "kong.dynamic_hook"
local uuid = require("kong.tools.uuid").uuid
local kong_time = require("kong.tools.time")


local kong             = kong
local ngx              = ngx
local var              = ngx.var
local arg              = ngx.arg
local header           = ngx.header
local ngx_log          = ngx.log
local ngx_ALERT        = ngx.ALERT
local ngx_CRIT         = ngx.CRIT
local ngx_ERR          = ngx.ERR
local ngx_WARN         = ngx.WARN
local ngx_NOTICE       = ngx.NOTICE
local ngx_INFO         = ngx.INFO
local ngx_DEBUG        = ngx.DEBUG
local is_http_module   = ngx.config.subsystem == "http"
local is_stream_module = ngx.config.subsystem == "stream"
local worker_id        = ngx.worker.id
local type             = type
local error            = error
local ipairs           = ipairs
local assert           = assert
local tostring         = tostring
local coroutine        = coroutine
local fetch_table      = tablepool.fetch
local release_table    = tablepool.release
local get_last_failure = ngx_balancer.get_last_failure
local set_current_peer = ngx_balancer.set_current_peer
local set_timeouts     = ngx_balancer.set_timeouts
local set_more_tries   = ngx_balancer.set_more_tries
local enable_keepalive = ngx_balancer.enable_keepalive


local time_ns            = kong_time.time_ns
local get_now_ms         = kong_time.get_now_ms
local get_start_time_ms  = kong_time.get_start_time_ms
local get_updated_now_ms = kong_time.get_updated_now_ms


local req_dyn_hook_run_hook        = req_dyn_hook.run_hook
local req_dyn_hook_is_group_enabled = req_dyn_hook.is_group_enabled


local DECLARATIVE_LOAD_KEY = constants.DECLARATIVE_LOAD_KEY


local CTX_NS = "ctx"
local CTX_NARR = 0
local CTX_NREC = 50 -- normally Kong has ~32 keys in ctx


local declarative_entities
local declarative_meta
local declarative_hash
local schema_state


local stash_init_worker_error
local log_init_worker_errors
do
  local init_worker_errors
  local init_worker_errors_str
  local ctx_k = {}


  stash_init_worker_error = function(err)
    if err == nil then
      return
    end

    err = tostring(err)

    if not init_worker_errors then
      init_worker_errors = {}
    end

    table.insert(init_worker_errors, err)
    init_worker_errors_str = table.concat(init_worker_errors, ", ")

    return ngx_log(ngx_CRIT, "worker initialization error: ", err,
                             "; this node must be restarted")
  end


  log_init_worker_errors = function(ctx)
    if not init_worker_errors_str or ctx[ctx_k] then
      return
    end

    ctx[ctx_k] = true

    return ngx_log(ngx_ALERT, "unsafe request processing due to earlier ",
                              "initialization errors; this node must be ",
                              "restarted (", init_worker_errors_str, ")")
  end
end


local is_data_plane
local is_control_plane
local is_dbless
do
  is_data_plane = function(config)
    return config.role == "data_plane"
  end


  is_control_plane = function(config)
    return config.role == "control_plane"
  end


  is_dbless = function(config)
    return config.database == "off"
  end
end


local reset_kong_shm
do
  local preserve_keys = {
    "kong:node_id",
    constants.DYN_LOG_LEVEL_KEY,
    constants.DYN_LOG_LEVEL_TIMEOUT_AT_KEY,
    "events:requests",
    "events:requests:http",
    "events:requests:https",
    "events:requests:h2c",
    "events:requests:h2",
    "events:requests:grpc",
    "events:requests:grpcs",
    "events:requests:ws",
    "events:requests:wss",
    "events:requests:go_plugins",
    "events:km:visit",
    "events:streams",
    "events:streams:tcp",
    "events:streams:tls",
    "events:ai:response_tokens",
    "events:ai:prompt_tokens",
    "events:ai:requests",
  }

  reset_kong_shm = function(config)
    local kong_shm = ngx.shared.kong

    local preserved = {}

    if is_dbless(config) then
      if not (config.declarative_config or config.declarative_config_string) then
        preserved[DECLARATIVE_LOAD_KEY] = kong_shm:get(DECLARATIVE_LOAD_KEY)
      end
    end

    for _, key in ipairs(preserve_keys) do
      preserved[key] = kong_shm:get(key) -- ignore errors
    end

    kong_shm:flush_all()
    for key, value in pairs(preserved) do
      kong_shm:set(key, value)
    end
    kong_shm:flush_expired(0)
  end
end


local function setup_plugin_context(ctx, plugin, conf)
  if plugin.handler._go then
    ctx.ran_go_plugin = true
  end

  kong_global.set_named_ctx(kong, "plugin", plugin.handler, ctx)
  kong_global.set_namespaced_log(kong, plugin.name, ctx)
  ctx.plugin_id = conf.__plugin_id
end


local function reset_plugin_context(ctx, old_ws)
  kong_global.reset_log(kong, ctx)

  if old_ws then
    ctx.workspace = old_ws
  end
end


local function execute_init_worker_plugins_iterator(plugins_iterator, ctx)
  local iterator, plugins = plugins_iterator:get_init_worker_iterator()
  if not iterator then
    return
  end

  local errors

  for _, plugin in iterator, plugins, 0 do
    kong_global.set_namespaced_log(kong, plugin.name, ctx)

    -- guard against failed handler in "init_worker" phase only because it will
    -- cause Kong to not correctly initialize and can not be recovered automatically.
    local ok, err = pcall(plugin.handler.init_worker, plugin.handler)
    if not ok then
      errors = errors or {}
      errors[#errors + 1] = {
        plugin = plugin.name,
        err = err,
      }
    end

    kong_global.reset_log(kong, ctx)
  end

  return errors
end


local function execute_global_plugins_iterator(plugins_iterator, phase, ctx)
  if not plugins_iterator.has_plugins then
    return
  end

  local iterator, plugins = plugins_iterator:get_global_iterator(phase)
  if not iterator then
    return
  end

  local old_ws = ctx.workspace
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:plugin_iterator")
  end

  for _, plugin, configuration in iterator, plugins, 0 do
    local span
    if phase == "rewrite" then
      span = instrumentation.plugin_rewrite(plugin)
    end

    setup_plugin_context(ctx, plugin, configuration)

    if has_timing then
      req_dyn_hook_run_hook("timing", "before:plugin", plugin.name, ctx.plugin_id)
    end

    plugin.handler[phase](plugin.handler, configuration)

    if has_timing then
      req_dyn_hook_run_hook("timing", "after:plugin")
    end

    reset_plugin_context(ctx, old_ws)

    if span then
      span:finish()
    end
  end

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:plugin_iterator")
  end
end


local function execute_collecting_plugins_iterator(plugins_iterator, phase, ctx)
  if not plugins_iterator.has_plugins then
    return
  end

  local iterator, plugins = plugins_iterator:get_collecting_iterator(ctx)
  if not iterator then
    return
  end

  ctx.delay_response = true

  local old_ws = ctx.workspace
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:plugin_iterator")
  end

  for _, plugin, configuration in iterator, plugins, 0 do
    if not ctx.delayed_response then
      local span
      if phase == "access" then
        span = instrumentation.plugin_access(plugin)
      end

      setup_plugin_context(ctx, plugin, configuration)

      if has_timing then
        req_dyn_hook_run_hook( "timing", "before:plugin", plugin.name, ctx.plugin_id)
      end

      local co = coroutine.create(plugin.handler[phase])
      local cok, cerr = coroutine.resume(co, plugin.handler, configuration)

      if has_timing then
        req_dyn_hook_run_hook("timing", "after:plugin")
      end

      if not cok then
        -- set tracing error
        if span then
          span:record_error(cerr)
          span:set_status(2)
        end

        kong.log.err(cerr)
        ctx.delayed_response = {
          status_code = 500,
          content = { message  = "An unexpected error occurred" },
        }

        -- plugin that throws runtime exception should be marked as `error`
        ctx.KONG_UNEXPECTED = true
      end

      reset_plugin_context(ctx, old_ws)

      -- ends tracing span
      if span then
        span:finish()
      end
    end
  end

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:plugin_iterator")
  end

  ctx.delay_response = nil
end


local function execute_collected_plugins_iterator(plugins_iterator, phase, ctx)
  if not plugins_iterator.has_plugins then
    return
  end

  local iterator, plugins = plugins_iterator:get_collected_iterator(phase, ctx)
  if not iterator then
    return
  end

  local old_ws = ctx.workspace
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:plugin_iterator")
  end

  for _, plugin, configuration in iterator, plugins, 0 do
    local span
    if phase == "header_filter" then
      span = instrumentation.plugin_header_filter(plugin)
    end

    setup_plugin_context(ctx, plugin, configuration)

    if has_timing then
      req_dyn_hook_run_hook("timing", "before:plugin", plugin.name, ctx.plugin_id)
    end

    plugin.handler[phase](plugin.handler, configuration)

    if has_timing then
      req_dyn_hook_run_hook("timing", "after:plugin")
    end

    reset_plugin_context(ctx, old_ws)

    if span then
      span:finish()
    end
  end

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:plugin_iterator")
  end
end


local function execute_cache_warmup(kong_config)
  if is_dbless(kong_config) then
    return true
  end

  if worker_id() == 0 then
    local ok, err = cache_warmup.execute(kong_config.db_cache_warmup_entities)
    if not ok then
      return nil, err
    end
  end

  return true
end


local function flush_delayed_response(ctx)
  ctx.delay_response = nil
  ctx.buffered_proxying = nil

  if type(ctx.delayed_response_callback) == "function" then
    ctx.delayed_response_callback(ctx)
    return -- avoid tail call
  end

  local dr = ctx.delayed_response
  local message = dr.content and dr.content.message or dr.content
  kong.response.error(dr.status_code, message, dr.headers)
end


local function has_declarative_config(kong_config)
  local declarative_config = kong_config.declarative_config
  local declarative_config_string = kong_config.declarative_config_string

  return declarative_config or declarative_config_string,
         declarative_config ~= nil,         -- is filename
         declarative_config_string ~= nil   -- is string
end


local function parse_declarative_config(kong_config, dc)
  local declarative_config, is_file, is_string = has_declarative_config(kong_config)

  local entities, err, _, meta, hash
  if not declarative_config then
    -- return an empty configuration,
    -- including only the default workspace
    entities, _, _, meta, hash = dc:parse_table({ _format_version = "3.0" })
    return entities, nil, meta, hash
  end

  if is_file then
    entities, err, _, meta, hash = dc:parse_file(declarative_config)

  elseif is_string then
    entities, err, _, meta, hash = dc:parse_string(declarative_config)
  end

  if not entities then
    if is_file then
      return nil, "error parsing declarative config file " ..
                  declarative_config .. ":\n" .. err

    elseif is_string then
      return nil, "error parsing declarative string " ..
                  declarative_config .. ":\n" .. err
    end
  end

  return entities, nil, meta, hash
end


local function declarative_init_build()
  local default_ws = kong.db.workspaces:select_by_name("default")
  kong.default_workspace = default_ws and default_ws.id or kong.default_workspace

  local ok, err = runloop.build_plugins_iterator("init")
  if not ok then
    return nil, "error building initial plugins iterator: " .. err
  end

  ok, err = runloop.build_router("init")
  if not ok then
    return nil, "error building initial router: " .. err
  end

  return true
end


local function load_declarative_config(kong_config, entities, meta, hash)
  local opts = {
    name = "declarative_config",
  }

  local kong_shm = ngx.shared.kong
  local ok, err = concurrency.with_worker_mutex(opts, function()
    local value = kong_shm:get(DECLARATIVE_LOAD_KEY)
    if value then
      return true
    end
    local ok, err = declarative.load_into_cache(entities, meta, hash)
    if not ok then
      return nil, err
    end

    if kong_config.declarative_config then
      kong.log.notice("declarative config loaded from ",
                      kong_config.declarative_config)
    end

    ok, err = kong_shm:safe_set(DECLARATIVE_LOAD_KEY, true)
    if not ok then
      kong.log.warn("failed marking declarative_config as loaded: ", err)
    end

    return true
  end)

  if ok then
    return declarative_init_build()
  end

  return nil, err
end


local function list_migrations(migtable)
  local list = {}
  for _, t in ipairs(migtable) do
    local mignames = {}
    for _, mig in ipairs(t.migrations) do
      table.insert(mignames, mig.name)
    end
    table.insert(list, string.format("%s (%s)", t.subsystem,
                       table.concat(mignames, ", ")))
  end
  return table.concat(list, " ")
end


-- Kong public context handlers.
-- @section kong_handlers

local Kong = {}


function Kong.init()
  local pl_path = require "pl.path"
  local conf_loader = require "kong.conf_loader"

  -- check if kong global is the correct one
  if not kong.version then
    error("configuration error: make sure your template is not setting a " ..
          "global named 'kong' (please use 'Kong' instead)")
  end

  -- retrieve kong_config
  local conf_path = pl_path.join(ngx.config.prefix(), ".kong_env")
  local config = assert(conf_loader(conf_path, nil, { from_kong_env = true }))

  -- The dns client has been initialized in conf_loader, so we set it directly.
  -- Other modules should use 'kong.dns' to avoid reinitialization.
  kong.dns = assert(package.loaded["kong.resty.dns.client"])

  reset_kong_shm(config)

  -- special math.randomseed from kong.globalpatches not taking any argument.
  -- Must only be called in the init or init_worker phases, to avoid
  -- duplicated seeds.
  math.randomseed()

  kong_global.init_pdk(kong, config)
  instrumentation.init(config)
  wasm.init(config)

  local db = assert(DB.new(config))
  instrumentation.db_query(db.connector)
  assert(db:init_connector())

  -- check state of migration only if there is an external database
  if not is_dbless(config) then
    ngx_log(ngx_DEBUG, "checking database schema state")
    local migrations_utils = require "kong.cmd.utils.migrations"
    schema_state = assert(db:schema_state())
    migrations_utils.check_state(schema_state)

    if schema_state.missing_migrations or schema_state.pending_migrations then
      if schema_state.missing_migrations then
        ngx_log(ngx_WARN, "database is missing some migrations:\n",
                          schema_state.missing_migrations)
      end

      if schema_state.pending_migrations then
        ngx_log(ngx_WARN, "database has pending migrations:\n",
                          schema_state.pending_migrations)
      end
    end
  end

  assert(db:connect())

  kong.db = db

  if config.proxy_ssl_enabled or config.stream_ssl_enabled then
    certificate.init()
  end

  if is_http_module and (is_data_plane(config) or is_control_plane(config))
  then
    kong.clustering = require("kong.clustering").new(config)

    if config.cluster_rpc then
      kong.rpc = require("kong.clustering.rpc.manager").new(config, kong.node.get_id())

      if config.cluster_rpc_sync then
        kong.sync = require("kong.clustering.services.sync").new(db, is_control_plane(config))
        kong.sync:init(kong.rpc)
      end
    end
  end

  assert(db.vaults:load_vault_schemas(config.loaded_vaults))

  -- Load plugins as late as possible so that everything is set up
  assert(db.plugins:load_plugin_schemas(config.loaded_plugins))

  if is_stream_module then
    stream_api.load_handlers()
  end

  if is_dbless(config) then
    local dc, err = declarative.new_config(config)
    if not dc then
      error(err)
    end

    kong.db.declarative_config = dc

    if is_http_module or
       (#config.proxy_listeners == 0 and
        #config.admin_listeners == 0 and
        #config.status_listeners == 0)
    then
      declarative_entities, err, declarative_meta, declarative_hash =
        parse_declarative_config(kong.configuration, dc)

      if not declarative_entities then
        error(err)
      end

      kong.vault.warmup(declarative_entities)
    end

  else
    local default_ws = db.workspaces:select_by_name("default")
    kong.default_workspace = default_ws and default_ws.id

    local ok, err = runloop.build_plugins_iterator("init")
    if not ok then
      error("error building initial plugins: " .. tostring(err))
    end

    if not is_control_plane(config) then
      assert(runloop.build_router("init"))

      ok, err = wasm.check_enabled_filters()
      if not ok then
        error("[wasm]: " .. err)
      end

      ok, err = runloop.set_init_versions_in_cache()
      if not ok then
        error("error setting initial versions for router and plugins iterator in cache: " ..
              tostring(err))
      end
    end
  end

  db:close()

  require("resty.kong.var").patch_metatable()

  -- NOTE: privileged_agent is disabled when rpc sync is on
  if config.dedicated_config_processing and is_data_plane(config) and not kong.sync then
    -- TODO: figure out if there is better value than 4096
    -- 4096 is for the cocurrency of the lua-resty-timer-ng
    local ok, err = process.enable_privileged_agent(4096)
    if not ok then
      error(err)
    end
  end

  if config.request_debug and config.role ~= "control_plane" and is_http_module then
    local token = config.request_debug_token or uuid()

    local request_debug_token_file = pl_path.join(config.prefix,
                                                  constants.REQUEST_DEBUG_TOKEN_FILE)

    if pl_path.exists(request_debug_token_file) then
      local ok, err = pl_file.delete(request_debug_token_file)
      if not ok then
        ngx.log(ngx.ERR, "failed to delete old .request_debug_token file: ", err)
      end
    end

    local ok, err = pl_file.write(request_debug_token_file, token)
    if not ok then
      ngx.log(ngx.ERR, "failed to write .request_debug_token file: ", err)
    end

    kong.request_debug_token = token
    ngx.log(ngx.NOTICE,
            constants.REQUEST_DEBUG_LOG_PREFIX,
            " token for request debugging: ",
            kong.request_debug_token)
  end
end


function Kong.init_worker()

  emmy_debugger.init()

  local ctx = ngx.ctx

  ctx.KONG_PHASE = PHASES.init_worker

  -- special math.randomseed from kong.globalpatches not taking any argument.
  -- Must only be called in the init or init_worker phases, to avoid
  -- duplicated seeds.
  math.randomseed()


  -- setup timerng to _G.kong
  kong.timer = _G.timerng
  _G.timerng = nil

  kong.timer:set_debug(kong.configuration.log_level == "debug")
  kong.timer:start()

  -- init DB

  local ok, err = kong.db:init_worker()
  if not ok then
    stash_init_worker_error("failed to instantiate 'kong.db' module: " .. err)
    return
  end

  if worker_id() == 0 and not is_dbless(kong.configuration) then
    if schema_state.missing_migrations then
      ngx_log(ngx_WARN, "missing migrations: ",
              list_migrations(schema_state.missing_migrations))
    end

    if schema_state.pending_migrations then
      ngx_log(ngx_INFO, "starting with pending migrations: ",
              list_migrations(schema_state.pending_migrations))
    end
  end

  schema_state = nil

  local worker_events, err = kong_global.init_worker_events(kong.configuration)
  if not worker_events then
    stash_init_worker_error("failed to instantiate 'kong.worker_events' " ..
                            "module: " .. err)
    return
  end
  kong.worker_events = worker_events

  local cluster_events, err = kong_global.init_cluster_events(kong.configuration, kong.db)
  if not cluster_events then
    stash_init_worker_error("failed to instantiate 'kong.cluster_events' " ..
                            "module: " .. err)
    return
  end
  kong.cluster_events = cluster_events

  local cache, err = kong_global.init_cache(kong.configuration, cluster_events, worker_events)
  if not cache then
    stash_init_worker_error("failed to instantiate 'kong.cache' module: " ..
                            err)
    return
  end
  kong.cache = cache

  local core_cache, err = kong_global.init_core_cache(kong.configuration, cluster_events, worker_events)
  if not core_cache then
    stash_init_worker_error("failed to instantiate 'kong.core_cache' module: " ..
                            err)
    return
  end
  kong.core_cache = core_cache

  kong.db:set_events_handler(worker_events)

  if kong.configuration.admin_gui_listeners then
    kong.cache:invalidate_local(constants.ADMIN_GUI_KCONFIG_CACHE_KEY)
  end

  if kong.clustering then
    local using_dedicated = kong.configuration.dedicated_config_processing

    -- CP needs to support both v1 and v2 sync
    -- v1 sync is only enabled for DP if v2 sync is unavailble
    kong.clustering:init_worker()

    -- see is_dp_worker_process() in clustering/utils.lua
    if using_dedicated and process.type() == "privileged agent" then
      return
    end
  end

  kong.vault.init_worker()

  kong.timing = kong_global.init_timing()
  kong.timing.init_worker(kong.configuration.request_debug)

  if is_dbless(kong.configuration) then
    -- databases in LMDB need to be explicitly created, otherwise `get`
    -- operations will return error instead of `nil`. This ensures the default
    -- namespace always exists in the
    local t = lmdb_txn.begin(1)
    t:db_open(true)
    ok, err = t:commit()
    if not ok then
      stash_init_worker_error("failed to create and open LMDB database: " .. err)
      return
    end

    if not has_declarative_config(kong.configuration) and
      declarative.get_current_hash() ~= nil then
      -- if there is no declarative config set and a config is present in LMDB,
      -- just build the router and plugins iterator
      ngx_log(ngx_INFO, "found persisted lmdb config, loading...")
      local ok, err = declarative_init_build()
      if not ok then
        stash_init_worker_error("failed to initialize declarative config: " .. err)
        return
      end

    elseif declarative_entities then

      ok, err = load_declarative_config(kong.configuration,
                                        declarative_entities,
                                        declarative_meta,
                                        declarative_hash)

      declarative_entities = nil
      declarative_meta = nil
      declarative_hash = nil

      if not ok then
        stash_init_worker_error("failed to load declarative config file: " .. err)
        return
      end

    else
      -- stream does not need to load declarative config again, just build
      -- the router and plugins iterator
      local ok, err = declarative_init_build()
      if not ok then
        stash_init_worker_error("failed to initialize declarative config: " .. err)
        return
      end
    end
  end

  local is_not_control_plane = not is_control_plane(kong.configuration)
  if is_not_control_plane then
    ok, err = execute_cache_warmup(kong.configuration)
    if not ok then
      ngx_log(ngx_ERR, "failed to warm up the DB cache: ", err)
    end
  end

  ok, err = runloop.update_plugins_iterator()
  if not ok then
    stash_init_worker_error("failed to build the plugins iterator: " .. err)
    return
  end

  if is_not_control_plane then
    ok, err = runloop.update_router()
    if not ok then
      stash_init_worker_error("failed to build the router: " .. err)
      return
    end
  end

  runloop.init_worker.before()

  -- run plugins init_worker context
  local plugins_iterator = runloop.get_plugins_iterator()
  local errors = execute_init_worker_plugins_iterator(plugins_iterator, ctx)
  if errors then
    for _, e in ipairs(errors) do
      local err = 'failed to execute the "init_worker" ' ..
                  'handler for plugin "' .. e.plugin ..'": ' .. e.err
      stash_init_worker_error(err)
    end
  end

  if is_not_control_plane then
    plugin_servers.start()
  end

  -- rpc and sync
  if is_http_module then

    -- init rpc connection
    if kong.rpc then
      kong.rpc:init_worker()
    end

    -- init sync
    -- should run after rpc init successfully
    if kong.sync then
      kong.sync:init_worker()
    end
  end

  ok, err = wasm.init_worker()
  if not ok then
    err = "wasm nginx worker initialization failed: " .. tostring(err)
    stash_init_worker_error(err)
    return
  end

  plugins_iterator:configure(ctx)
end


function Kong.exit_worker()
  if process.type() ~= "privileged agent" and not is_control_plane(kong.configuration) then
    plugin_servers.stop()
  end
end


function Kong.ssl_certificate()
  -- Note: ctx here is for a connection (not for a single request)
  local ctx = get_ctx_table(fetch_table(CTX_NS, CTX_NARR, CTX_NREC))

  ctx.KONG_PHASE = PHASES.certificate

  log_init_worker_errors(ctx)

  -- this is the first phase to run on an HTTPS request
  ctx.workspace = kong.default_workspace

  certificate.execute()
  local plugins_iterator = runloop.get_updated_plugins_iterator()
  execute_global_plugins_iterator(plugins_iterator, "certificate", ctx)

  -- TODO: do we want to keep connection context?
  kong.table.clear(ngx.ctx)
end

function Kong.ssl_client_hello()
  local ctx = get_ctx_table(fetch_table(CTX_NS, CTX_NARR, CTX_NREC))
  ctx.KONG_PHASE = PHASES.client_hello
end

function Kong.preread()
  local ctx = get_ctx_table(fetch_table(CTX_NS, CTX_NARR, CTX_NREC))
  if not ctx.KONG_PROCESSING_START then
    ctx.KONG_PROCESSING_START = get_start_time_ms()
  end

  if not ctx.KONG_PREREAD_START then
    ctx.KONG_PREREAD_START = get_now_ms()
  end

  ctx.KONG_PHASE = PHASES.preread

  log_init_worker_errors(ctx)

  local preread_terminate = runloop.preread.before(ctx)

  -- if proxying to a second layer TLS terminator is required
  -- abort further execution and return back to Nginx
  if preread_terminate then
    return
  end

  local plugins_iterator = runloop.get_updated_plugins_iterator()
  execute_collecting_plugins_iterator(plugins_iterator, "preread", ctx)

  if ctx.delayed_response then
    ctx.KONG_PREREAD_ENDED_AT = get_updated_now_ms()
    ctx.KONG_PREREAD_TIME = ctx.KONG_PREREAD_ENDED_AT - ctx.KONG_PREREAD_START
    ctx.KONG_RESPONSE_LATENCY = ctx.KONG_PREREAD_ENDED_AT - ctx.KONG_PROCESSING_START

    return flush_delayed_response(ctx)
  end

  ctx.delay_response = nil

  if not ctx.service then
    ctx.KONG_PREREAD_ENDED_AT = get_updated_now_ms()
    ctx.KONG_PREREAD_TIME = ctx.KONG_PREREAD_ENDED_AT - ctx.KONG_PREREAD_START
    ctx.KONG_RESPONSE_LATENCY = ctx.KONG_PREREAD_ENDED_AT - ctx.KONG_PROCESSING_START

    ngx_log(ngx_WARN, "no Service found with those values")
    return ngx.exit(503)
  end

  runloop.preread.after(ctx)

  ctx.KONG_PREREAD_ENDED_AT = get_updated_now_ms()
  ctx.KONG_PREREAD_TIME = ctx.KONG_PREREAD_ENDED_AT - ctx.KONG_PREREAD_START

  -- we intent to proxy, though balancer may fail on that
  ctx.KONG_PROXIED = true
end


function Kong.rewrite()
  local proxy_mode = var.kong_proxy_mode
  if proxy_mode == "grpc" or proxy_mode == "unbuffered"  then
    kong_resty_ctx.apply_ref()    -- if kong_proxy_mode is gRPC/unbuffered, this is executing
    local ctx = ngx.ctx           -- after an internal redirect. Restore (and restash)
    kong_resty_ctx.stash_ref(ctx) -- context to avoid re-executing phases

    ctx.KONG_REWRITE_ENDED_AT = get_now_ms()
    ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT - ctx.KONG_REWRITE_START

    return
  end

  local is_https = var.https == "on"
  local ctx
  if is_https then
    ctx = ngx.ctx
  else
    ctx = get_ctx_table(fetch_table(CTX_NS, CTX_NARR, CTX_NREC))
  end

  if not ctx.KONG_PROCESSING_START then
    ctx.KONG_PROCESSING_START = get_start_time_ms()
  end

  if not ctx.KONG_REWRITE_START then
    ctx.KONG_REWRITE_START = get_now_ms()
  end

  ctx.KONG_PHASE = PHASES.rewrite
  local has_timing

  req_dyn_hook_run_hook("timing:auth", "auth")

  if req_dyn_hook_is_group_enabled("timing") then
    ctx.has_timing = true
    has_timing = true
  end

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:rewrite")
  end

  kong_resty_ctx.stash_ref(ctx)

  if not is_https then
    log_init_worker_errors(ctx)
  end

  runloop.rewrite.before(ctx)

  if not ctx.workspace then
    ctx.workspace = kong.default_workspace
  end

  -- On HTTPS requests, the plugins iterator is already updated in the ssl_certificate phase
  local plugins_iterator
  if is_https then
    plugins_iterator = runloop.get_plugins_iterator()
  else
    plugins_iterator = runloop.get_updated_plugins_iterator()
  end

  execute_global_plugins_iterator(plugins_iterator, "rewrite", ctx)

  ctx.KONG_REWRITE_ENDED_AT = get_updated_now_ms()
  ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT - ctx.KONG_REWRITE_START

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:rewrite")
  end
end


function Kong.access()
  local ctx = ngx.ctx
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:access")
  end

  if not ctx.KONG_ACCESS_START then
    ctx.KONG_ACCESS_START = get_now_ms()

    if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
      ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_ACCESS_START
      ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT - ctx.KONG_REWRITE_START
    end
  end

  ctx.KONG_PHASE = PHASES.access

  runloop.access.before(ctx)

  local plugins_iterator = runloop.get_plugins_iterator()

  execute_collecting_plugins_iterator(plugins_iterator, "access", ctx)

  if ctx.delayed_response then
    ctx.KONG_ACCESS_ENDED_AT = get_updated_now_ms()
    ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START
    ctx.KONG_RESPONSE_LATENCY = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_PROCESSING_START

    if has_timing then
      req_dyn_hook_run_hook("timing", "after:access")
    end

    return flush_delayed_response(ctx)
  end

  ctx.delay_response = nil

  if not ctx.service then
    ctx.KONG_ACCESS_ENDED_AT = get_updated_now_ms()
    ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START
    ctx.KONG_RESPONSE_LATENCY = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_PROCESSING_START

    ctx.buffered_proxying = nil

    if has_timing then
      req_dyn_hook_run_hook("timing", "after:access")
    end

    return kong.response.error(503, "no Service found with those values")
  end

  runloop.wasm_attach(ctx)
  runloop.access.after(ctx)

  ctx.KONG_ACCESS_ENDED_AT = get_updated_now_ms()
  ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT - ctx.KONG_ACCESS_START

  -- we intent to proxy, though balancer may fail on that
  ctx.KONG_PROXIED = true


  if ctx.buffered_proxying then
    local upgrade = var.upstream_upgrade or ""
    if upgrade == "" then
      if has_timing then
        req_dyn_hook_run_hook("timing", "after:access")
      end

      return Kong.response()
    end

    ngx_log(ngx_NOTICE, "response buffering was turned off: connection upgrade (", upgrade, ")")

    ctx.buffered_proxying = nil
  end

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:access")
  end
end


function Kong.balancer()
  local ctx = ngx.ctx
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:balancer")
  end

  -- This may be called multiple times, and no yielding here!
  local now_ms = get_now_ms()
  local now_ns = time_ns()

  if not ctx.KONG_BALANCER_START then
    ctx.KONG_BALANCER_START = now_ms

    if is_stream_module then
      if ctx.KONG_PREREAD_START and not ctx.KONG_PREREAD_ENDED_AT then
        ctx.KONG_PREREAD_ENDED_AT = ctx.KONG_BALANCER_START
        ctx.KONG_PREREAD_TIME = ctx.KONG_PREREAD_ENDED_AT -
                                ctx.KONG_PREREAD_START
      end

    else
      if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
        ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_ACCESS_START or
                                    ctx.KONG_BALANCER_START
        ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT -
                                ctx.KONG_REWRITE_START
      end

      if ctx.KONG_ACCESS_START and not ctx.KONG_ACCESS_ENDED_AT then
        ctx.KONG_ACCESS_ENDED_AT = ctx.KONG_BALANCER_START
        ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT -
                               ctx.KONG_ACCESS_START
      end
    end
  end

  ctx.KONG_PHASE = PHASES.balancer

  local balancer_data = ctx.balancer_data
  local tries = balancer_data.tries
  local try_count = balancer_data.try_count
  local current_try = table_new(0, 4)

  try_count = try_count + 1
  balancer_data.try_count = try_count
  tries[try_count] = current_try

  current_try.balancer_start = now_ms
  current_try.balancer_start_ns = now_ns

  if try_count > 1 then
    -- only call balancer on retry, first one is done in `runloop.access.after`
    -- which runs in the ACCESS context and hence has less limitations than
    -- this BALANCER context where the retries are executed

    -- record failure data
    local previous_try = tries[try_count - 1]
    previous_try.state, previous_try.code = get_last_failure()

    -- Report HTTP status for health checks
    local balancer_instance = balancer_data.balancer
    if balancer_instance then
      if previous_try.state == "failed" then
        if previous_try.code == 504 then
          balancer_instance.report_timeout(balancer_data.balancer_handle)
        else
          balancer_instance.report_tcp_failure(balancer_data.balancer_handle)
        end

      else
        balancer_instance.report_http_status(balancer_data.balancer_handle,
                                             previous_try.code)
      end
    end

    local ok, err, errcode = balancer.execute(balancer_data, ctx)
    if not ok then
      ngx_log(ngx_ERR, "failed to retry the dns/balancer resolver for ",
              tostring(balancer_data.host), "' with: ", tostring(err))

      ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
      ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START
      ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START

      if has_timing then
        req_dyn_hook_run_hook("timing", "after:balancer")
      end

      return ngx.exit(errcode)
    end

    if is_http_module then
      ok, err = balancer.set_host_header(balancer_data, var.upstream_scheme, var.upstream_host, true)
      if not ok then
        ngx_log(ngx_ERR, "failed to set balancer Host header: ", err)

        if has_timing then
          req_dyn_hook_run_hook("timing", "after:balancer")
        end

        return ngx.exit(500)
      end
    end

  else
    -- first try, so set the max number of retries
    local retries = balancer_data.retries
    if retries > 0 then
      set_more_tries(retries)
    end
  end

  local pool_opts
  local kong_conf = kong.configuration
  local balancer_data_ip = balancer_data.ip
  local balancer_data_port = balancer_data.port

  if kong_conf.upstream_keepalive_pool_size > 0 and is_http_module then
    local pool = balancer_data_ip .. "|" .. balancer_data_port

    if balancer_data.scheme == "https" then
      -- upstream_host is SNI
      pool = pool .. "|" .. var.upstream_host

      local ctx_service = ctx.service
      if ctx_service then
        pool = string.format("%s|%s|%s|%s|%s",
              pool,
              ctx_service.tls_verify ~= nil and tostring(ctx_service.tls_verify) or "",
              ctx_service.tls_verify_depth or "",
              ctx_service.ca_certificates and table.concat(ctx_service.ca_certificates, ",") or "",
              ctx_service.client_certificate and ctx_service.client_certificate.id or "")
      end
    end

    pool_opts = {
      pool = pool,
      pool_size = kong_conf.upstream_keepalive_pool_size,
    }
  end

  current_try.ip   = balancer_data_ip
  current_try.port = balancer_data_port

  -- set the targets as resolved
  ngx_log(ngx_DEBUG, "setting address (try ", try_count, "): ",
                     balancer_data_ip, ":", balancer_data_port)
  local ok, err = set_current_peer(balancer_data_ip, balancer_data_port, pool_opts)
  if not ok then
    ngx_log(ngx_ERR, "failed to set the current peer (address: ",
            tostring(balancer_data_ip), " port: ", tostring(balancer_data_port),
            "): ", tostring(err))

    ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
    ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START
    ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START

    if has_timing then
      req_dyn_hook_run_hook("timing", "after:balancer")
    end

    return ngx.exit(500)
  end

  ok, err = set_timeouts(balancer_data.connect_timeout / 1000,
                         balancer_data.send_timeout / 1000,
                         balancer_data.read_timeout / 1000)
  if not ok then
    ngx_log(ngx_ERR, "could not set upstream timeouts: ", err)
  end

  if pool_opts then
    ok, err = enable_keepalive(kong_conf.upstream_keepalive_idle_timeout,
                               kong_conf.upstream_keepalive_max_requests)
    if not ok then
      ngx_log(ngx_ERR, "could not enable connection keepalive: ", err)
    end

    ngx_log(ngx_DEBUG, "enabled connection keepalive (pool=", pool_opts.pool,
                       ", pool_size=", pool_opts.pool_size,
                       ", idle_timeout=", kong_conf.upstream_keepalive_idle_timeout,
                       ", max_requests=", kong_conf.upstream_keepalive_max_requests, ")")
  end

  -- record overall latency
  ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
  ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START

  -- record try-latency
  local try_latency = ctx.KONG_BALANCER_ENDED_AT - current_try.balancer_start
  current_try.balancer_latency = try_latency
  current_try.balancer_latency_ns = time_ns() - current_try.balancer_start_ns

  -- time spent in Kong before sending the request to upstream
  -- start_time() is kept in seconds with millisecond resolution.
  ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:balancer")
  end
end


do
  local HTTP_METHODS = {
    GET       = ngx.HTTP_GET,
    HEAD      = ngx.HTTP_HEAD,
    PUT       = ngx.HTTP_PUT,
    POST      = ngx.HTTP_POST,
    DELETE    = ngx.HTTP_DELETE,
    OPTIONS   = ngx.HTTP_OPTIONS,
    MKCOL     = ngx.HTTP_MKCOL,
    COPY      = ngx.HTTP_COPY,
    MOVE      = ngx.HTTP_MOVE,
    PROPFIND  = ngx.HTTP_PROPFIND,
    PROPPATCH = ngx.HTTP_PROPPATCH,
    LOCK      = ngx.HTTP_LOCK,
    UNLOCK    = ngx.HTTP_UNLOCK,
    PATCH     = ngx.HTTP_PATCH,
    TRACE     = ngx.HTTP_TRACE,
  }

  function Kong.response()
    local ctx = ngx.ctx
    local has_timing = ctx.has_timing

    if has_timing then
      req_dyn_hook_run_hook("timing", "before:response")
    end

    local plugins_iterator = runloop.get_plugins_iterator()

    -- buffered proxying (that also executes the balancer)
    ngx.req.read_body()

    local options = {
      always_forward_body = true,
      share_all_vars      = true,
      method              = HTTP_METHODS[ngx.req.get_method()],
      ctx                 = ctx,
    }

    local res = ngx.location.capture("/kong_buffered_http", options)
    if res.truncated and options.method ~= ngx.HTTP_HEAD then
      ctx.KONG_PHASE = PHASES.error
      ngx.status = res.status or 502

      if has_timing then
        req_dyn_hook_run_hook("timing", "after:response")
      end

      return kong_error_handlers(ctx)
    end

    ctx.KONG_PHASE = PHASES.response

    local status = res.status
    local headers = res.header
    local body = res.body

    ctx.buffered_status = status
    ctx.buffered_headers = headers
    ctx.buffered_body = body

    -- fake response phase (this runs after the balancer)
    if not ctx.KONG_RESPONSE_START then
      ctx.KONG_RESPONSE_START = get_now_ms()

      if ctx.KONG_BALANCER_START and not ctx.KONG_BALANCER_ENDED_AT then
        ctx.KONG_BALANCER_ENDED_AT = ctx.KONG_RESPONSE_START
        ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT -
          ctx.KONG_BALANCER_START
      end
    end

    if not ctx.KONG_WAITING_TIME then
      ctx.KONG_WAITING_TIME = ctx.KONG_RESPONSE_START -
        (ctx.KONG_BALANCER_ENDED_AT or ctx.KONG_ACCESS_ENDED_AT)
    end

    if not ctx.KONG_PROXY_LATENCY then
      ctx.KONG_PROXY_LATENCY = ctx.KONG_RESPONSE_START - ctx.KONG_PROCESSING_START
    end

    if not ctx.KONG_UPSTREAM_DNS_TIME and ctx.KONG_UPSTREAM_DNS_END_AT and ctx.KONG_UPSTREAM_DNS_START then
      ctx.KONG_UPSTREAM_DNS_TIME = ctx.KONG_UPSTREAM_DNS_END_AT - ctx.KONG_UPSTREAM_DNS_START
    else
      ctx.KONG_UPSTREAM_DNS_TIME = 0
    end

    kong.response.set_status(status)
    kong.response.set_headers(headers)

    execute_collected_plugins_iterator(plugins_iterator, "response", ctx)

    ctx.KONG_RESPONSE_ENDED_AT = get_updated_now_ms()
    ctx.KONG_RESPONSE_TIME = ctx.KONG_RESPONSE_ENDED_AT - ctx.KONG_RESPONSE_START

    -- buffered response
    ngx.print(body)

    if has_timing then
      req_dyn_hook_run_hook("timing", "after:response")
    end

    -- jump over the balancer to header_filter
    ngx.exit(status)
  end
end


function Kong.header_filter()
  local ctx = ngx.ctx
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:header_filter")
  end

  if not ctx.KONG_PROCESSING_START then
    ctx.KONG_PROCESSING_START = get_start_time_ms()
  end

  if not ctx.workspace then
    ctx.workspace = kong.default_workspace
  end

  if not ctx.KONG_HEADER_FILTER_START then
    ctx.KONG_HEADER_FILTER_START = get_now_ms()

    if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
      ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_BALANCER_START or
                                  ctx.KONG_ACCESS_START or
                                  ctx.KONG_RESPONSE_START or
                                  ctx.KONG_HEADER_FILTER_START
      ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT -
                              ctx.KONG_REWRITE_START
    end

    if ctx.KONG_ACCESS_START and not ctx.KONG_ACCESS_ENDED_AT then
      ctx.KONG_ACCESS_ENDED_AT = ctx.KONG_BALANCER_START or
                                 ctx.KONG_RESPONSE_START or
                                 ctx.KONG_HEADER_FILTER_START
      ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT -
                             ctx.KONG_ACCESS_START
    end

    if ctx.KONG_BALANCER_START and not ctx.KONG_BALANCER_ENDED_AT then
      ctx.KONG_BALANCER_ENDED_AT = ctx.KONG_RESPONSE_START or
                                   ctx.KONG_HEADER_FILTER_START
      ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT -
                               ctx.KONG_BALANCER_START
    end

    if ctx.KONG_RESPONSE_START and not ctx.KONG_RESPONSE_ENDED_AT then
      ctx.KONG_RESPONSE_ENDED_AT = ctx.KONG_HEADER_FILTER_START
      ctx.KONG_RESPONSE_TIME = ctx.KONG_RESPONSE_ENDED_AT -
                               ctx.KONG_RESPONSE_START
    end
  end

  if ctx.KONG_PROXIED then
    if not ctx.KONG_WAITING_TIME then
      ctx.KONG_WAITING_TIME = (ctx.KONG_RESPONSE_START    or ctx.KONG_HEADER_FILTER_START) -
                              (ctx.KONG_BALANCER_ENDED_AT or ctx.KONG_ACCESS_ENDED_AT)
    end

    if not ctx.KONG_PROXY_LATENCY then
      ctx.KONG_PROXY_LATENCY = (ctx.KONG_RESPONSE_START or ctx.KONG_HEADER_FILTER_START) -
                                ctx.KONG_PROCESSING_START
    end

  elseif not ctx.KONG_RESPONSE_LATENCY then
    ctx.KONG_RESPONSE_LATENCY = (ctx.KONG_RESPONSE_START or ctx.KONG_HEADER_FILTER_START) -
                                 ctx.KONG_PROCESSING_START
  end

  ctx.KONG_PHASE = PHASES.header_filter

  runloop.header_filter.before(ctx)
  local plugins_iterator = runloop.get_plugins_iterator()
  execute_collected_plugins_iterator(plugins_iterator, "header_filter", ctx)
  runloop.header_filter.after(ctx)

  ctx.KONG_HEADER_FILTER_ENDED_AT = get_updated_now_ms()
  ctx.KONG_HEADER_FILTER_TIME = ctx.KONG_HEADER_FILTER_ENDED_AT - ctx.KONG_HEADER_FILTER_START

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:header_filter")
  end
end


function Kong.body_filter()
  local ctx = ngx.ctx
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:body_filter")
  end

  if not ctx.KONG_BODY_FILTER_START then
    ctx.KONG_BODY_FILTER_START = get_now_ms()

    if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
      ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_ACCESS_START or
                                  ctx.KONG_BALANCER_START or
                                  ctx.KONG_RESPONSE_START or
                                  ctx.KONG_HEADER_FILTER_START or
                                  ctx.KONG_BODY_FILTER_START
      ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT -
                              ctx.KONG_REWRITE_START
    end

    if ctx.KONG_ACCESS_START and not ctx.KONG_ACCESS_ENDED_AT then
      ctx.KONG_ACCESS_ENDED_AT = ctx.KONG_BALANCER_START or
                                 ctx.KONG_RESPONSE_START or
                                 ctx.KONG_HEADER_FILTER_START or
                                 ctx.KONG_BODY_FILTER_START
      ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT -
                             ctx.KONG_ACCESS_START
    end

    if ctx.KONG_BALANCER_START and not ctx.KONG_BALANCER_ENDED_AT then
      ctx.KONG_BALANCER_ENDED_AT = ctx.KONG_RESPONSE_START or
                                   ctx.KONG_HEADER_FILTER_START or
                                   ctx.KONG_BODY_FILTER_START
      ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT -
                               ctx.KONG_BALANCER_START
    end

    if ctx.KONG_RESPONSE_START and not ctx.KONG_RESPONSE_ENDED_AT then
      ctx.KONG_RESPONSE_ENDED_AT = ctx.KONG_HEADER_FILTER_START or
                                   ctx.KONG_BODY_FILTER_START
      ctx.KONG_RESPONSE_TIME = ctx.KONG_RESPONSE_ENDED_AT -
                               ctx.KONG_RESPONSE_START
    end

    if ctx.KONG_HEADER_FILTER_START and not ctx.KONG_HEADER_FILTER_ENDED_AT then
      ctx.KONG_HEADER_FILTER_ENDED_AT = ctx.KONG_BODY_FILTER_START
      ctx.KONG_HEADER_FILTER_TIME = ctx.KONG_HEADER_FILTER_ENDED_AT -
                                    ctx.KONG_HEADER_FILTER_START
    end
  end

  ctx.KONG_PHASE = PHASES.body_filter

  if ctx.response_body then
    arg[1] = ctx.response_body
    arg[2] = true
  end

  local plugins_iterator = runloop.get_plugins_iterator()
  execute_collected_plugins_iterator(plugins_iterator, "body_filter", ctx)

  if not arg[2] then
    if has_timing then
      req_dyn_hook_run_hook("timing", "after:body_filter")
    end

    return
  end

  ctx.KONG_BODY_FILTER_ENDED_AT = get_updated_now_ms()
  ctx.KONG_BODY_FILTER_ENDED_AT_NS = time_ns()
  ctx.KONG_BODY_FILTER_TIME = ctx.KONG_BODY_FILTER_ENDED_AT - ctx.KONG_BODY_FILTER_START

  if ctx.KONG_PROXIED then
    -- time spent receiving the response ((response +) header_filter + body_filter)
    -- we could use $upstream_response_time but we need to distinguish the waiting time
    -- from the receiving time in our logging plugins (especially ALF serializer).
    ctx.KONG_RECEIVE_TIME = ctx.KONG_BODY_FILTER_ENDED_AT - (ctx.KONG_RESPONSE_START or
                                                             ctx.KONG_HEADER_FILTER_START or
                                                             ctx.KONG_BALANCER_ENDED_AT or
                                                             ctx.KONG_BALANCER_START or
                                                             ctx.KONG_ACCESS_ENDED_AT)
  end

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:body_filter")
  end
end


function Kong.log()
  local ctx = ngx.ctx
  local has_timing = ctx.has_timing

  if has_timing then
    req_dyn_hook_run_hook("timing", "before:log")
  end

  if not ctx.KONG_LOG_START then
    ctx.KONG_LOG_START = get_now_ms()
    ctx.KONG_LOG_START_NS = time_ns()
    if is_stream_module then
      if not ctx.KONG_PROCESSING_START then
        ctx.KONG_PROCESSING_START = get_start_time_ms()
      end

      if ctx.KONG_PREREAD_START and not ctx.KONG_PREREAD_ENDED_AT then
        ctx.KONG_PREREAD_ENDED_AT = ctx.KONG_LOG_START
        ctx.KONG_PREREAD_TIME = ctx.KONG_PREREAD_ENDED_AT -
                                ctx.KONG_PREREAD_START
      end

      if ctx.KONG_BALANCER_START and not ctx.KONG_BALANCER_ENDED_AT then
        ctx.KONG_BALANCER_ENDED_AT = ctx.KONG_LOG_START
        ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT -
                                 ctx.KONG_BALANCER_START
      end

      if ctx.KONG_PROXIED then
        if not ctx.KONG_PROXY_LATENCY then
          ctx.KONG_PROXY_LATENCY = ctx.KONG_LOG_START -
                                   ctx.KONG_PROCESSING_START
        end

      elseif not ctx.KONG_RESPONSE_LATENCY then
        ctx.KONG_RESPONSE_LATENCY = ctx.KONG_LOG_START -
                                    ctx.KONG_PROCESSING_START
      end

    else
      if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
        ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_ACCESS_START or
                                    ctx.KONG_BALANCER_START or
                                    ctx.KONG_RESPONSE_START or
                                    ctx.KONG_HEADER_FILTER_START or
                                    ctx.BODY_FILTER_START or
                                    ctx.KONG_LOG_START
        ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT -
                                ctx.KONG_REWRITE_START
      end

      if ctx.KONG_ACCESS_START and not ctx.KONG_ACCESS_ENDED_AT then
        ctx.KONG_ACCESS_ENDED_AT = ctx.KONG_BALANCER_START or
                                   ctx.KONG_RESPONSE_START or
                                   ctx.KONG_HEADER_FILTER_START or
                                   ctx.BODY_FILTER_START or
                                   ctx.KONG_LOG_START
        ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT -
                               ctx.KONG_ACCESS_START
      end

      if ctx.KONG_BALANCER_START and not ctx.KONG_BALANCER_ENDED_AT then
        ctx.KONG_BALANCER_ENDED_AT = ctx.KONG_RESPONSE_START or
                                     ctx.KONG_HEADER_FILTER_START or
                                     ctx.BODY_FILTER_START or
                                     ctx.KONG_LOG_START
        ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT -
                                 ctx.KONG_BALANCER_START
      end

      if ctx.KONG_HEADER_FILTER_START and not ctx.KONG_HEADER_FILTER_ENDED_AT then
        ctx.KONG_HEADER_FILTER_ENDED_AT = ctx.BODY_FILTER_START or
                                          ctx.KONG_LOG_START
        ctx.KONG_HEADER_FILTER_TIME = ctx.KONG_HEADER_FILTER_ENDED_AT -
                                      ctx.KONG_HEADER_FILTER_START
      end

      if ctx.KONG_BODY_FILTER_START and not ctx.KONG_BODY_FILTER_ENDED_AT then
        ctx.KONG_BODY_FILTER_ENDED_AT = ctx.KONG_LOG_START
        ctx.KONG_BODY_FILTER_ENDED_AT_NS = ctx.KONG_LOG_START_NS
        ctx.KONG_BODY_FILTER_TIME = ctx.KONG_BODY_FILTER_ENDED_AT -
                                    ctx.KONG_BODY_FILTER_START
      end

      if ctx.KONG_PROXIED and not ctx.KONG_WAITING_TIME then
        ctx.KONG_WAITING_TIME = ctx.KONG_LOG_START -
                                (ctx.KONG_BALANCER_ENDED_AT or ctx.KONG_ACCESS_ENDED_AT)
      end
    end
  end

  ctx.KONG_PHASE = PHASES.log

  runloop.log.before(ctx)
  local plugins_iterator = runloop.get_plugins_iterator()
  execute_collected_plugins_iterator(plugins_iterator, "log", ctx)
  plugins_iterator.release(ctx)
  runloop.log.after(ctx)

  if has_timing then
    req_dyn_hook_run_hook("timing", "after:log")
  end

  release_table(CTX_NS, ctx)

  -- this is not used for now, but perhaps we need it later?
  --ctx.KONG_LOG_ENDED_AT = get_now_ms()
  --ctx.KONG_LOG_TIME = ctx.KONG_LOG_ENDED_AT - ctx.KONG_LOG_START
end


function Kong.handle_error()
  kong_resty_ctx.apply_ref()

  local ctx = ngx.ctx
  ctx.KONG_PHASE = PHASES.error
  ctx.KONG_UNEXPECTED = true

  log_init_worker_errors(ctx)

  return kong_error_handlers(ctx)
end


local function serve_content(module)
  local ctx = ngx.ctx
  ctx.KONG_PROCESSING_START = get_start_time_ms()
  ctx.KONG_ADMIN_CONTENT_START = ctx.KONG_ADMIN_CONTENT_START or get_now_ms()
  ctx.KONG_PHASE = PHASES.admin_api

  log_init_worker_errors(ctx)

  ngx.header["Access-Control-Allow-Origin"] = ngx.req.get_headers()["Origin"] or "*"

  lapis.serve(module)

  ctx.KONG_ADMIN_CONTENT_ENDED_AT = get_updated_now_ms()
  ctx.KONG_ADMIN_CONTENT_TIME = ctx.KONG_ADMIN_CONTENT_ENDED_AT - ctx.KONG_ADMIN_CONTENT_START
  ctx.KONG_ADMIN_LATENCY = ctx.KONG_ADMIN_CONTENT_ENDED_AT - ctx.KONG_PROCESSING_START
end


function Kong.admin_content()
  kong.worker_events.poll()

  local ctx = ngx.ctx
  if not ctx.workspace then
    ctx.workspace = kong.default_workspace
  end

  return serve_content("kong.api")
end


function Kong.admin_header_filter()
  local ctx = ngx.ctx

  if not ctx.KONG_PROCESSING_START then
    ctx.KONG_PROCESSING_START = get_start_time_ms()
  end

  if not ctx.KONG_ADMIN_HEADER_FILTER_START then
    ctx.KONG_ADMIN_HEADER_FILTER_START = get_now_ms()

    if ctx.KONG_ADMIN_CONTENT_START and not ctx.KONG_ADMIN_CONTENT_ENDED_AT then
      ctx.KONG_ADMIN_CONTENT_ENDED_AT = ctx.KONG_ADMIN_HEADER_FILTER_START
      ctx.KONG_ADMIN_CONTENT_TIME = ctx.KONG_ADMIN_CONTENT_ENDED_AT - ctx.KONG_ADMIN_CONTENT_START
    end

    if not ctx.KONG_ADMIN_LATENCY then
      ctx.KONG_ADMIN_LATENCY = ctx.KONG_ADMIN_HEADER_FILTER_START - ctx.KONG_PROCESSING_START
    end
  end

  local enabled_headers = kong.configuration.enabled_headers
  local headers = constants.HEADERS

  if enabled_headers[headers.ADMIN_LATENCY] then
    header[headers.ADMIN_LATENCY] = ctx.KONG_ADMIN_LATENCY
  end

  if enabled_headers[headers.SERVER] then
    header[headers.SERVER] = meta._SERVER_TOKENS

  else
    header[headers.SERVER] = nil
  end

  -- this is not used for now, but perhaps we need it later?
  --ctx.KONG_ADMIN_HEADER_FILTER_ENDED_AT = get_now_ms()
  --ctx.KONG_ADMIN_HEADER_FILTER_TIME = ctx.KONG_ADMIN_HEADER_FILTER_ENDED_AT - ctx.KONG_ADMIN_HEADER_FILTER_START
end

function Kong.admin_gui_kconfig_content()
  local content, err = kong.cache:get(
    constants.ADMIN_GUI_KCONFIG_CACHE_KEY,
    nil,
    admin_gui.generate_kconfig,
    kong.configuration
  )
  if err then
    kong.log.err("error occurred while retrieving admin gui config `kconfig.js` from cache", err)
    kong.response.exit(500, { message = "An unexpected error occurred" })
  else
    ngx.say(content)
  end
end

function Kong.admin_gui_log()
  if kong.configuration.anonymous_reports then
    reports.admin_gui_log(ngx.ctx)
  end
end

function Kong.status_content()
  return serve_content("kong.status")
end


Kong.status_header_filter = Kong.admin_header_filter


function Kong.serve_cluster_listener()
  local ctx = ngx.ctx

  log_init_worker_errors(ctx)

  ctx.KONG_PHASE = PHASES.cluster_listener

  return kong.clustering:handle_cp_websocket()
end


function Kong.stream_api()
  stream_api.handle()
end


function Kong.serve_cluster_rpc_listener()
  local ctx = ngx.ctx

  log_init_worker_errors(ctx)

  ctx.KONG_PHASE = PHASES.cluster_listener

  return kong.rpc:handle_websocket()
end


do
  local events = require "kong.runloop.events"
  Kong.stream_config_listener = events.stream_reconfigure_listener
end


return Kong
