local _EXTRACTOR        = require "kong.observability.tracing.propagation.extractors._base"
local propagation_utils = require "kong.observability.tracing.propagation.utils"
local from_hex          = propagation_utils.from_hex

local INSTANA_EXTRACTOR = _EXTRACTOR:new({
  headers_validate = {
    any = {
      "x-instana-t",
      "x-instana-s",
      "x-instana-l",
    }
  }
})

function INSTANA_EXTRACTOR:get_context(headers)

  -- x-instana-t trace id
  local trace_id_raw = headers["x-instana-t"]

  if type(trace_id_raw) ~= "string" then
    return
  end

  trace_id_raw = trace_id_raw:match("^(%x+)")
  local trace_id_len = trace_id_raw and #trace_id_raw or 0
  if not trace_id_raw or
     not(trace_id_len == 16 or trace_id_len == 32)
  then
    kong.log.warn("x-instana-t header invalid; ignoring.")
  end

  -- x-instana-s span id
  local span_id_raw = headers["x-instana-s"]

  if type(span_id_raw) ~= "string" then
    return
  end

  span_id_raw = span_id_raw:match("^(%x+)")
  if not span_id_raw then
    kong.log.warn("x-instana-s header invalid; ignoring.")
  end

  -- x-instana-l
  local level_id_raw = headers["x-instana-l"]

  if level_id_raw then
    -- the flag can come in as "0" or "1" 
    -- or something like the following format
    -- "1,correlationType=web;correlationId=1234567890abcdef"
    -- here we only care about the first value
    level_id_raw = level_id_raw:sub(1, 1)
  end
  local should_sample = level_id_raw == "1"

  local trace_id = trace_id_raw and from_hex(trace_id_raw) or nil
  local span_id = span_id_raw and from_hex(span_id_raw) or nil
  
  return {
    trace_id      = trace_id,
    span_id       = span_id,
    should_sample = should_sample,
  }
end

return INSTANA_EXTRACTOR
