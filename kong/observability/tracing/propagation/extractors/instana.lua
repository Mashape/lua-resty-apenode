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

  local trace_id_raw = headers["x-instana-t"]
  local span_id_raw = headers["x-instana-s"]
  local level_id_raw = headers["x-instana-l"] 

  if trace_id_raw then
    trace_id_raw = trace_id_raw:match("^(%x+)")
    if not trace_id_raw then
      kong.log.warn("x-instana-t header invalid; ignoring.")
    end
  end
  
  if span_id_raw then
    span_id_raw = span_id_raw:match("^(%x+)")
    if not span_id_raw then
      kong.log.warn("x-instana-s header invalid; ignoring.")
    end
  end
  
  if level_id_raw then
    -- the flag can come in as "0" or "1" 
    -- or something like the following format
    -- "1,correlationType=web;correlationId=1234567890abcdef"
    -- here we only care about the first value
    level_id_raw = level_id_raw:match("^([0-1])$") 
                or level_id_raw:match("^([0-1]).")
  end
  local should_sample = level_id_raw or "1"

  local trace_id = from_hex(trace_id_raw) or nil
  local span_id = from_hex(span_id_raw) or nil
  
  return {
    trace_id      = trace_id,
    span_id       = span_id,
    should_sample = should_sample,
  }
end

return INSTANA_EXTRACTOR
