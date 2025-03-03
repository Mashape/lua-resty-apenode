---
-- Tracer module
--
-- Application-level tracing for Kong.
--
-- @module kong.tracing

local require = require
local ffi = require "ffi"
local tablepool = require "tablepool"
local new_tab = require "table.new"
local phase_checker = require "kong.pdk.private.phases"
local tracing_context = require "kong.observability.tracing.tracing_context"

local ngx = ngx
local type = type
local error = error
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable
local getmetatable = getmetatable
local rand_bytes = require("kong.tools.rand").get_rand_bytes
local check_phase = phase_checker.check
local PHASES = phase_checker.phases
local ffi_cast = ffi.cast
local ffi_str = ffi.string
local ffi_time_unix_nano = require("kong.tools.time").time_ns
local tablepool_fetch = tablepool.fetch
local tablepool_release = tablepool.release
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR

local NOOP = function() end

local POOL_SPAN = "KONG_SPAN"
local POOL_SPAN_STORAGE = "KONG_SPAN_STORAGE"
local POOL_ATTRIBUTES = "KONG_SPAN_ATTRIBUTES"
local POOL_EVENTS = "KONG_SPAN_EVENTS"

-- must be power of 2
local SAMPLING_BYTE = 8
local SAMPLING_BITS = 8 * SAMPLING_BYTE
local BOUND_MAX = math.pow(2, SAMPLING_BITS)
local SAMPLING_UINT_PTR_TYPE = "uint" .. SAMPLING_BITS .. "_t*"
local TOO_SHORT_MESSAGE = "sampling needs trace ID to be longer than " .. SAMPLING_BYTE .. " bytes to work"

local SPAN_KIND = {
  UNSPECIFIED = 0,
  INTERNAL = 1,
  SERVER = 2,
  CLIENT = 3,
  PRODUCER = 4,
  CONSUMER = 5,
}

--- Generate trace ID
local function generate_trace_id()
  return rand_bytes(16)
end

--- Generate span ID
local function generate_span_id()
  return rand_bytes(8)
end

-- Fractions >= 1 will always sample. Fractions < 0 are treated as zero.
-- spec: https://github.com/c24t/opentelemetry-specification/blob/3b3d321865cf46364bdfb292c179b6444dc96bf9/specification/sdk-tracing.md#probability-sampler-algorithm
local function get_trace_id_based_sampler(options_sampling_rate)
  return function(trace_id, sampling_rate)
    sampling_rate = sampling_rate or options_sampling_rate

    if type(sampling_rate) ~= "number" then
      return nil, "invalid fraction"
    end

    -- always on sampler
    if sampling_rate >= 1 then
      return true
    end

    -- always off sampler
    if sampling_rate <= 0 then
      return false
    end

    -- probability sampler
    local bound = sampling_rate * BOUND_MAX

    if #trace_id < SAMPLING_BYTE then
      return nil, TOO_SHORT_MESSAGE
    end

    local truncated = ffi_cast(SAMPLING_UINT_PTR_TYPE, ffi_str(trace_id, SAMPLING_BYTE))[0]
    return truncated < bound
  end
end

-- @class span : table
--
--- Trace Context. Those IDs are all represented as bytes, and the length may vary.
-- We try best to preserve as much information as possible from the tracing context.
-- @field trace_id bytes auto generated 16 bytes ID if not designated
-- @field span_id bytes 
-- @field parent_span_id bytes
--
--- Timing. All times are in nanoseconds.
-- @field start_time_ns number
-- @field end_time_ns number
--
--- Scopes and names. Defines what the span is about.
-- TODO: service should be retrieved from kong service instead of from plugin instances. It should be the same for spans from a single request.
-- service name/top level scope is defined by plugin instances.
-- @field name string type of the span. Should be of low cardinality. Good examples are "proxy", "DNS query", "database query". Approximately operation name of DataDog.
-- resource_name of Datadog is built from attirbutes.
--
--- Other fields
-- @field should_sample boolean whether the span should be sampled
-- @field kind number TODO: Should we remove this field? It's used by OTEL and zipkin. Maybe move this to impl_specific.
-- @field attributes table extra information about the span. Attribute of OTEL or meta of Datadog.
-- TODO: @field impl_specific table implementation specific fields. For example, impl_specific.datadog is used by Datadog tracer.
-- TODO: @field events table list of events. 
--
--- Internal fields
-- @field tracer table
-- @field parent table
local span_mt = {}
span_mt.__index = span_mt

-- Noop Span
local noop_span = {}
-- Using static function instead of metatable for better performance
noop_span.is_recording = false
noop_span.finish = NOOP
noop_span.set_attribute = NOOP
noop_span.add_event = NOOP
noop_span.record_error = NOOP
noop_span.set_status = NOOP
noop_span.each_baggage_item = function() return NOOP end

setmetatable(noop_span, {
  -- Avoid noop span table being modifed
  __newindex = NOOP,
})

local function validate_span_options(options)
  if options ~= nil then
    if type(options) ~= "table" then
      error("invalid options type", 2)
    end

    if options.start_time_ns ~= nil and type(options.start_time_ns) ~= "number" then
      error("invalid start time", 2)
    end

    if options.span_kind ~= nil and type(options.span_kind) ~= "number" then
      error("invalid start kind", 2)
    end

    if options.should_sample ~= nil and type(options.should_sample) ~= "boolean" then
      error("invalid sampled", 2)
    end

    if options.attributes ~= nil and type(options.attributes) ~= "table" then
      error("invalid attributes", 2)
    end
  end
end

local function create_span(tracer, options)
  validate_span_options(options)
  options = options or {}

  local span = tablepool_fetch(POOL_SPAN, 0, 12)

  span.parent = options.parent or tracer and tracer.active_span()

  local trace_id = span.parent and span.parent.trace_id
      or options.trace_id
      or generate_trace_id()

  local sampled
  if span.parent and span.parent.should_sample ~= nil then
    sampled = span.parent.should_sample

  elseif options.should_sample ~= nil then
    sampled = options.should_sample

  else
    if not tracer then
      sampled = false

    else
      local err
      sampled, err = tracer.sampler(trace_id)

      if err then
        sampled = false
        ngx_log(ngx_ERR, "sampler failure: ", err)
      end
    end
  end

  span.parent_id = span.parent and span.parent.span_id
      or options.parent_id
  span.tracer = span.tracer or tracer
  span.span_id = generate_span_id()
  span.trace_id = trace_id
  span.kind = options.span_kind or SPAN_KIND.INTERNAL
  -- get_sampling_decision() can be used to dynamically run the sampler's logic
  -- and obtain the sampling decision for the span. This way plugins can apply
  -- their configured sampling rate dynamically. The sampled flag can then be
  -- overwritten by set_should_sample.
  span.should_sample = sampled

  setmetatable(span, span_mt)
  return span
end

local function link_span(tracer, span, name, options)
  if tracer and type(tracer) ~= "table" then
    error("invalid tracer", 2)
  end
  validate_span_options(options)

  options = options or {}

  -- cache tracer ref, to get hooks / span processer
  -- tracer ref will not be cleared when the span table released
  span.tracer = span.tracer or tracer
  -- specify span start time
  span.start_time_ns = options.start_time_ns or ffi_time_unix_nano()
  span.attributes = options.attributes
  span.name = name
  span.linked = true

  -- insert the span to ctx
  local spans = tracer.get_spans()

  local len = spans[0] + 1
  spans[len] = span
  spans[0] = len

  return span
end

local function new_span(tracer, name, options)
  if type(tracer) ~= "table" then
    error("invalid tracer", 2)
  end

  if type(name) ~= "string" or #name == 0 then
    error("invalid span name", 2)
  end

  local span = create_span(tracer, options)
  link_span(tracer, span, name, options)

  return span
end

--- Ends a Span
-- Set the end time and release the span,
-- the span table MUST not being used after ended.
--
-- @function span:finish
-- @tparam number|nil end_time_ns
-- @usage
-- span:finish()
--
-- local time = ngx.now()
-- span:finish(time * 100000000)
function span_mt:finish(end_time_ns)
  if self.end_time_ns ~= nil then
    -- span is finished, and already processed
    return
  end

  if end_time_ns ~= nil and type(end_time_ns) ~= "number" then
    error("invalid span end time", 2)
  end

  if end_time_ns and end_time_ns < self.start_time_ns then
    ngx_log(ngx_ERR, "invalid span duration: ",
        end_time_ns - self.start_time_ns, " for span: ", self.name)
    return
  end

  self.end_time_ns = end_time_ns or ffi_time_unix_nano()

  if self.active and self.tracer.active_span() == self then
    self.tracer.set_active_span(self.parent)
    self.active = nil
  end
end

--- Set an attribute to a Span
--
-- @function span:set_attribute
-- @tparam string key
-- @tparam string|number|boolean|nil value
-- @usage
-- span:set_attribute("net.transport", "ip_tcp")
-- span:set_attribute("net.peer.port", 443)
-- span:set_attribute("exception.escaped", true)
-- span:set_attribute("unset.this", nil)
function span_mt:set_attribute(key, value)
  -- key is decided by the programmer, so if it is not a string, we should
  -- error out.
  if type(key) ~= "string" then
    error("invalid key", 2)
  end

  local vtyp
  if value == nil then
   vtyp = value
  else
   vtyp = type(value)
  end

  -- TODO: any invalid type left?
  if vtyp ~= "string" and vtyp ~= "number" and vtyp ~= "boolean" and vtyp ~= "table" and vtyp ~= nil then
    -- we should not error out here, as most of the caller does not catch
    -- errors, and they are hooking to core facilities, which may cause
    -- unexpected behavior.
    ngx_log(ngx_ERR, debug.traceback("invalid span attribute value type: " .. vtyp, 2))
  end

  if self.attributes == nil then
    self.attributes = tablepool_fetch(POOL_ATTRIBUTES, 0, 4)
  end

  self.attributes[key] = value
end

--- Adds an event to a Span
--
-- @function span:add_event
-- @tparam string name Event name
-- @tparam table|nil attributes Event attributes
-- @tparam number|nil time_ns Event timestamp
function span_mt:add_event(name, attributes, time_ns)
  if type(name) ~= "string" then
    error("invalid name", 2)
  end

  if attributes ~= nil and type(attributes) ~= "table" then
    error("invalid attribute", 2)
  end

  if self.events == nil then
    self.events = tablepool_fetch(POOL_EVENTS, 4, 0)
    self.events[0] = 0
  end

  local obj = new_tab(0, 3)
  obj.name = name
  obj.time_ns = time_ns or ffi_time_unix_nano()

  if attributes then
    obj.attributes = attributes
  end

  local len = self.events[0] + 1
  self.events[len] = obj
  self.events[0] = len
end

--- Adds an error event to a Span
--
-- @function span:record_error
-- @tparam string err error string
function span_mt:record_error(err)
  if type(err) ~= "string" then
    err = tostring(err)
  end

  self:add_event("exception", {
    ["exception.message"] = err,
  })
end

--- Adds an error event to a Span
-- Status codes:
-- - `0` unset
-- - `1` ok
-- - `2` error
--
-- @function span:set_status
-- @tparam number status status code
function span_mt:set_status(status)
  if type(status) ~= "number" then
    error("invalid status", 2)
  end

  self.status = status
end

-- (internal) Release a span
-- The lifecycle of span is controlled by Kong
function span_mt:release()
  if type(self.attributes) == "table" then
    tablepool_release(POOL_ATTRIBUTES, self.attributes)
  end

  if type(self.events) == "table" then
    tablepool_release(POOL_EVENTS, self.events)
  end

  -- metabale will be cleared
  tablepool_release(POOL_SPAN, self)
end

-- (internal) compatible with Zipkin tracing headers
-- TODO: implement baggage API
function span_mt:each_baggage_item() return NOOP end

local tracer_mt = {}
tracer_mt.__index = tracer_mt

-- avoid creating multiple tracer with same name
local tracer_memo = setmetatable({}, { __mode = "k" })

local noop_tracer = {}
noop_tracer.name = "noop"
noop_tracer.start_span = function() return noop_span end
noop_tracer.create_span = function() return noop_span end
noop_tracer.get_spans = NOOP
noop_tracer.get_root_span = NOOP
noop_tracer.init_spans = NOOP
noop_tracer.link_span = NOOP
noop_tracer.active_span = NOOP
noop_tracer.set_active_span = NOOP
noop_tracer.process_span = NOOP
noop_tracer.set_should_sample = NOOP
noop_tracer.get_sampling_decision = NOOP
noop_tracer.spans_table_key = "noop"

local VALID_TRACING_PHASES = {
  ssl_cert = true,
  rewrite = true,
  access = true,
  header_filter = true,
  body_filter = true,
  log = true,
  content = true,
}

--- New Tracer
local function new_tracer(name, options)
  name = name or "default"
  local namespace = options and options.namespace or "KONG"
  local cache_key = namespace .. "_" .. name

  if tracer_memo[cache_key] then
    return tracer_memo[cache_key]
  end

  local self = {
    -- instrumentation library name
    name = name,
  }

  options = options or {}
  if options.noop then
    return noop_tracer
  end

  options.sampling_rate = options.sampling_rate or 1.0
  self.sampler = get_trace_id_based_sampler(options.sampling_rate)
  self.active_span_key = namespace .. "_" .. "active_span"
  self.spans_table_key = namespace .. "_" .. "SPANS"

  --- Get the active span
  -- Returns the root span by default
  --
  -- @function kong.tracing.active_span
  -- @phases rewrite, access, header_filter, response, body_filter, log
  -- @treturn table span
  function self.active_span()
    if not VALID_TRACING_PHASES[ngx.get_phase()] then
      return
    end

    return ngx.ctx[self.active_span_key]
  end

  --- Set the active span
  --
  -- @function kong.tracing.set_active_span
  -- @phases rewrite, access, header_filter, response, body_filter, log
  -- @tparam table span
  function self.set_active_span(span)
    if not VALID_TRACING_PHASES[ngx.get_phase()] then
      return
    end

    if span then
      span.active = true
    end

    ngx.ctx[self.active_span_key] = span
  end

  --- Create a new Span
  --
  -- @function kong.tracing.start_span
  -- @phases rewrite, access, header_filter, response, body_filter, log
  -- @tparam string name span name
  -- @tparam table options
  -- @treturn table span
  function self.start_span(...)
    if not VALID_TRACING_PHASES[ngx.get_phase()] then
      return noop_span
    end

    return new_span(self, ...)
  end

  function self.create_span(...)
    return create_span(...)
  end

  function self.link_span(...)
    return link_span(...)
  end

  function self.init_spans()
    local spans = tablepool_fetch(POOL_SPAN_STORAGE, 10, 0)
    spans[0] = 0 -- span counter
    ngx.ctx[self.spans_table_key] = spans
    return spans
  end

  function self.get_spans()
    return ngx.ctx[self.spans_table_key] or self.init_spans()
  end

  function self.get_root_span()
    local spans = self.get_spans()
    if not spans then
      return
    end

    return spans[1]
  end

  --- Batch process spans
  -- Please note that socket is not available in the log phase, use `ngx.timer.at` instead
  --
  -- @function kong.tracing.process_span
  -- @phases log
  -- @tparam function processor a function that accecpt a span as the parameter
  function self.process_span(processor, ...)
    check_phase(PHASES.log)

    if type(processor) ~= "function" then
      error("processor must be a function", 2)
    end

    local spans = self.get_spans()
    if not spans then
      return
    end

    for _, span in ipairs(spans) do
      if span.tracer and span.tracer.name == self.name then
        processor(span, ...)
      end
    end
  end

  --- Update the value of should_sample for all spans
  --
  -- @function kong.tracing:set_should_sample
  -- @tparam bool should_sample value for the sample parameter
  function self:set_should_sample(should_sample)
    local spans = self.get_spans()
    if not spans then
      return
    end

    for _, span in ipairs(spans) do
      if span.is_recording ~= false then
        span.should_sample = should_sample
      end
    end
  end

  --- Get the sampling decision result
  --
  -- Uses a parent-based sampler when the parent has sampled flag == false
  -- to inherit the non-recording decision from the parent span, or when 
  -- trace_id is not available.
  --
  -- Else, apply the probability-based should_sample decision.
  --
  -- @function kong.tracing:get_sampling_decision
  -- @tparam bool parent_should_sample value of the parent span sampled flag
  -- extracted from the incoming tracing headers
  -- @tparam number sampling_rate the sampling rate to apply for the
  -- probability sampler
  -- @treturn bool sampled value of sampled for this trace
  function self:get_sampling_decision(parent_should_sample, plugin_sampling_rate)
    local ctx = ngx.ctx

    local sampled
    local root_span = self.get_root_span()
    local trace_id = tracing_context.get_raw_trace_id(ctx)
    local sampling_rate = plugin_sampling_rate or kong.configuration.tracing_sampling_rate

    if not root_span or root_span.attributes["kong.propagation_only"] then
      -- should not sample if there is no root span or if the root span is
      -- a dummy created only to propagate headers
      sampled = false

    elseif parent_should_sample == false or not trace_id then
      -- trace_id can be nil when tracing instrumentations are disabled
      -- and Kong is configured to only do headers propagation
      sampled = parent_should_sample

    elseif sampling_rate then
      -- use probability-based sampler
      local err
      sampled, err = self.sampler(trace_id, sampling_rate)

      if err then
        sampled = false
        ngx_log(ngx_ERR, "sampler failure: ", err)
      end
    end

    -- enforce boolean
    return not not sampled
  end

  tracer_memo[name] = setmetatable(self, tracer_mt)
  return tracer_memo[name]
end

tracer_mt.new = new_tracer
noop_tracer.new = new_tracer

local global_tracer
tracer_mt.set_global_tracer = function(tracer)
  if type(tracer) ~= "table" or
      (getmetatable(tracer) ~= tracer_mt and tracer.name ~= "noop") then
    error("invalid tracer", 2)
  end

  global_tracer = tracer
  -- replace kong.pdk.tracer
  if kong then
    kong.tracing = tracer
  end
end
noop_tracer.set_global_tracer = tracer_mt.set_global_tracer
global_tracer = new_tracer("core", { noop = true })

tracer_mt.__call = function(_, ...)
  return new_tracer(...)
end
setmetatable(noop_tracer, {
  __call = tracer_mt.__call,
  __newindex = NOOP,
})

return {
  new = function()
    return global_tracer
  end,
}
