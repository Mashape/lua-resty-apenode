local tracing_context     = require "kong.observability.tracing.tracing_context"
local table_new           = require "table.new"

local formats             = require "kong.observability.tracing.propagation.utils".FORMATS

local clear_header        = kong.service.request.clear_header
local ngx_req_get_headers = ngx.req.get_headers
local table_insert        = table.insert
local null                = ngx.null
local type = type
local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable

local EXTRACTORS_PATH = "kong.observability.tracing.propagation.extractors."
local INJECTORS_PATH  = "kong.observability.tracing.propagation.injectors."


-- This function retrieves the propagation parameters from a plugin
-- configuration, converting legacy parameters to their new locations.
local function get_plugin_params(config)
  local propagation_config = config.propagation or table_new(0, 3)

  -- detect if any of the new fields was set (except for
  -- default_format, which is required) and if so just return
  -- the propagation configuration as is.
  -- This also ensures that warnings are only logged once (per worker).
  for k, v in pairs(propagation_config) do
    if k ~= "default_format" and (v or null) ~= null then
      return propagation_config
    end
  end

  if (config.default_header_type or null) ~= null then
    propagation_config.default_format = config.default_header_type
  end

  if (config.header_type or null) ~= null then
    if config.header_type == "preserve" then
      -- configure extractors to match what used to be the harcoded
      -- order of extraction in the old propagation module
      propagation_config.extract = {
        formats.B3,
        formats.W3C,
        formats.JAEGER,
        formats.OT,
        formats.DATADOG,
        formats.AWS,
        formats.GCP,
        formats.INSTANA
      }
      propagation_config.inject = { "preserve" }

    elseif config.header_type == "ignore" then
      propagation_config.inject = { propagation_config.default_format }

    else
      propagation_config.extract = {
        formats.B3,
        formats.W3C,
        formats.JAEGER,
        formats.OT,
        formats.DATADOG,
        formats.AWS,
        formats.GCP,
        formats.INSTANA,
      }
      propagation_config.inject = {
        -- the old logic used to propagate the "found" incoming format
        "preserve",
        config.header_type
      }
    end
  end

  return propagation_config
end


-- Extract tracing data from incoming tracing headers
-- @param table conf propagation configuration
-- @return table|nil Extracted tracing context
local function extract_tracing_context(conf)
  local extracted_ctx = {}
  local headers = ngx_req_get_headers()

  local extractors = conf.extract
  if not extractors then
    -- configuring no extractors is valid to disable
    -- context extraction from incoming tracing headers
    return extracted_ctx
  end

  for _, extractor_m in ipairs(extractors) do
    local extractor = require(EXTRACTORS_PATH .. extractor_m)

    extracted_ctx = extractor:extract(headers)

    -- extract tracing context only from the first successful extractor
    if type(extracted_ctx) == "table" and next(extracted_ctx) ~= nil then
      kong.ctx.plugin.extracted_from = extractor_m
      break
    end
  end

  return extracted_ctx
end


-- Clear tracing headers from the request
local function clear_tracing_headers(propagation_conf)
  local headers = propagation_conf.clear
  if not headers or next(headers) == nil then
    return
  end

  for _, header in ipairs(headers) do
    clear_header(header)
  end
end


-- Inject tracing context into outgoing requests
-- @param table conf propagation configuration
-- @param table inject_ctx The tracing context to inject
local function inject_tracing_context(propagation_conf, inject_ctx)
  local injectors = propagation_conf.inject
  if not injectors then
    -- configuring no injectors is valid to disable
    -- context injection in outgoing requests
    return
  end

  local err = {}
  local trace_id_formats
  for _, injector_m in ipairs(injectors) do
    if injector_m == "preserve" then
      -- preserve the incoming tracing header type
      injector_m = kong.ctx.plugin.extracted_from or propagation_conf.default_format or formats.W3C

      -- "preserve" mappings:
      -- b3 has one extractor and 2 injectors to handle single and multi-header
      if injector_m == formats.B3 and inject_ctx.single_header then
        injector_m = formats.B3_SINGLE
      end
    end

    local injector = require(INJECTORS_PATH .. injector_m)

    -- pass inject_ctx_instance to avoid modifying the original
    local inject_ctx_instance = setmetatable({}, { __index = inject_ctx })
    -- inject tracing context information in outgoing headers
    -- and obtain the formatted trace_id
    local formatted_trace_id, injection_err = injector:inject(inject_ctx_instance)
    if formatted_trace_id then
      trace_id_formats = tracing_context.add_trace_id_formats(formatted_trace_id)
    else
      table_insert(err, injection_err)
    end
  end

  if #err > 0 then
    return nil, table.concat(err, ", ")
  end
  return trace_id_formats
end


--- Propagate tracing headers.
--
-- This function takes care of extracting, clearing and injecting tracing
-- headers according to the provided configuration. It also allows for
-- plugin-specific logic to be executed via a callback between the extraction
-- and injection steps.
--
-- @function propagate
-- @param table propagation_conf The plugin's propagation configuration
--  this should use `get_plugin_params` to obtain the propagation configuration
--  from the plugin's configuration.
-- @param function get_inject_ctx_cb The callback function to apply
--  plugin-specific transformations to the extracted tracing context. It is
--  expected to return a table with the data to be injected in the outgoing
--  tracing headers. get_inject_ctx_cb receives the extracted tracing context
--  as its only argument, which is a table with a structure as defined in the
--  extractor base class.
-- @param variable_args Additional arguments to be passed to the callback
--
-- @usage
-- propagation.propagate(
--   propagation.get_plugin_params(conf),
--   function(extract_ctx)
--     -- plugin-specific logic to obtain the data to be injected
--     return get_inject_ctx(conf, extract_ctx, other_args)
--   end
-- )
local function propagate(propagation_conf, get_inject_ctx_cb, ...)
  -- Tracing context Extraction:
  local extract_ctx, extract_err = extract_tracing_context(propagation_conf)
  if extract_err then
    kong.log.err("failed to extract tracing context: ", extract_err)
  end
  extract_ctx = extract_ctx or {}

  -- Obtain the inject ctx (outgoing tracing headers data). The logic
  -- for this is plugin-specific, defined in the get_inject_ctx_cb callback.
  local inject_ctx = extract_ctx
  if get_inject_ctx_cb then
    inject_ctx = get_inject_ctx_cb(extract_ctx, ...)
  end

  -- Clear headers:
  clear_tracing_headers(propagation_conf)

  -- Tracing context Injection:
  local trace_id_formats, injection_err =
      inject_tracing_context(propagation_conf, inject_ctx)
  if trace_id_formats then
    kong.log.set_serialize_value("trace_id", trace_id_formats)
  elseif injection_err then
    kong.log.err(injection_err)
  end
end


return {
  extract           = extract_tracing_context,
  inject            = inject_tracing_context,
  clear             = clear_tracing_headers,
  propagate         = propagate,
  get_plugin_params = get_plugin_params,
}
