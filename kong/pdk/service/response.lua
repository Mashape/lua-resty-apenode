---
-- Module for manipulating the response from the Service.
-- @module kong.service.response


local cjson = require "kong.tools.cjson"
local multipart = require "multipart"
local phase_checker = require "kong.pdk.private.phases"
local string_tools = require "kong.tools.string"


local ngx = ngx
local sub = string.sub
local fmt = string.format
local find = string.find
local type = type
local error = error
local lower = string.lower
local pairs = pairs
local tonumber = tonumber
local getmetatable = getmetatable
local setmetatable = setmetatable
local check_phase = phase_checker.check



local replace_dashes       = string_tools.replace_dashes
local replace_dashes_lower = string_tools.replace_dashes_lower


local PHASES = phase_checker.phases


local header_body_log = phase_checker.new(PHASES.response,
                                          PHASES.header_filter,
                                          PHASES.body_filter,
                                          PHASES.log)


local attach_resp_headers_mt


do
  local resp_headers_orig_mt_index


  local resp_headers_mt = {
    __index = function(t, name)
      if type(name) == "string" then
        local var = fmt("upstream_http_%s", replace_dashes_lower(name))
        if not ngx.var[var] then
          return nil
        end
      end

      return resp_headers_orig_mt_index(t, name)
    end,
  }


  attach_resp_headers_mt = function(response_headers, err)
    if not resp_headers_orig_mt_index then
      local mt = getmetatable(response_headers)
      resp_headers_orig_mt_index = mt.__index
    end

    setmetatable(response_headers, resp_headers_mt)

    return response_headers, err
  end
end


local attach_buffered_headers_mt

do
  local EMPTY = {}

  attach_buffered_headers_mt = function(response_headers, max_headers)
    if not response_headers then
      return EMPTY
    end

    return setmetatable({}, { __index = function(_, name)
      if type(name) ~= "string" then
        return nil
      end

      if response_headers[name] then
        return response_headers[name]
      end

      name = lower(name)

      if response_headers[name] then
        return response_headers[name]
      end

      name = replace_dashes(name)

      if response_headers[name] then
        return response_headers[name]
      end

      local i = 1
      for n, v in pairs(response_headers) do
        if i > max_headers then
          return nil
        end

        n = replace_dashes_lower(n)
        if n == name then
          return v
        end

        i = i + 1
      end
    end })
  end
end


local function new(pdk, major_version)
  local response = {}


  local MIN_POST_ARGS          = 1
  local MAX_POST_ARGS_DEFAULT  = 100
  local MAX_POST_ARGS          = 1000

  local CONTENT_TYPE           = "Content-Type"

  local CONTENT_TYPE_POST      = "application/x-www-form-urlencoded"
  local CONTENT_TYPE_JSON      = "application/json"
  local CONTENT_TYPE_FORM_DATA = "multipart/form-data"

  local MIN_HEADERS            = 1
  local MAX_HEADERS_DEFAULT    = 100
  local MAX_HEADERS            = 1000
  local MAX_HEADERS_CONFIGURED


  ---
  -- Returns the HTTP status code of the response from the Service as a Lua number.
  --
  -- @function kong.service.response.get_status
  -- @phases `header_filter`, `body_filter`, `log`
  -- @treturn number|nil The status code from the response from the Service, or `nil`
  -- if the request was not proxied (that is, if `kong.response.get_source()` returned
  -- anything other than `"service"`).
  -- @usage
  -- kong.log.inspect(kong.service.response.get_status()) -- 418
  function response.get_status()
    check_phase(header_body_log)

    local ctx = ngx.ctx
    if ctx.buffered_status then
      return ctx.buffered_status
    end

    return tonumber(sub(ngx.var.upstream_status or "", -3))
  end


  ---
  -- Returns a Lua table holding the headers from the Service response. Keys are
  -- header names. Values are either a string with the header value, or an array of
  -- strings if a header was sent multiple times. Header names in this table are
  -- case-insensitive and dashes (`-`) can be written as underscores (`_`); that is,
  -- the header `X-Custom-Header` can also be retrieved as `x_custom_header`.
  --
  -- Unlike `kong.response.get_headers()`, this function only returns headers that
  -- are present in the response from the Service (ignoring headers added by Kong itself).
  -- If the request is not proxied to a Service (e.g. an authentication plugin rejected
  -- a request and produced an HTTP 401 response), then the returned `headers` value
  -- might be `nil`, since no response from the Service has been received.
  --
  -- By default, this function returns up to **100** headers. The optional
  -- `max_headers` argument can be specified to customize this limit, but must be
  -- greater than **1** and not greater than **1000**.
  -- @function kong.service.response.get_headers
  -- @phases `header_filter`, `body_filter`, `log`
  -- @tparam[opt] number max_headers Sets a limit on the maximum number of
  -- headers that can be parsed.
  -- @treturn table The response headers in table form.
  -- @treturn string If more headers than `max_headers` are present, returns
  -- a string with the error `"truncated"`.
  -- @usage
  -- -- Given a response with the following headers:
  -- -- X-Custom-Header: bla
  -- -- X-Another: foo bar
  -- -- X-Another: baz
  -- local headers = kong.service.response.get_headers()
  -- if headers then
  --   kong.log.inspect(headers.x_custom_header) -- "bla"
  --   kong.log.inspect(headers.x_another[1])    -- "foo bar"
  --   kong.log.inspect(headers["X-Another"][2]) -- "baz"
  -- end
  -- Note that this function returns a proxy table
  -- which cannot be iterated with `pairs` or used as operand of `#`.
  function response.get_headers(max_headers)
    check_phase(header_body_log)

    local buffered_headers = ngx.ctx.buffered_headers

    if max_headers == nil then
      if buffered_headers then
        if not MAX_HEADERS_CONFIGURED then
          MAX_HEADERS_CONFIGURED = pdk and pdk.configuration and pdk.configuration.lua_max_resp_headers
        end
        return attach_buffered_headers_mt(buffered_headers, MAX_HEADERS_CONFIGURED or MAX_HEADERS_DEFAULT)
      end

      return attach_resp_headers_mt(ngx.resp.get_headers())
    end

    if type(max_headers) ~= "number" then
      error("max_headers must be a number", 2)

    elseif max_headers < MIN_HEADERS then
      error("max_headers must be >= " .. MIN_HEADERS, 2)

    elseif max_headers > MAX_HEADERS then
      error("max_headers must be <= " .. MAX_HEADERS, 2)
    end

    if buffered_headers then
      return attach_buffered_headers_mt(buffered_headers, max_headers)
    end

    return attach_resp_headers_mt(ngx.resp.get_headers(max_headers))
  end

  ---
  -- Returns the value of the specified response header.
  --
  -- Unlike `kong.response.get_header()`, this function only returns a header
  -- if it is present in the response from the Service (ignoring headers added by Kong
  -- itself).
  --
  -- @function kong.service.response.get_header
  -- @phases `header_filter`, `body_filter`, `log`
  -- @tparam string name The name of the header.
  --
  --   Header names in are case-insensitive and are normalized to lowercase, and
  --   dashes (`-`) can be written as underscores (`_`); that is, the header
  --   `X-Custom-Header` can also be retrieved as `x_custom_header`.
  --
  -- @treturn string|nil The value of the header, or `nil` if a header with
  -- `name` is not found in the response. If a header with the same name is present
  -- multiple times in the response, this function returns the value of the
  -- first occurrence of this header.
  -- @usage
  -- -- Given a response with the following headers:
  -- -- X-Custom-Header: bla
  -- -- X-Another: foo bar
  -- -- X-Another: baz
  --
  -- kong.log.inspect(kong.service.response.get_header("x-custom-header")) -- "bla"
  -- kong.log.inspect(kong.service.response.get_header("X-Another"))       -- "foo bar"
  function response.get_header(name)
    check_phase(header_body_log)

    if type(name) ~= "string" then
      error("name must be a string", 2)
    end

    local header_value = response.get_headers()[name]
    if type(header_value) == "table" then
      return header_value[1]
    end

    return header_value
  end


  ---
  -- Returns the raw buffered body.
  --
  -- @function kong.service.response.get_raw_body
  -- @phases `header_filter`, `body_filter`, `log`
  -- @treturn string The raw buffered body.
  -- @usage
  -- -- Plugin needs to call kong.service.request.enable_buffering() on `rewrite`
  -- -- or `access` phase prior calling this function.
  --
  -- local body = kong.service.response.get_raw_body()
  function response.get_raw_body(buffered_proxying)
    check_phase(header_body_log)
    local ctx = ngx.ctx
    local buffered = buffered_proxying or ctx.buffered_proxying
    if not buffered then
      error("service body is only available with buffered proxying " ..
            "(see: kong.service.request.enable_buffering function)", 2)
    end

    return ctx.buffered_body or ""
  end


  ---
  -- Returns the decoded buffered body.
  --
  -- @function kong.service.response.get_body
  -- @phases `header_filter`, `body_filter`, `log`
  -- @tparam[opt] string mimetype The MIME type of the response (if known).
  -- @tparam[opt] number max_args Sets a limit on the maximum number of (what?)
  -- that can be parsed.
  -- @treturn string The decoded buffered body
  -- @usage
  -- -- Plugin needs to call kong.service.request.enable_buffering() on `rewrite`
  -- -- or `access` phase prior calling this function.
  --
  -- local body = kong.service.response.get_body()
  function response.get_body(mimetype, max_args)
    check_phase(header_body_log)
    local bufferred_proxying = ngx.ctx.buffered_proxying
    if not bufferred_proxying then
      error("service body is only available with buffered proxying " ..
            "(see: kong.service.request.enable_buffering function)", 2)
    end

    local content_type = mimetype or response.get_header(CONTENT_TYPE)
    if not content_type then
      return nil, "missing content type"
    end

    local content_type_lower = lower(content_type)
    do
      local s = find(content_type_lower, ";", 1, true)
      if s then
        content_type_lower = sub(content_type_lower, 1, s - 1)
      end
    end

    if find(content_type_lower, CONTENT_TYPE_POST, 1, true) == 1 then
      if max_args ~= nil then
        if type(max_args) ~= "number" then
          error("max_args must be a number", 2)

        elseif max_args < MIN_POST_ARGS then
          error("max_args must be >= " .. MIN_POST_ARGS, 2)

        elseif max_args > MAX_POST_ARGS then
          error("max_args must be <= " .. MAX_POST_ARGS, 2)
        end
      end

      local body = response.get_raw_body(bufferred_proxying)
      local pargs, err = ngx.decode_args(body, max_args or MAX_POST_ARGS_DEFAULT)
      if not pargs then
        return nil, err, CONTENT_TYPE_POST
      end

      return pargs, nil, CONTENT_TYPE_POST

    elseif find(content_type_lower, CONTENT_TYPE_JSON, 1, true) == 1 then
      local body = response.get_raw_body(bufferred_proxying)
      local json = cjson.decode_with_array_mt(body)
      if type(json) ~= "table" then
        return nil, "invalid json body", CONTENT_TYPE_JSON
      end

      return json, nil, CONTENT_TYPE_JSON

    elseif find(content_type_lower, CONTENT_TYPE_FORM_DATA, 1, true) == 1 then
      local body = response.get_raw_body(bufferred_proxying)

      local parts = multipart(body, content_type)
      if not parts then
        return nil, "unable to decode multipart body", CONTENT_TYPE_FORM_DATA
      end

      local margs = parts:get_all_with_arrays()
      if not margs then
        return nil, "unable to read multipart values", CONTENT_TYPE_FORM_DATA
      end

      return margs, nil, CONTENT_TYPE_FORM_DATA

    else
      return nil, "unsupported content type '" .. content_type .. "'", content_type_lower
    end
  end


  return response
end


return {
  new = new,
}
