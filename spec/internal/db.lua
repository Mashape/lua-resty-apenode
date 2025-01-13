------------------------------------------------------------------
-- Collection of utilities to help testing Kong features and plugins.
--
-- @copyright Copyright 2016-2022 Kong Inc. All rights reserved.
-- @license [Apache 2.0](https://opensource.org/licenses/Apache-2.0)
-- @module spec.helpers


local pl_tablex = require("pl.tablex")
local table_clone = require("table.clone")


local DB = require("kong.db")
local constants = require("kong.constants")
local kong_global = require("kong.global")
local Blueprints = require("spec.fixtures.blueprints")
local dc_blueprints = require("spec.fixtures.dc_blueprints")


-- will be initialized in get_db_utils()
local dcbp
local PLUGINS_LIST


-- Add to package path so dao helpers can insert custom plugins
-- (while running from the busted environment)
do
  local CONSTANTS = require("spec.internal.constants")

  local paths = {}
  table.insert(paths, os.getenv("KONG_LUA_PACKAGE_PATH"))
  table.insert(paths, CONSTANTS.CUSTOM_PLUGIN_PATH)
  table.insert(paths, CONSTANTS.CUSTOM_VAULT_PATH)
  table.insert(paths, package.path)
  package.path = table.concat(paths, ";")
end


-- ------------
-- Conf and DAO
-- ------------

local conf = require("spec.internal.conf")


_G.kong = kong_global.new()
kong_global.init_pdk(_G.kong, conf)
ngx.ctx.KONG_PHASE = kong_global.phases.access
_G.kong.core_cache = {
  get = function(self, key, opts, func, ...)
    if key == constants.CLUSTER_ID_PARAM_KEY then
      return "123e4567-e89b-12d3-a456-426655440000"
    end

    return func(...)
  end
}


local db = assert(DB.new(conf))
assert(db:init_connector())
db.plugins:load_plugin_schemas(conf.loaded_plugins)
db.vaults:load_vault_schemas(conf.loaded_vaults)
local blueprints = assert(Blueprints.new(db))


kong.db = db


--- Gets the ml_cache instance.
-- @function get_cache
-- @param db the database object
-- @return ml_cache instance
local function get_cache(db)
  local worker_events = assert(kong_global.init_worker_events(conf))
  local cluster_events = assert(kong_global.init_cluster_events(conf, db))
  local cache = assert(kong_global.init_cache(conf,
                                              cluster_events,
                                              worker_events
                                              ))
  return cache
end


--- Iterator over DB strategies.
-- @function each_strategy
-- @param strategies (optional string array) explicit list of strategies to use,
-- defaults to `{ "postgres", }`.
-- @see all_strategies
-- @usage
-- -- repeat all tests for each strategy
-- for _, strategy_name in helpers.each_strategy() do
--   describe("my test set [#" .. strategy .. "]", function()
--
--     -- add your tests here
--
--   end)
-- end
local function each_strategy() -- luacheck: ignore   -- required to trick ldoc into processing for docs
end


--- Iterator over all strategies, the DB ones and the DB-less one.
-- To test with DB-less, check the example.
-- @function all_strategies
-- @param strategies (optional string array) explicit list of strategies to use,
-- defaults to `{ "postgres", "off" }`.
-- @see each_strategy
-- @see make_yaml_file
-- @usage
-- -- example of using DB-less testing
--
-- -- use "all_strategies" to iterate over; "postgres", "off"
-- for _, strategy in helpers.all_strategies() do
--   describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
--
--     lazy_setup(function()
--
--       -- when calling "get_db_utils" with "strategy=off", we still use
--       -- "postgres" so we can write the test setup to the database.
--       local bp = helpers.get_db_utils(
--                      strategy == "off" and "postgres" or strategy,
--                      nil, { PLUGIN_NAME })
--
--       -- Inject a test route, when "strategy=off" it will still be written
--       -- to Postgres.
--       local route1 = bp.routes:insert({
--         hosts = { "test1.com" },
--       })
--
--       -- start kong
--       assert(helpers.start_kong({
--         -- set the strategy
--         database   = strategy,
--         nginx_conf = "spec/fixtures/custom_nginx.template",
--         plugins = "bundled," .. PLUGIN_NAME,
--
--         -- The call to "make_yaml_file" will write the contents of
--         -- the database to a temporary file, which filename is returned.
--         -- But only when "strategy=off".
--         declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
--
--         -- the below lines can be omitted, but are just to prove that the test
--         -- really runs DB-less despite that Postgres was used as intermediary
--         -- storage.
--         pg_host = strategy == "off" and "unknownhost.konghq.com" or nil,
--       }))
--     end)
--
--     ... rest of your test file
local function all_strategies() -- luacheck: ignore   -- required to trick ldoc into processing for docs
end


do
  local pl_Set = require "pl.Set"

  local def_db_strategies = {"postgres"}
  local def_all_strategies = {"postgres", "off"}
  local env_var = os.getenv("KONG_DATABASE")
  if env_var then
    def_db_strategies = { env_var }
    def_all_strategies = { env_var }
  end
  local db_available_strategies = pl_Set(def_db_strategies)
  local all_available_strategies = pl_Set(def_all_strategies)

  local function iter(strategies, i)
    i = i + 1
    local strategy = strategies[i]
    if strategy then
      return i, strategy
    end
  end

  each_strategy = function(strategies)
    if not strategies then
      return iter, def_db_strategies, 0
    end

    for i = #strategies, 1, -1 do
      if not db_available_strategies[strategies[i]] then
        table.remove(strategies, i)
      end
    end
    return iter, strategies, 0
  end

  all_strategies = function(strategies)
    if not strategies then
      return iter, def_all_strategies, 0
    end

    for i = #strategies, 1, -1 do
      if not all_available_strategies[strategies[i]] then
        table.remove(strategies, i)
      end
    end
    return iter, strategies, 0
  end
end


local function truncate_tables(db, tables)
  if not tables then
    return
  end

  for _, t in ipairs(tables) do
    if db[t] and db[t].schema then
      db[t]:truncate()
    end
  end
end


local function bootstrap_database(db)
  local schema_state = assert(db:schema_state())

  if schema_state.needs_bootstrap then
    assert(db:schema_bootstrap())
    schema_state = assert(db:schema_state())
  end

  if schema_state.new_migrations then
    assert(db:run_migrations(schema_state.new_migrations, {
      run_up = true,
      run_teardown = true,
    }))
  end
end


--- Gets the database utility helpers and prepares the database for a testrun.
-- This will a.o. bootstrap the datastore and truncate the existing data that
-- migth be in it. The BluePrint and DB objects returned can be used to create
-- test entities in the database.
--
-- So the difference between the `db` and `bp` is small. The `db` one allows access
-- to the datastore for creating entities and inserting data. The `bp` one is a
-- wrapper around the `db` one. It will auto-insert some stuff and check for errors;
--
-- - if you create a route using `bp`, it will automatically attach it to the
--   default service that it already created, without you having to specify that
--   service.
-- - any errors returned by `db`, which will be `nil + error` in Lua, will be
--   wrapped in an assertion by `bp` so if something is wrong it will throw a hard
--   error which is convenient when testing. When using `db` you have to manually
--   check for errors.
--
-- Since `bp` is a wrapper around `db` it will only know about the Kong standard
-- entities in the database. Hence the `db` one should be used when working with
-- custom DAO's for which no `bp` entry is available.
-- @function get_db_utils
-- @param strategy (optional) the database strategy to use, will default to the
-- strategy in the test configuration.
-- @param tables (optional) tables to truncate, this can be used to accelarate
-- tests if only a few tables are used. By default all tables will be truncated.
-- @param plugins (optional) array of plugins to mark as loaded. Since kong will
-- load all the bundled plugins by default, this is useful mostly for marking
-- custom plugins as loaded.
-- @param vaults (optional) vault configuration to use.
-- @param skip_migrations (optional) if true, migrations will not be run.
-- @return BluePrint, DB
-- @usage
-- local PLUGIN_NAME = "my_fancy_plugin"
-- local bp = helpers.get_db_utils("postgres", nil, { PLUGIN_NAME })
--
-- -- Inject a test route. No need to create a service, there is a default
-- -- service which will echo the request.
-- local route1 = bp.routes:insert({
--   hosts = { "test1.com" },
-- })
-- -- add the plugin to test to the route we created
-- bp.plugins:insert {
--   name = PLUGIN_NAME,
--   route = { id = route1.id },
--   config = {},
-- }
local function get_db_utils(strategy, tables, plugins, vaults, skip_migrations, expand_foreigns)
  strategy = strategy or conf.database
  conf.database = strategy  -- overwrite kong.configuration.database

  if tables ~= nil and type(tables) ~= "table" then
    error("arg #2 must be a list of tables to truncate", 2)
  end
  if plugins ~= nil and type(plugins) ~= "table" then
    error("arg #3 must be a list of plugins to enable", 2)
  end

  if plugins then
    for _, plugin in ipairs(plugins) do
      conf.loaded_plugins[plugin] = true
    end
  end

  if vaults ~= nil and type(vaults) ~= "table" then
    error("arg #4 must be a list of vaults to enable", 2)
  end

  if vaults then
    for _, vault in ipairs(vaults) do
      conf.loaded_vaults[vault] = true
    end
  end

  -- Clean workspaces from the context - otherwise, migrations will fail,
  -- as some of them have dao calls
  -- If `no_truncate` is falsey, `dao:truncate` and `db:truncate` are called,
  -- and these set the workspace back again to the new `default` workspace
  ngx.ctx.workspace = nil

  -- DAO (DB module)
  local db = assert(DB.new(conf, strategy))
  assert(db:init_connector())

  if not skip_migrations then
    -- Drop all schema and data
    assert(db:schema_reset())
    bootstrap_database(db)
  end

  db:truncate("plugins")
  assert(db.plugins:load_plugin_schemas(conf.loaded_plugins))
  assert(db.vaults:load_vault_schemas(conf.loaded_vaults))

  db:truncate("tags")

  _G.kong.db = db

  -- cleanup tables
  if not tables then
    assert(db:truncate())

  else
    tables[#tables + 1] = "workspaces"
    truncate_tables(db, tables)
  end

  -- blueprints
  local bp
  if strategy ~= "off" then
    bp = assert(Blueprints.new(db))
    dcbp = nil
  else
    bp = assert(dc_blueprints.new(db, expand_foreigns))
    dcbp = bp
  end

  if plugins then
    for _, plugin in ipairs(plugins) do
      conf.loaded_plugins[plugin] = false
    end
  end

  if vaults then
    for _, vault in ipairs(vaults) do
      conf.loaded_vaults[vault] = false
    end
  end

  if strategy ~= "off" then
    local workspaces = require "kong.workspaces"
    workspaces.upsert_default(db)
  end

  -- calculation can only happen here because this function
  -- initializes the kong.db instance
  PLUGINS_LIST = assert(kong.db.plugins:get_handlers())
  table.sort(PLUGINS_LIST, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  PLUGINS_LIST = pl_tablex.map(function(p)
    return { name = p.name, version = p.handler.VERSION, }
  end, PLUGINS_LIST)

  return bp, db
end


local function get_dcbp()
  return dcbp
end


local function get_plugins_list()
  return PLUGINS_LIST
end


-- returns the plugins and version list that is used by Hybrid mode tests
local function clone_plugins_list()
  assert(PLUGINS_LIST, "plugin list has not been initialized yet, " ..
                       "you must call get_db_utils first")
  return table_clone(PLUGINS_LIST)
end


local validate_plugin_config_schema
do
  local consumers_schema_def = require("kong.db.schema.entities.consumers")
  local services_schema_def = require("kong.db.schema.entities.services")
  local plugins_schema_def = require("kong.db.schema.entities.plugins")
  local routes_schema_def = require("kong.db.schema.entities.routes")
  local Schema = require("kong.db.schema")
  local Entity = require("kong.db.schema.entity")
  local uuid = require("kong.tools.uuid").uuid

  -- Prepopulate Schema's cache
  Schema.new(consumers_schema_def)
  Schema.new(services_schema_def)
  Schema.new(routes_schema_def)

  local plugins_schema = assert(Entity.new(plugins_schema_def))

  --- Validate a plugin configuration against a plugin schema.
  -- @function validate_plugin_config_schema
  -- @param config The configuration to validate. This is not the full schema,
  -- only the `config` sub-object needs to be passed.
  -- @param schema_def The schema definition
  -- @return the validated schema, or nil+error
  validate_plugin_config_schema = function(config, schema_def, extra_fields)
    assert(plugins_schema:new_subschema(schema_def.name, schema_def))
    local entity = {
      id = uuid(),
      name = schema_def.name,
      config = config
    }

    if extra_fields then
      for k, v in pairs(extra_fields) do
        entity[k] = v
      end
    end

    local entity_to_insert, err = plugins_schema:process_auto_fields(entity, "insert")
    if err then
      return nil, err
    end
    local _, err = plugins_schema:validate_insert(entity_to_insert)
    if err then return
      nil, err
    end
    return entity_to_insert
  end
end


return {
  db = db,
  blueprints = blueprints,

  get_dcbp = get_dcbp,
  get_plugins_list = get_plugins_list,
  clone_plugins_list = clone_plugins_list,

  get_cache = get_cache,
  get_db_utils = get_db_utils,

  truncate_tables = truncate_tables,
  bootstrap_database = bootstrap_database,

  each_strategy = each_strategy,
  all_strategies = all_strategies,

  validate_plugin_config_schema = validate_plugin_config_schema,
}
