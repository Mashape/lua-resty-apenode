local _M = {
  -- these filter lookup tables are created once and then reset/re-used when
  -- `wasm.init()` is called. This means other modules are permitted to stash
  -- a reference to them, which helps to avoid several chicken/egg dependency
  -- ordering issues.

  ---@type kong.configuration.wasm_filter[]
  filters = {},

  ---@type table<string, kong.configuration.wasm_filter>
  filters_by_name = {},

  ---@type string[]
  filter_names = {},

  ---@type table<string, kong.runloop.wasm.filter_meta>
  filter_meta = {},
}


--- This represents a wasm module discovered by the conf_loader in
--- `kong.configuration.wasm_filters_path`
---
---@class kong.configuration.wasm_filter
---
---@field name string
---@field path string


local uuid = require "kong.tools.uuid"
local reports = require "kong.reports"
local clear_tab = require "table.clear"
local cjson = require "cjson.safe"
local json_schema = require "kong.db.schema.json"
local pl_file = require "pl.file"
local pl_path = require "pl.path"
local constants = require "kong.constants"
local properties = require "kong.runloop.wasm.properties"


---@module 'resty.wasmx.proxy_wasm'
local proxy_wasm

local kong = _G.kong
local ngx = ngx
local null = ngx.null
local log = ngx.log
local DEBUG = ngx.DEBUG
local ERR = ngx.ERR
local CRIT = ngx.CRIT
local tostring = tostring
local ipairs = ipairs
local type = type
local assert = assert
local insert = table.insert
local sort = table.sort
local cjson_encode = cjson.encode
local cjson_decode = cjson.decode
local fmt = string.format


local VERSION_KEY = "filter_chains:version"
local TTL_ZERO = { ttl = 0 }
local GLOBAL_QUERY_OPTS = { workspace = null, show_ws_id = true }

---@class kong.runloop.wasm.filter_meta
---
---@field config_schema kong.db.schema.json.schema_doc|nil
---@field metrics table|nil

local FILTER_META_SCHEMA = {
  type = "object",
  properties = {
    config_schema = json_schema.metaschema,
    metrics = {
      type = "object",
      properties = {
        label_patterns = {
          type = "array",
          items = {
            type = "object",
            required = { "label", "pattern" },
            properties = {
              label = { type = "string" },
              pattern = { type = "string" },
            }
          }
        }
      }
    }
  },
}


---
-- Fetch the current version of the filter chain state from cache
--
---@return string
local function get_version()
  return kong.core_cache:get(VERSION_KEY, TTL_ZERO, uuid.uuid)
end


---@alias kong.wasm.filter_chain_type
---| 0 # service
---| 1 # route
---| 2 # combined

local TYPE_SERVICE  = 0
local TYPE_ROUTE    = 1
local TYPE_COMBINED = 2

local STATUS_DISABLED = "wasm support is not enabled"
local STATUS_NO_FILTERS = "no wasm filters are available"
local STATUS_ENABLED = "wasm support is enabled"

local ENABLED = false
local STATUS = STATUS_DISABLED

local function filter_plugin_compare(a, b)
  if a.name ~= b.name then
    return a.name < b.name
  end

  if a.updated_at and b.updated_at and a.updated_at ~= b.updated_at then
    return a.updated_at < b.updated_at
  end

  if a.created_at and b.created_at and a.created_at ~= b.created_at then
    return a.created_at < b.created_at
  end

  return a.id < b.id
end

local hash_chain
do
  local buffer = require "string.buffer"

  local sha256 = require("kong.tools.sha256").sha256_bin

  local HASH_DISABLED = sha256("disabled")
  local HASH_NONE     = sha256("none")

  local buf = buffer.new()

  ---@param chain kong.db.schema.entities.filter_chain
  ---@return string
  local function hash_chain_entity(chain)
    if not chain then
      return HASH_NONE

    elseif not chain.enabled then
      return HASH_DISABLED
    end

    local filters = chain.filters
    for i = 1, #filters do
      local filter = filters[i]

      buf:put(filter.name)
      buf:put(tostring(filter.enabled))
      buf:put(tostring(filter.enabled and sha256(filter.config)))
    end

    local s = buf:get()

    buf:reset()

    return sha256(s)
  end

  ---
  -- Generate a hash key for a filter chain from a service
  -- and route filter chain [entity] combo.
  --
  -- The result of this is used to invalidate cached filter chain
  -- plans.
  --
  ---@param service? kong.db.schema.entities.filter_chain
  ---@param route?   kong.db.schema.entities.filter_chain
  ---@return string
  function hash_chain(service, route)
    assert(service ~= nil or route ~= nil,
           "hash_chain() called with neither service nor route")

    return sha256(hash_chain_entity(service) .. hash_chain_entity(route))
  end
end


---@class kong.runloop.wasm.filter_chain_reference
---
---@field type          kong.wasm.filter_chain_type
---@field label         string
---@field hash          string
---@field c_plan        ffi.cdata*|nil
---
---@field service_chain kong.db.schema.entities.filter_chain|nil
---@field service_id    string|nil
---
---@field route_chain   kong.db.schema.entities.filter_chain|nil
---@field route_id      string|nil


---@class kong.runloop.wasm.state
local STATE = {
  -- mapping of service IDs to service filter chains
  --
  ---@type table<string, kong.runloop.wasm.filter_chain_reference>
  by_service = {},

  -- mapping of route IDs to route filter chains
  --
  ---@type table<string, kong.runloop.wasm.filter_chain_reference>
  by_route = {},

  -- two level mapping: the top level is indexed by service ID, and the
  -- secondary level is indexed by route ID
  --
  ---@type table<string, table<string, kong.runloop.wasm.filter_chain_reference>>
  combined = {},

  version = -1,
}


---
-- Initialize and return a filter chain plan from a list of filters.
--
---@param filters kong.db.schema.entities.wasm_filter[]|nil
---@return ffi.cdata*? c_plan
---@return string?     error
local function init_c_plan(filters)
  if not filters then
    return
  end

  local c_plan, err = proxy_wasm.new(filters)
  if not c_plan then
    return nil, "failed instantiating filter chain: "
                .. tostring(err)
  end

  local ok
  ok, err = proxy_wasm.load(c_plan)
  if not ok then
    return nil, "failed loading filters: " .. tostring(err)
  end

  return c_plan
end


-- Helper method for retrieving a filter chain reference from
-- the state table.
--
---@param state       kong.runloop.wasm.state
---@param typ         kong.wasm.filter_chain_type
---@param service_id? string
---@param route_id?   string
---
---@return kong.runloop.wasm.filter_chain_reference? ref
local function get_chain_ref(state, typ, service_id, route_id)
  local ref

  if typ == TYPE_SERVICE and service_id then
    ref = state.by_service[service_id]

  elseif typ == TYPE_ROUTE and route_id then
    ref = state.by_route[route_id]

  elseif typ == TYPE_COMBINED and service_id and route_id then
    local routes = state.combined[service_id]
    ref = routes and routes[route_id]

  else
    -- unreachable
    error("unknown filter chain type: " .. tostring(typ), 2)
  end

  return ref
end


---
-- Helper method for storing a new filter chain reference within
-- the state table.
--
---@param state       kong.runloop.wasm.state
---@param ref         kong.runloop.wasm.filter_chain_reference
local function store_chain_ref(state, ref)
  local typ = ref.type
  local service_id = ref.service_id
  local route_id = ref.route_id

  if typ == TYPE_SERVICE then
    assert(type(service_id) == "string",
           ref.label .. " chain has no service ID")

    state.by_service[service_id] = ref

  elseif typ == TYPE_ROUTE then
    assert(type(route_id) == "string",
           ref.label .. " chain has no route ID")

    state.by_route[route_id] = ref

  elseif typ == TYPE_COMBINED then
    assert(type(service_id) == "string" and type(route_id) == "string",
           ref.label .. " chain is missing a service ID or route ID")

    local routes = state.combined[service_id]

    if not routes then
      routes = {}
      state.combined[service_id] = routes
    end

    routes[route_id] = ref

  else
    -- unreachable
    error("unknown filter chain type: " .. tostring(typ), 2)
  end
end


---
-- Create a log-friendly string label for a filter chain reference.
--
---@param service_id? string
---@param route_id?   string
---@return string label
local function label_for(service_id, route_id)
  if service_id and route_id then
    return "combined " ..
           "service(" .. service_id .. "), " ..
           "route(" .. route_id .. ")"

  elseif service_id then
    return "service(" .. service_id .. ")"

  elseif route_id then
    return "route(" .. route_id .. ")"

  else
    -- unreachable
    error("can't compute a label for a filter chain with no route/service", 2)
  end
end


---
-- Build a combined filter list from 1-2 filter chain entities.
--
-- Disabled filter chains are skipped, and disabled filters are
-- skipped.
--
-- Returns `nil` if no enabled filters are found.
--
---@param service_chain? kong.db.schema.entities.filter_chain
---@param route_chain?   kong.db.schema.entities.filter_chain
---
---@return kong.db.schema.entities.wasm_filter[]?
local function build_filter_list(service_chain, route_chain)
  ---@type kong.db.schema.entities.wasm_filter[]|nil
  local combined
  local n = 0

  if service_chain and service_chain.enabled then
    for _, filter in ipairs(service_chain.filters) do
      if filter.enabled then
        n = n + 1
        combined = combined or {}
        combined[n] = filter
      end
    end
  end

  if route_chain and route_chain.enabled then
    for _, filter in ipairs(route_chain.filters) do
      if filter.enabled then
        n = n + 1
        combined = combined or {}
        combined[n] = filter
      end
    end
  end

  return combined
end


---@param config any
---@return string|nil
local function serialize_configuration(config)
  -- Serialize all JSON configurations up front
  --
  -- NOTE: there is a subtle difference between a raw, non-JSON filter
  -- configuration which requires no encoding (e.g. `my config bytes`)
  -- and a JSON filter configuration of type=string, which should be
  -- JSON-encoded (e.g. `"my config string"`).
  --
  -- Properly disambiguating between the two cases requires an
  -- inspection of the filter metadata, which is not guaranteed to be
  -- present on data-plane/proxy nodes.
  if config ~= nil and type(config) ~= "string" then
    return cjson_encode(config)
  end

  return config
end


---@param chain kong.db.schema.entities.filter_chain
local function get_or_insert_chain(chains, chain)
  local route_id = chain.route and chain.route.id
  local service_id = chain.service and chain.service.id

  local chain_type = service_id and TYPE_SERVICE or TYPE_ROUTE
  local id = service_id or route_id

  -- already exists
  if chains.by_id[chain_type][id] then
    return chains.by_id[chain_type][id]
  end

  chains.by_id[chain_type][id] = chain

  if chain_type == TYPE_ROUTE then
    insert(chains.route_chains, chain)
  end

  insert(chains.all_chain_refs, {
    type           = chain_type,

    service_chain  = (chain_type == TYPE_SERVICE and chain) or nil,
    service_id     = service_id,

    route_chain    = (chain_type == TYPE_ROUTE and chain) or nil,
    route_id       = route_id,
  })

  return chain
end


---
-- Unconditionally rebuild and return a new wasm state table from the db.
--
---@param  db                       table # kong.db
---@param  version                  any
---@param  old_state                kong.runloop.wasm.state
---@return kong.runloop.wasm.state? new_state
---@return string?                  err
local function rebuild_state(db, version, old_state)
  ---@type kong.db.schema.entities.filter_chain[]
  local route_chains = {}

  ---@type table<string, kong.db.schema.entities.filter_chain>
  local service_chains_by_id = {}

  ---@type kong.runloop.wasm.state
  local state = {
    by_service = {},
    by_route = {},
    combined = {},
    version = version,
  }

  ---@type kong.runloop.wasm.filter_chain_reference[]
  local all_chain_refs = {}

  local chains = {
    all_chain_refs = all_chain_refs,
    by_id = {
      [TYPE_SERVICE] = service_chains_by_id,
      [TYPE_ROUTE] = {},
    },
    route_chains = route_chains,
  }

  local page_size = db.filter_chains.max_page_size

  for chain, err in db.filter_chains:each(page_size) do
    if err then
      return nil, "failed iterating filter chains: " .. tostring(err)
    end

    if chain.enabled then
      for _, filter in ipairs(chain.filters) do
        if filter.enabled then
          filter.config = serialize_configuration(filter.config)
        end
      end

      get_or_insert_chain(chains, chain)
    end
  end

  local plugin_pagesize = db.plugins.pagination.max_page_size

  local filter_plugins = {}

  for plugin, err in db.plugins:each(plugin_pagesize, GLOBAL_QUERY_OPTS) do
    if err then
      return nil, "failed iterating plugins: " .. tostring(err)
    end

    if _M.filters_by_name[plugin.name] and plugin.enabled then
      insert(filter_plugins, plugin)
    end
  end

  sort(filter_plugins, filter_plugin_compare)

  for _, plugin in ipairs(filter_plugins) do
    local chain = get_or_insert_chain(chains, {
      id = uuid.uuid(),
      enabled = true,
      route = plugin.route,
      service = plugin.service,
      filters = {},
    })

    insert(chain.filters, {
      name = plugin.name,
      enabled = true,
      config = serialize_configuration(plugin.config),
    })
  end

  local routes = db.routes
  local select_route = routes.select

  -- the only cache lookups here are for route entities,
  -- so use the core cache
  local cache = kong.core_cache


  -- locate matching route/service chain entities to build combined
  -- filter chain references
  for _, route_chain in ipairs(route_chains) do
    local cache_key = routes:cache_key(route_chain.route.id)

    local route, err = cache:get(cache_key, nil,
                                 select_route, routes, route_chain.route)

    if err then
      return nil, "failed to load route for filter chain " ..
                  route_chain.id .. ": " .. tostring(err)
    end

    local service_id = route and route.service and route.service.id
    local service_chain = service_id and service_chains_by_id[service_id]

    if service_chain then
      insert(all_chain_refs, {
        type           = TYPE_COMBINED,

        service_chain  = service_chain,
        service_id     = service_id,

        route_chain    = route_chain,
        route_id       = route.id,
      })
    end
  end

  for _, chain_ref in ipairs(all_chain_refs) do
    local service_id = chain_ref.service_id
    local route_id = chain_ref.route_id

    local new_chain_hash = hash_chain(chain_ref.service_chain, chain_ref.route_chain)
    local old_ref = get_chain_ref(old_state, chain_ref.type, service_id, route_id)
    local new_ref

    if old_ref then
      if old_ref.hash == new_chain_hash then
        new_ref = old_ref
        log(DEBUG, old_ref.label, ": reusing existing filter chain reference")

      else
        log(DEBUG, old_ref.label, ": filter chain has changed and will be rebuilt")
      end
    end


    if not new_ref then
      new_ref = chain_ref
      new_ref.label = label_for(service_id, route_id)

      local filters = build_filter_list(chain_ref.service_chain, chain_ref.route_chain)
      local c_plan, err = init_c_plan(filters)

      if err then
        return nil, "failed to initialize " .. new_ref.label ..
                    " filter chain: " .. tostring(err)

      elseif not c_plan then
        log(DEBUG, new_ref.label, " filter chain has no enabled filters")
      end

      new_ref.hash = new_chain_hash
      new_ref.c_plan = c_plan
    end

    store_chain_ref(state, new_ref)
  end

  return state
end


---
-- Replace the current filter chain state with a new one.
--
-- This function does not do any I/O or other yielding operations.
--
---@param new kong.runloop.wasm.state
local function set_state(new)
  if type(new) ~= "table" then
    error("bad argument #1 to 'set_state' (table expected, got " ..
          type(new) .. ")", 2)
  end

  local old = STATE

  if old.version == new.version then
    log(DEBUG, "called with new version that is identical to the last")
  end

  STATE = new
end


---
-- Conditionally rebuild and update the filter chain state.
--
-- If the current state matches the desired version, no update
-- will be performed.
--
---@param  new_version? string
---@return boolean?     ok
---@return string?      error
local function update_in_place(new_version)
  if not ENABLED then
    return true
  end

  new_version = new_version or get_version()
  local old = STATE

  if new_version == old.version then
    log(DEBUG, "filter chain state is already up-to-date, no changes needed")
    return true
  end

  local new, err = rebuild_state(kong.db, new_version, old)
  if not new then
    log(ERR, "failed rebuilding filter chain state: ", err)
    return nil, err
  end

  set_state(new)

  return true
end


---@param route?    { id: string }
---@param service?  { id: string }
---@return kong.runloop.wasm.filter_chain_reference?
local function get_filter_chain_for_request(route, service)
  local service_id = service and service.id
  local route_id = route and route.id
  local state = STATE

  return get_chain_ref(state, TYPE_COMBINED, service_id, route_id)
      or get_chain_ref(state, TYPE_SERVICE, service_id)
      or get_chain_ref(state, TYPE_ROUTE, nil, route_id)
end


---@param filters kong.configuration.wasm_filter[]|nil
local function discover_filter_metadata(filters)
  if not filters then return end

  local errors = {}

  for _, filter in ipairs(filters) do
    local meta_path = (filter.path:gsub("%.wasm$", "")) .. ".meta.json"

    local function add_error(reason, err)
      table.insert(errors, fmt("* %s (%s) %s: %s", filter.name, meta_path, reason, err))
    end

    if pl_path.exists(meta_path) then
      if pl_path.isfile(meta_path) then
        local data, err = pl_file.read(meta_path)

        if data then
          local meta
          meta, err = cjson_decode(data)

          if err then
            add_error("JSON decode error", err)

          else
            local ok
            ok, err = json_schema.validate(meta, FILTER_META_SCHEMA)
            if ok then
              _M.filter_meta[filter.name] = meta

            else
              add_error("file contains invalid metadata", err)
            end
          end

        else
          add_error("I/O error", err)
        end

      else
        add_error("invalid type", "path exists but is not a file")
      end
    end
  end

  if #errors > 0 then
    local err = "\nFailed to load metadata for one or more filters:\n"
                .. table.concat(errors, "\n") .. "\n"

    error(err)
  end

  local namespace = constants.SCHEMA_NAMESPACES.PROXY_WASM_FILTERS
  for name, meta in pairs(_M.filter_meta) do
    if meta.config_schema then
      local schema_name = namespace .. "/" .. name
      meta.config_schema["$schema"] = json_schema.DRAFT_4
      json_schema.add_schema(schema_name, meta.config_schema)
    end
  end
end


---@param filters kong.configuration.wasm_filter[]|nil
local function set_available_filters(filters)
  clear_tab(_M.filters)
  clear_tab(_M.filters_by_name)
  clear_tab(_M.filter_names)
  clear_tab(_M.filter_meta)

  if filters then
    for i, filter in ipairs(filters) do
      _M.filters[i] = filter
      _M.filters_by_name[filter.name] = filter
      _M.filter_names[i] = filter.name
    end

    discover_filter_metadata(filters)
  end
end


---@param reason string
local function disable(reason)
  set_available_filters(nil)

  _G.dns_client = nil

  ENABLED = false
  STATUS = reason or STATUS_DISABLED
end


local function register_property_handlers()
  properties.reset()

  properties.add_getter("kong.client.protocol", function(kong)
    return true, kong.client.get_protocol(), true
  end)

  properties.add_getter("kong.nginx.subsystem", function(kong)
    return true, kong.nginx.get_subsystem(), true
  end)

  properties.add_getter("kong.node.id", function(kong)
    return true, kong.node.get_id(), true
  end)

  properties.add_getter("kong.node.memory_stats", function(kong)
    local stats = kong.node.get_memory_stats()
    if not stats then
      return false
    end
    return true, cjson_encode(stats), false
  end)

  properties.add_getter("kong.request.forwarded_host", function(kong)
    return true, kong.request.get_forwarded_host(), true
  end)

  properties.add_getter("kong.request.forwarded_port", function(kong)
    return true, kong.request.get_forwarded_port(), true
  end)

  properties.add_getter("kong.request.forwarded_scheme", function(kong)
    return true, kong.request.get_forwarded_scheme(), true
  end)

  properties.add_getter("kong.request.port", function(kong)
    return true, kong.request.get_port(), true
  end)

  properties.add_getter("kong.response.source", function(kong)
    return true, kong.request.get_source(), false
  end)

  properties.add_setter("kong.response.status", function(kong, _, _, status)
    return true, kong.response.set_status(tonumber(status)), false
  end)

  properties.add_getter("kong.router.route", function(kong)
    local route = kong.router.get_route()
    if not route then
      return true, nil, true
    end
    return true, cjson_encode(route), true
  end)

  properties.add_getter("kong.router.service", function(kong)
    local service = kong.router.get_service()
    if not service then
      return true, nil, true
    end
    return true, cjson_encode(service), true
  end)

  properties.add_setter("kong.service.target", function(kong, _, _, target)
    local host, port = target:match("^(.*):([0-9]+)$")
    port = tonumber(port)
    if not (host and port) then
      return false
    end

    kong.service.set_target(host, port)
    return true, target, false
  end)

  properties.add_setter("kong.service.upstream", function(kong, _, _, upstream)
    local ok, err = kong.service.set_upstream(upstream)
    if not ok then
      kong.log.err(err)
      return false
    end

    return true, upstream, false
  end)

  properties.add_setter("kong.service.request.scheme", function(kong, _, _, scheme)
    kong.service.request.set_scheme(scheme)
    return true, scheme, false
  end)

  properties.add_getter("kong.route_id", function(_, _, ctx)
    local value = ctx.route and ctx.route.id
    local ok = value ~= nil
    local const = ok
    return ok, value, const
  end)

  properties.add_getter("kong.route_name", function(_, _, ctx)
    local value = ctx.route and ctx.route.name
    local ok = value ~= nil
    local const = ok
    return ok, value, const
  end)

  properties.add_getter("kong.service.response.status", function(kong)
    return true, kong.service.response.get_status(), false
  end)

  properties.add_getter("kong.service_id", function(_, _, ctx)
    local value = ctx.service and ctx.service.id
    local ok = value ~= nil
    local const = ok
    return ok, value, const
  end)

  properties.add_getter("kong.service_name", function(_, _, ctx)
    local value = ctx.service and ctx.service.name
    local ok = value ~= nil
    local const = ok
    return ok, value, const
  end)

  properties.add_getter("kong.version", function(kong)
    return true, kong.version, true
  end)

  properties.add_namespace_handlers("kong.ctx.shared",
    function(kong, _, _, key)
      local value = kong.ctx.shared[key]
      local ok = value ~= nil
      value = ok and tostring(value) or nil
      return ok, value, false
    end,

    function(kong, _, _, key, value)
      kong.ctx.shared[key] = value
      return true
    end
  )

  properties.add_namespace_handlers("kong.configuration",
    function(kong, _, _, key)
      local value = kong.configuration[key]
      if value ~= nil then
        if type(value) == "table" then
          value = cjson_decode(value)
        else
          value = tostring(value)
        end

        return true, value, true
      end

      return false
    end,

    function()
      -- kong.configuration is read-only: setter rejects all
      return false
    end
  )
end


local function enable(kong_config)
  set_available_filters(kong_config.wasm_modules_parsed)

  if not ngx.IS_CLI then
    proxy_wasm = proxy_wasm or require "resty.wasmx.proxy_wasm"
    jit.off(proxy_wasm.set_host_properties_handlers)

    register_property_handlers()
  end

  ENABLED = true
  STATUS = STATUS_ENABLED
end


_M.get_version = get_version

_M.update_in_place = update_in_place

_M.set_state = set_state

function _M.enable(filters)
  enable({
    wasm = true,
    wasm_modules_parsed = filters,
  })
end

_M.disable = disable


---@param kong_config table
function _M.init(kong_config)
  if kong_config.wasm then
    local filters = kong_config.wasm_modules_parsed

    if filters and #filters > 0 then
      reports.add_immutable_value("wasm_cnt", #filters)
      enable(kong_config)

    else
      disable(STATUS_NO_FILTERS)
    end

  else
    disable(STATUS_DISABLED)
  end
end


---@return boolean? ok
---@return string?  error
function _M.init_worker()
  if not ENABLED then
    return true
  end

  if not ngx.IS_CLI then
    _G.dns_client = kong and kong.dns

    if not _G.dns_client then
      return nil, "global kong.dns client is not initialized"
    end
  end

  local ok, err = update_in_place()
  if not ok then
    return nil, err
  end

  return true
end


---
-- Lookup and execute the filter chain that applies to the current request
-- (if any).
--
---@param ctx table # the request ngx.ctx table
function _M.attach(ctx)
  if not ENABLED then
    return
  end

  local chain = get_filter_chain_for_request(ctx.route, ctx.service)

  if not chain then
    -- no matching chain for this route/service
    return
  end

  if not chain.c_plan then
    -- all filters in this chain are disabled
    return
  end

  ctx.ran_wasm = true

  local ok, err
  if not ctx.wasm_attached then
    ctx.wasm_attached = true

    ok, err = proxy_wasm.attach(chain.c_plan)
    if not ok then
      log(CRIT, "failed attaching ", chain.label, " filter chain to request: ", err)
      return kong.response.error(500)
    end

    ok, err = proxy_wasm.set_host_properties_handlers(properties.get,
                                                      properties.set)
    if not ok then
      log(CRIT, "failed setting host property handlers: ", err)
      return kong.response.error(500)
    end
  end
end


---
-- Unconditionally rebuild and return the current filter chain state.
--
-- This function is intended to be used in conjunction with `set_state()`
-- to perform an atomic update of the filter chain state alongside other
-- node updates:
--
-- ```lua
-- local new_state, err = wasm.rebuild_state()
-- if not new_state then
--   -- handle error
-- end
--
-- -- do some other things in preparation of an update
-- -- [...]
--
--
-- -- finally, swap in the new state
-- wasm.set_state(new_state)
-- ```
--
---@return kong.runloop.wasm.state? state
---@return string? error
function _M.rebuild_state()
  -- return the default/empty state
  if not ENABLED then
    return STATE
  end

  local old = STATE
  local version = get_version()

  return rebuild_state(kong.db, version, old)
end


function _M.enabled()
  return ENABLED
end


---@return boolean? ok
---@return string? error
function _M.status()
  if not ENABLED then
    return nil, STATUS
  end

  return true
end

function _M.check_enabled_filters()
  if not ENABLED then
    return true
  end

  local enabled_filters = _M.filters_by_name

  local errs
  for chain, err in kong.db.filter_chains:each() do
    if err then
      return nil, err
    end

    for i, filter in ipairs(chain.filters) do
      if not enabled_filters[filter.name] then
        errs = errs or {}

        insert(errs, fmt("filter chain: %s, filter: #%s (%s)",
                         chain.id, i, filter.name))
      end
    end
  end

  if errs then
    return nil, "found one or more filter chain entities with filters that are "
             .. "not enabled/installed:\n" .. table.concat(errs, "\n")
  end


  return true
end

return _M
