local char = string.char
local gsub = string.gsub

local match        = string.match
local unescape_uri = ngx.unescape_uri
local pairs = pairs

local NULL                = "\0"
local TRACE_ID_SIZE_BYTES = 16
local SPAN_ID_SIZE_BYTES  = 8

local FORMATS = {
  W3C       = "w3c",
  B3        = "b3",
  B3_SINGLE = "b3-single",
  JAEGER    = "jaeger",
  OT        = "ot",
  DATADOG   = "datadog",
  AWS       = "aws",
  GCP       = "gcp",
  INSTANA   = "instana",
}

local function hex_to_char(c)
  return char(tonumber(c, 16))
end

local function from_hex(str)
  if type(str) ~= "string" then
    return nil, "not a string"
  end

  if #str % 2 ~= 0 then
    str = "0" .. str
  end

  if str ~= nil then
    str = gsub(str, "%x%x", hex_to_char)
  end
  return str
end

local baggage_mt = {
  __newindex = function()
    error("attempt to set immutable baggage", 2)
  end,
}

local function parse_baggage_headers(headers, header_pattern)
  local baggage
  for k, v in pairs(headers) do
    local baggage_key = match(k, header_pattern)
    if baggage_key then
      if baggage then
        baggage[baggage_key] = unescape_uri(v)
      else
        baggage = { [baggage_key] = unescape_uri(v) }
      end
    end
  end

  if baggage then
    return setmetatable(baggage, baggage_mt)
  end
end

local function to_id_size(id, length)
  if not id then
    return nil
  end

  local len = #id
  if len > length then
    return id:sub(-length)

  elseif len < length then
    return NULL:rep(length - len) .. id
  end

  return id
end

local function to_kong_trace_id(id)
  return to_id_size(id, TRACE_ID_SIZE_BYTES)
end

local function to_kong_span_id(id)
  return to_id_size(id, SPAN_ID_SIZE_BYTES)
end

return {
  FORMATS = FORMATS,

  from_hex = from_hex,
  to_id_size = to_id_size,
  to_kong_trace_id = to_kong_trace_id,
  to_kong_span_id = to_kong_span_id,
  parse_baggage_headers = parse_baggage_headers,
}
