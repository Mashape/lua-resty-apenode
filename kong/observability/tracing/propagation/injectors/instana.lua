local _INJECTOR = require "kong.observability.tracing.propagation.injectors._base"
local to_hex    = require "resty.string".to_hex

local INSTANA_INJECTOR = _INJECTOR:new({
  name = "instana",
  context_validate = {}, -- all fields are optional
  trace_id_allowed_sizes = { 16, 8 },
  span_id_size_bytes = 8,
})


function INSTANA_INJECTOR:create_headers(out_tracing_ctx)
  local headers = {
    ["x-instana-t"] = to_hex(out_tracing_ctx.trace_id) or nil, 
    ["x-instana-s"] = to_hex(out_tracing_ctx.span_id) or nil,
  }
  
  if out_tracing_ctx.should_sample ~= nil then
    headers["x-instana-l"] = out_tracing_ctx.should_sample and "1" or "0"
  end

  return headers
end


function INSTANA_INJECTOR:get_formatted_trace_id(trace_id)
  return { instana = to_hex(trace_id) }
end


return INSTANA_INJECTOR
