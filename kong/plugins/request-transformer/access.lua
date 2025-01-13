local multipart = require "multipart"
local cjson = require("cjson.safe").new()
local pl_template = require "pl.template"
local sandbox = require "kong.tools.sandbox"
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy

local table_insert = table.insert
local get_uri_args = kong.request.get_query
local set_uri_args = kong.service.request.set_query
local clear_header = kong.service.request.clear_header
local var = ngx.var
local set_header = kong.service.request.set_header
local get_headers = kong.request.get_headers
local set_headers = kong.service.request.set_headers
local set_method = kong.service.request.set_method
local set_path = kong.service.request.set_path
local get_raw_body = kong.request.get_raw_body
local set_raw_body = kong.service.request.set_raw_body
local encode_args = ngx.encode_args
local ngx_decode_args = ngx.decode_args
local type = type
local str_find = string.find
local pairs = pairs
local error = error
local rawset = rawset
local lua_enabled = sandbox.configuration.enabled
local sandbox_enabled = sandbox.configuration.sandbox_enabled

local _M = {}
local template_cache = setmetatable( {}, { __mode = "k" })

local DEBUG = ngx.DEBUG
local CONTENT_LENGTH = "content-length"
local HOST = "host"
local JSON, MULTI, ENCODED = "json", "multi_part", "form_encoded"
local EMPTY = require("kong.tools.table").EMPTY


local compile_opts = {
  escape = "\xff", -- disable '#' as a valid template escape
}


cjson.decode_array_with_array_mt(true)


local function parse_json(body)
  if body then
    return cjson.decode(body)
  end
end

local function decode_args(body)
  if body then
    return ngx_decode_args(body)
  end
  return {}
end

local function get_content_type(content_type)
  if content_type == nil then
    return
  end
  if str_find(content_type:lower(), "application/json", nil, true) then
    return JSON
  elseif str_find(content_type:lower(), "multipart/form-data", nil, true) then
    return MULTI
  elseif str_find(content_type:lower(), "application/x-www-form-urlencoded", nil, true) then
    return ENCODED
  end
end

local function param_value(source_template, config_array, template_env)
  if not source_template or source_template == "" then
    return nil
  end

  if not lua_enabled then
    -- Detect expressions in the source template
    local expr = str_find(source_template, "%$%(.*%)")
    if expr then
      return nil, "loading of untrusted Lua code disabled because " ..
                  "'untrusted_lua' config option is set to 'off'"
    end
    -- Lua is disabled, no need to render the template
    return source_template
  end

  -- find compiled templates for this plugin-configuration array
  local compiled_templates = template_cache[config_array]
  if not compiled_templates then
    compiled_templates = {}
    -- store it by `config_array` which is part of the plugin `conf` table
    -- it will be GC'ed at the same time as `conf` and hence invalidate the
    -- compiled templates here as well as the cache-table has weak-keys
    template_cache[config_array] = compiled_templates
  end

  -- Find or compile the specific template
  local compiled_template = compiled_templates[source_template]
  if not compiled_template then
    compiled_template = assert(pl_template.compile(source_template, compile_opts))
    compiled_templates[source_template] = compiled_template
  end

  return compiled_template:render(template_env)
end

local function iter(config_array, template_env)
  return function(config_array, i, previous_name, previous_value)
    i = i + 1
    local current_pair = config_array[i]
    if current_pair == nil then -- n + 1
      return nil
    end

    local current_name, current_value = current_pair:match("^([^:]+):*(.-)$")

    if current_value == "" then
      return i, current_name
    end

    local res, err = param_value(current_value, config_array, template_env)
    if err then
      return error("[request-transformer] failed to render the template " ..
                   current_value .. ", error:" .. err)
    end

    kong.log.debug("[request-transformer] template `", current_value,
                   "` rendered to `", res, "`")

    return i, current_name, res
  end, config_array, 0
end

local function append_value(current_value, value)
  local current_value_type = type(current_value)

  if current_value_type  == "string" then
    return { current_value, value }
  elseif current_value_type  == "table" then
    table_insert(current_value, value)
    return current_value
  else
    return { value }
  end
end

local function rename(tbl, old_name, new_name)
  if old_name == new_name then
    return
  end

  local value = tbl[old_name]
  if value then
    tbl[old_name] = nil
    tbl[new_name] = value
    return true
  end
end

local function transform_headers(conf, template_env)
  local headers = get_headers()
  local headers_to_remove = {}

  headers.host = nil

  -- Remove header(s)
  for _, name, value in iter(conf.remove.headers, template_env) do
    name = name:lower()
    if headers[name] then
      headers[name] = nil
      headers_to_remove[name] = true
    end
  end

  -- Rename headers(s)
  for _, old_name, new_name in iter(conf.rename.headers, template_env) do
    local lower_old_name, lower_new_name = old_name:lower(), new_name:lower()
    -- headers by default are case-insensitive
    -- but if we have a case change, we need to handle it as a special case
    local need_remove
    if lower_old_name == lower_new_name then
      need_remove = rename(headers, old_name, new_name)
    else
      need_remove = rename(headers, lower_old_name, lower_new_name)
    end

    if need_remove then
      headers_to_remove[old_name] = true
    end
  end

  -- Replace header(s)
  for _, name, value in iter(conf.replace.headers, template_env) do
    name = name:lower()
    if headers[name] or name == HOST then
      headers[name] = value
    end
  end

  -- Add header(s)
  for _, name, value in iter(conf.add.headers, template_env) do
    if not headers[name] and name:lower() ~= HOST then
      headers[name] = value
    end
  end

  -- Append header(s)
  for _, name, value in iter(conf.append.headers, template_env) do
    local name_lc = name:lower()

    if name_lc ~= HOST and name ~= name_lc and headers[name] ~= nil then
      -- keep original content, use configd case
      -- note: the __index method of table returned by ngx.req.get_header
      -- is overwritten to check for lower case as well, see documentation
      -- for ngx.req.get_header to get more information
      -- effectively, it does this: headers[name] = headers[name] or headers[name_lc]
      headers[name] = headers[name]
      headers[name_lc] = nil
    end

    headers[name] = append_value(headers[name], value)
  end

  for name, _ in pairs(headers_to_remove) do
    clear_header(name)
  end

  set_headers(headers)
end

local function transform_querystrings(conf, template_env)

  if not (#conf.remove.querystring > 0 or #conf.rename.querystring > 0 or
          #conf.replace.querystring > 0 or #conf.add.querystring > 0 or
          #conf.append.querystring > 0) then
    return
  end

  local querystring = cycle_aware_deep_copy(template_env.query_params)

  -- Remove querystring(s)
  for _, name, value in iter(conf.remove.querystring, template_env) do
    querystring[name] = nil
  end

  -- Rename querystring(s)
  for _, old_name, new_name in iter(conf.rename.querystring, template_env) do
    rename(querystring, old_name, new_name)
  end

  for _, name, value in iter(conf.replace.querystring, template_env) do
    if querystring[name] then
      querystring[name] = value
    end
  end

  -- Add querystring(s)
  for _, name, value in iter(conf.add.querystring, template_env) do
    if not querystring[name] then
      querystring[name] = value
    end
  end

  -- Append querystring(s)
  for _, name, value in iter(conf.append.querystring, template_env) do
    querystring[name] = append_value(querystring[name], value)
  end
  set_uri_args(querystring)
end

local function transform_json_body(conf, body, content_length, template_env)
  local removed, renamed, replaced, added, appended = false, false, false, false, false
  local content_length = (body and #body) or 0
  local parameters = parse_json(body)
  if parameters == nil then
    if content_length > 0 then
      return false, nil
    end
    parameters = {}
  end

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body, template_env) do
      parameters[name] = nil
      removed = true
    end
  end

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body, template_env) do
      renamed = rename(parameters, old_name, new_name) or renamed
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body, template_env) do
      if parameters[name] then
        parameters[name] = value
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body, template_env) do
      if not parameters[name] then
        parameters[name] = value
        added = true
      end
    end
  end

  if #conf.append.body > 0 then
    for _, name, value in iter(conf.append.body, template_env) do
      local old_value = parameters[name]
      parameters[name] = append_value(old_value, value)
      appended = true
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, assert(cjson.encode(parameters))
  end
end

local function transform_url_encoded_body(conf, body, content_length, template_env)
  local renamed, removed, replaced, added, appended = false, false, false, false, false
  local parameters = decode_args(body)

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body, template_env) do
      parameters[name] = nil
      removed = true
    end
  end

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body, template_env) do
      renamed = rename(parameters, old_name, new_name) or renamed
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body, template_env) do
      if parameters[name] then
        parameters[name] = value
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body, template_env) do
      if parameters[name] == nil then
        parameters[name] = value
        added = true
      end
    end
  end

  if #conf.append.body > 0 then
    for _, name, value in iter(conf.append.body, template_env) do
      local old_value = parameters[name]
      parameters[name] = append_value(old_value, value)
      appended = true
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, encode_args(parameters)
  end
end

local function transform_multipart_body(conf, body, content_length, content_type_value, template_env)
  local removed, renamed, replaced, added, appended = false, false, false, false, false
  local parameters = multipart(body and body or "", content_type_value)

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body, template_env) do
      local para = parameters:get(old_name)
      if para and old_name ~= new_name then
        local value = para.value
        parameters:set_simple(new_name, value)
        parameters:delete(old_name)
        renamed = true
      end
    end
  end

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body, template_env) do
      parameters:delete(name)
      removed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body, template_env) do
      if parameters:get(name) then
        parameters:delete(name)
        parameters:set_simple(name, value)
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body, template_env) do
      if not parameters:get(name) then
        parameters:set_simple(name, value)
        added = true
      end
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, parameters:tostring()
  end
end

local function transform_body(conf, template_env)
  -- content-type is a builtin single value header, use var to fetch is faster.
  local content_type_value = var.http_content_type
  local content_type = get_content_type(content_type_value)
  if content_type == nil or #conf.rename.body < 1 and
     #conf.remove.body < 1 and #conf.replace.body < 1 and
     #conf.add.body < 1 and #conf.append.body < 1 then
    return
  end

  -- Call req_read_body to read the request body first
  local body, err = get_raw_body()
  if err then
    kong.log.warn(err)
  end
  local is_body_transformed = false
  local content_length = (body and #body) or 0

  if content_type == ENCODED then
    is_body_transformed, body = transform_url_encoded_body(conf, body, content_length, template_env)
  elseif content_type == MULTI then
    is_body_transformed, body = transform_multipart_body(conf, body, content_length, content_type_value, template_env)
  elseif content_type == JSON then
    is_body_transformed, body = transform_json_body(conf, body, content_length, template_env)
  end

  if is_body_transformed then
    set_raw_body(body)
    set_header(CONTENT_LENGTH, #body)
  end
end

local function transform_method(conf)
  if conf.http_method then
    set_method(conf.http_method:upper())
    if conf.http_method == "GET" or conf.http_method == "HEAD" or conf.http_method == "TRACE" then
      -- content-type is a builtin single value header, use var to fetch is faster.
      local content_type_value = var.http_content_type
      local content_type = get_content_type(content_type_value)
      if content_type == ENCODED then
        -- Also put the body into querystring
        local body = get_raw_body()
        local parameters = decode_args(body)

        -- Append to querystring
        if type(parameters) == "table" and next(parameters) then
          local querystring = get_uri_args()
          for name, value in pairs(parameters) do
            if querystring[name] then
              if type(querystring[name]) == "table" then
                append_value(querystring[name], value)
              else
                querystring[name] = { querystring[name], value }
              end
            else
              querystring[name] = value
            end
          end

          set_uri_args(querystring)
        end
      end
    end
  end
end

local function transform_uri(conf, template_env)
  if conf.replace.uri then

    local res, err = param_value(conf.replace.uri, conf.replace, template_env)
    if err then
      error("[request-transformer] failed to render the template " ..
        tostring(conf.replace.uri) .. ", error:" .. err)
    end

    kong.log.debug(DEBUG, "[request-transformer] template `", conf.replace.uri,
      "` rendered to `", res, "`")

    if res then
      set_path(res)
    end
  end
end

function _M.execute(conf)
  -- meta table for the sandbox, exposing lazily loaded values
  local __meta_environment = {
    __index = function(self, key)
      local lazy_loaders = {
        headers = function(self)
          return get_headers() or EMPTY
        end,
        query_params = function(self)
          return get_uri_args() or EMPTY
        end,
        uri_captures = function(self)
          return (ngx.ctx.router_matches or EMPTY).uri_captures or EMPTY
        end,
        shared = function(self)
          return ((kong or EMPTY).ctx or EMPTY).shared or EMPTY
        end,
      }
      local loader = lazy_loaders[key]
      if not loader then
        if lua_enabled and not sandbox_enabled then
          return _G[key]
        end
        return
      end
      -- set the result on the table to not load again
      local value = loader()
      rawset(self, key, value)
      return value
    end,
    __newindex = function(self)
      error("This environment is read-only.")
    end,
  }

  local template_env = {}
  if lua_enabled and sandbox_enabled then
    -- load the sandbox environment to be used to render the template
    template_env = cycle_aware_deep_copy(sandbox.configuration.environment)
    -- here we can optionally add functions to expose to the sandbox, eg:
    -- tostring = tostring,
    -- because headers may contain array elements such as duplicated headers
    -- type is a useful function in these cases. See issue #25.
    template_env.type = type
  end
  setmetatable(template_env, __meta_environment)

  transform_uri(conf, template_env)
  transform_method(conf)
  transform_headers(conf, template_env)
  transform_body(conf, template_env)
  transform_querystrings(conf, template_env)
end

return _M
