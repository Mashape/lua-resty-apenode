local pl_template = require "pl.template"
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy
local typedefs = require "kong.db.schema.typedefs"
local validate_header_name = require("kong.tools.http").validate_header_name


local compile_opts = {
  escape = "\xff", -- disable '#' as a valid template escape
}


-- entries must have colons to set the key and value apart
local function check_for_value(entry)
  local name, value = entry:match("^([^:]+):*(.-)$")
  if not name or not value or value == "" then
    return false, "key '" ..name.. "' has no value"
  end

  local status, res, err = pcall(pl_template.compile, value, compile_opts)
  if not status or err then
    return false, "value '" .. value ..
            "' is not in supported format, error:" ..
            (status and res or err)
  end
  return true
end


local function validate_headers(pair, validate_value)
  local name, value = pair:match("^([^:]+):*(.-)$")
  if validate_header_name(name) == nil then
    return nil, string.format("'%s' is not a valid header", tostring(name))
  end

  if validate_value then
    if validate_header_name(value) == nil then
      return nil, string.format("'%s' is not a valid header", tostring(value))
    end
  end
  return true
end


local function validate_colon_headers(pair)
  return validate_headers(pair, true)
end


local strings_array = {
  type = "array",
  default = {},
  required = true,
  elements = { type = "string" },
}


local headers_array = {
  type = "array",
  default = {},
  required = true,
  elements = { type = "string", custom_validator = validate_headers },
}


local strings_array_record = {
  type = "record",
  fields = {
    { body = strings_array },
    { headers = headers_array },
    { querystring = strings_array },
  },
}


local colon_strings_array = {
  type = "array",
  default = {},
  required = true,
  elements = { type = "string", custom_validator = check_for_value }
}


local colon_header_value_array = {
  type = "array",
  default = {},
  required = true,
  elements = { type = "string", match = "^[^:]+:.*$", custom_validator = validate_headers },
}


local colon_strings_array_record = {
  type = "record",
  fields = {
    { body = colon_strings_array },
    { headers = colon_header_value_array },
    { querystring = colon_strings_array },
  },
}


local colon_headers_array = {
  type = "array",
  default = {},
  required = true,
  elements = { type = "string", match = "^[^:]+:.*$", custom_validator = validate_colon_headers },
}


local colon_rename_strings_array_record = {
  type = "record",
  fields = {
    { body = colon_strings_array },
    { headers = colon_headers_array },
    { querystring = colon_strings_array },
  },
}


local colon_strings_array_record_plus_uri = cycle_aware_deep_copy(colon_strings_array_record)
local uri = { uri = { type = "string" } }
table.insert(colon_strings_array_record_plus_uri.fields, uri)


return {
  name = "request-transformer",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { http_method = typedefs.http_method },
          { remove  = strings_array_record },
          { rename  = colon_rename_strings_array_record },
          { replace = colon_strings_array_record_plus_uri },
          { add     = colon_strings_array_record },
          { append  = colon_strings_array_record },
        }
      },
    },
  }
}
