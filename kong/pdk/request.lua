--- Client request module.
--
-- This module provides a set of functions to retrieve information about the
-- incoming requests made by clients.
--
-- @module kong.request


local cjson = require "kong.tools.cjson"
local multipart = require "multipart"
local phase_checker = require "kong.pdk.private.phases"
local normalize = require("kong.tools.uri").normalize
local yield = require("kong.tools.yield").yield


local ngx = ngx
local var = ngx.var
local req = ngx.req
local sub = string.sub
local find = string.find
local lower = string.lower
local type = type
local error = error
local pairs = pairs
local tonumber = tonumber
local setmetatable = setmetatable


local check_phase = phase_checker.check
local check_not_phase = phase_checker.check_not


local read_body = req.read_body
local start_time = req.start_time
local get_method = req.get_method
local get_headers = req.get_headers
local get_uri_args = req.get_uri_args
local http_version = req.http_version
local get_post_args = req.get_post_args
local get_body_data = req.get_body_data
local get_body_file = req.get_body_file
local decode_args = ngx.decode_args


local PHASES = phase_checker.phases



local function new(self)
  local _REQUEST = {}

  local HOST_PORTS             = self.configuration.host_ports or {}

  local MIN_HEADERS            = 1
  local MAX_HEADERS            = 1000
  local MIN_QUERY_ARGS         = 1
  local MAX_QUERY_ARGS         = 1000
  local MIN_POST_ARGS          = 1
  local MAX_POST_ARGS          = 1000

  local MIN_PORT               = 1
  local MAX_PORT               = 65535

  local CONTENT_TYPE_POST      = "application/x-www-form-urlencoded"
  local CONTENT_TYPE_JSON      = "application/json"
  local CONTENT_TYPE_FORM_DATA = "multipart/form-data"

  local X_FORWARDED_PROTO      = "X-Forwarded-Proto"
  local X_FORWARDED_HOST       = "X-Forwarded-Host"
  local X_FORWARDED_PORT       = "X-Forwarded-Port"
  local X_FORWARDED_PATH       = "X-Forwarded-Path"
  local X_FORWARDED_PREFIX     = "X-Forwarded-Prefix"

  local is_trusted_ip do
    local is_trusted = self.ip.is_trusted
    local get_ip = self.client.get_ip
    is_trusted_ip = function()
      return is_trusted(get_ip())
    end
  end

  local http_get_header = require("kong.tools.http").get_header


  ---
  -- Returns the scheme component of the request's URL. The returned value is
  -- normalized to lowercase form.
  --
  -- @function kong.request.get_scheme
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string A string like `"http"` or `"https"`.
  -- @usage
  -- -- Given a request to https://example.com:1234/v1/movies
  --
  -- kong.request.get_scheme() -- "https"
  function _REQUEST.get_scheme()
    check_phase(PHASES.request)

    return ngx.ctx.scheme or var.scheme
  end


  ---
  -- Returns the host component of the request's URL, or the value of the
  -- "Host" header. The returned value is normalized to lowercase form.
  --
  -- @function kong.request.get_host
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The hostname.
  -- @usage
  -- -- Given a request to https://example.com:1234/v1/movies
  --
  -- kong.request.get_host() -- "example.com"
  function _REQUEST.get_host()
    check_phase(PHASES.request)

    return ngx.ctx.host or var.host
  end


  ---
  -- Returns the port component of the request's URL. The value is returned
  -- as a Lua number.
  --
  -- @function kong.request.get_port
  -- @phases certificate, rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn number The port.
  -- @usage
  -- -- Given a request to https://example.com:1234/v1/movies
  --
  -- kong.request.get_port() -- 1234
  function _REQUEST.get_port()
    check_not_phase(PHASES.init_worker)

    return tonumber(var.server_port, 10)
  end


  ---
  -- Returns the scheme component of the request's URL, but also considers
  -- `X-Forwarded-Proto` if it comes from a trusted source. The returned
  -- value is normalized to lowercase.
  --
  -- Whether this function considers `X-Forwarded-Proto` or not depends on
  -- several Kong configuration parameters:
  --
  -- * [trusted\_ips](https://docs.konghq.com/gateway/latest/reference/configuration/#trusted_ips)
  -- * [real\_ip\_header](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_header)
  -- * [real\_ip\_recursive](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_recursive)
  --
  -- **Note**: Kong does not offer support for the Forwarded HTTP Extension
  -- (RFC 7239) since it is not supported by ngx_http_realip_module.
  --
  -- @function kong.request.get_forwarded_scheme
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The forwarded scheme.
  -- @usage
  -- kong.request.get_forwarded_scheme() -- "https"
  function _REQUEST.get_forwarded_scheme()
    check_phase(PHASES.request)

    if is_trusted_ip() then
      local scheme = _REQUEST.get_header(X_FORWARDED_PROTO)
      if scheme then
        return lower(scheme)
      end
    end

    return _REQUEST.get_scheme()
  end


  ---
  -- Returns the host component of the request's URL or the value of the "host"
  -- header. Unlike `kong.request.get_host()`, this function also considers
  -- `X-Forwarded-Host` if it comes from a trusted source. The returned value
  -- is normalized to lowercase.
  --
  -- Whether this function considers `X-Forwarded-Host` or not depends on
  -- several Kong configuration parameters:
  --
  -- * [trusted\_ips](https://docs.konghq.com/gateway/latest/reference/configuration/#trusted_ips)
  -- * [real\_ip\_header](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_header)
  -- * [real\_ip\_recursive](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_recursive)
  --
  -- **Note**: Kong does not offer support for the Forwarded HTTP Extension
  -- (RFC 7239) since it is not supported by ngx_http_realip_module.
  --
  -- @function kong.request.get_forwarded_host
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The forwarded host.
  -- @usage
  -- kong.request.get_forwarded_host() -- "example.com"
  function _REQUEST.get_forwarded_host()
    check_phase(PHASES.request)

    if is_trusted_ip() then
      local host = _REQUEST.get_header(X_FORWARDED_HOST)
      if host then
        local s = find(host, "@", 1, true)
        if s then
          host = sub(host, s + 1)
        end

        s = find(host, ":", 1, true)
        return s and lower(sub(host, 1, s - 1)) or lower(host)
      end
    end

    return _REQUEST.get_host()
  end


  ---
  -- Returns the port component of the request's URL, but also considers
  -- `X-Forwarded-Host` if it comes from a trusted source. The value
  -- is returned as a Lua number.
  --
  -- Whether this function considers `X-Forwarded-Proto` or not depends on
  -- several Kong configuration parameters:
  --
  -- * [trusted\_ips](https://docs.konghq.com/gateway/latest/reference/configuration/#trusted_ips)
  -- * [real\_ip\_header](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_header)
  -- * [real\_ip\_recursive](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_recursive)
  --
  -- **Note**: Kong does not offer support for the Forwarded HTTP Extension
  -- (RFC 7239) since it is not supported by ngx_http_realip_module.
  --
  -- When running Kong behind the L4 port mapping (or forwarding), you can also
  -- configure:
  -- * [port\_maps](https://docs.konghq.com/gateway/latest/reference/configuration/#port_maps)
  --
  -- The `port_maps` configuration parameter enables this function to return the
  -- port to which the port Kong is listening to is mapped to (in case they differ).
  --
  -- @function kong.request.get_forwarded_port
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn number The forwarded port.
  -- @usage
  -- kong.request.get_forwarded_port() -- 1234
  function _REQUEST.get_forwarded_port()
    check_phase(PHASES.request)

    if is_trusted_ip() then
      local port = tonumber(_REQUEST.get_header(X_FORWARDED_PORT), 10)
      if port and port >= MIN_PORT and port <= MAX_PORT then
        return port
      end

      local host = _REQUEST.get_header(X_FORWARDED_HOST)
      if host then
        local s = find(host, "@", 1, true)
        if s then
          host = sub(host, s + 1)
        end

        s = find(host, ":", 1, true)
        if s then
          port = tonumber(sub(host, s + 1), 10)
          if port and port >= MIN_PORT and port <= MAX_PORT then
            return port
          end
        end
      end
    end

    local host_port = ngx.ctx.host_port
    if host_port then
      return host_port
    end

    local port = _REQUEST.get_port()
    return HOST_PORTS[port] or port
  end


  ---
  -- Returns the path component of the request's URL, but also considers
  -- `X-Forwarded-Path` if it comes from a trusted source. The value
  -- is returned as a Lua string.
  --
  -- Whether this function considers `X-Forwarded-Path` or not depends on
  -- several Kong configuration parameters:
  --
  -- * [trusted\_ips](https://docs.konghq.com/gateway/latest/reference/configuration/#trusted_ips)
  -- * [real\_ip\_header](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_header)
  -- * [real\_ip\_recursive](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_recursive)
  --
  -- **Note**: Kong does not do any normalization on the request path.
  --
  -- @function kong.request.get_forwarded_path
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The forwarded path.
  -- @usage
  -- kong.request.get_forwarded_path() -- /path
  function _REQUEST.get_forwarded_path()
    check_phase(PHASES.request)

    if is_trusted_ip() then
      local path = _REQUEST.get_header(X_FORWARDED_PATH)
      if path then
        return path
      end
    end

    local path = _REQUEST.get_path()
    return path
  end


  ---
  -- Returns the prefix path component of the request's URL that Kong stripped
  -- before proxying to upstream. It also checks if `X-Forwarded-Prefix` comes
  -- from a trusted source, and uses it as-is when given. The value is returned
  -- as a Lua string.
  --
  -- If a trusted `X-Forwarded-Prefix` is not passed, this function must be
  -- called after Kong has run its router (`access` phase),
  -- as the Kong router may strip the prefix of the request path. That stripped
  -- path becomes the return value of this function, unless there is already
  -- a trusted `X-Forwarded-Prefix` header in the request.
  --
  -- Whether this function considers `X-Forwarded-Prefix` or not depends on
  -- several Kong configuration parameters:
  --
  -- * [trusted\_ips](https://docs.konghq.com/gateway/latest/reference/configuration/#trusted_ips)
  -- * [real\_ip\_header](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_header)
  -- * [real\_ip\_recursive](https://docs.konghq.com/gateway/latest/reference/configuration/#real_ip_recursive)
  --
  -- **Note**: Kong does not do any normalization on the request path prefix.
  --
  -- @function kong.request.get_forwarded_prefix
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string|nil The forwarded path prefix or `nil` if the prefix was
  -- not stripped.
  -- @usage
  -- kong.request.get_forwarded_prefix() -- /prefix
  function _REQUEST.get_forwarded_prefix()
    check_phase(PHASES.request)

    local prefix
    if is_trusted_ip() then
      prefix = _REQUEST.get_header(X_FORWARDED_PREFIX)
      if prefix then
        return prefix
      end
    end

    return var.upstream_x_forwarded_prefix
  end


  ---
  -- Returns the HTTP version used by the client in the request as a Lua
  -- number, returning values such as `1`, `1.1`, `2.0`, or `nil` for
  -- unrecognized values.
  --
  -- @function kong.request.get_http_version
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn number|nil The HTTP version as a Lua number.
  -- @usage
  -- kong.request.get_http_version() -- 1.1
  function _REQUEST.get_http_version()
    check_phase(PHASES.request)

    return http_version()
  end


  ---
  -- Returns the HTTP method of the request. The value is normalized to
  -- uppercase.
  --
  -- @function kong.request.get_method
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The request method.
  -- @usage
  -- kong.request.get_method() -- "GET"
  function _REQUEST.get_method()
    check_phase(PHASES.request)

    if ngx.ctx.KONG_UNEXPECTED and _REQUEST.get_http_version() < 2 then
      local req_line = var.request
      local idx = find(req_line, " ", 1, true)
      if idx then
        return sub(req_line, 1, idx - 1)
      end
    end

    return get_method()
  end


  ---
  -- Returns the normalized path component of the request's URL. The return
  -- value is the same as `kong.request.get_raw_path()` but normalized according
  -- to RFC 3986 section 6:
  --
  -- * Percent-encoded values of unreserved characters are decoded (`%20`
  --   becomes ` `).
  -- * Percent-encoded values of reserved characters have their hexidecimal
  --   value uppercased (`%2f` becomes `%2F`).
  -- * Relative path elements (`/.` and `/..`) are dereferenced.
  -- * Duplicate slashes are consolidated (`//` becomes `/`).
  --
  -- @function kong.request.get_path
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string the path
  -- @usage
  -- -- Given a request to https://example.com/t/Abc%20123%C3%B8%2f/parent/..//test/./
  --
  -- kong.request.get_path() -- "/t/Abc 123ø%2F/test/"
  function _REQUEST.get_path()
    return normalize(_REQUEST.get_raw_path(), true)
  end


  ---
  -- Returns the path component of the request's URL. It is not normalized in
  -- any way and does not include the query string.
  --
  -- **NOTE:** Using the raw path to perform string comparision during request
  -- handling (such as in routing, ACL/authorization checks, setting rate-limit
  -- keys, etc) is widely regarded as insecure, as it can leave plugin code
  -- vulnerable to path traversal attacks. Prefer `kong.request.get_path()` for
  -- such use cases.
  --
  -- @function kong.request.get_raw_path
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The path.
  -- @usage
  -- -- Given a request to https://example.com/t/Abc%20123%C3%B8%2f/parent/..//test/./?movie=foo
  --
  -- kong.request.get_raw_path() -- "/t/Abc%20123%C3%B8%2f/parent/..//test/./"
  function _REQUEST.get_raw_path()
    check_phase(PHASES.request)

    local uri = ngx.ctx.request_uri or var.request_uri or ""
    local s = find(uri, "?", 2, true)
    return s and sub(uri, 1, s - 1) or uri
  end


  ---
  -- Returns the path, including the query string if any. No
  -- transformations or normalizations are done.
  --
  -- @function kong.request.get_path_with_query
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The path with the query string.
  -- @usage
  -- -- Given a request to https://example.com:1234/v1/movies?movie=foo
  --
  -- kong.request.get_path_with_query() -- "/v1/movies?movie=foo"
  function _REQUEST.get_path_with_query()
    check_phase(PHASES.request)
    return ngx.ctx.request_uri or var.request_uri or ""
  end


  ---
  -- Returns the query component of the request's URL. It is not normalized in
  -- any way (not even URL-decoding of special characters) and does not
  -- include the leading `?` character.
  --
  -- @function kong.request.get_raw_query
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string The query component of the request's URL.
  -- @usage
  -- -- Given a request to https://example.com/foo?msg=hello%20world&bla=&bar
  --
  -- kong.request.get_raw_query() -- "msg=hello%20world&bla=&bar"
  function _REQUEST.get_raw_query()
    check_phase(PHASES.request)

    return var.args or ""
  end


  ---
  -- Returns the value of the specified argument, obtained from the query
  -- arguments of the current request.
  --
  -- The returned value is either a `string`, a boolean `true` if an
  -- argument was not given a value, or `nil` if no argument with `name` was
  -- found.
  --
  -- If an argument with the same name is present multiple times in the
  -- query string, this function returns the value of the first occurrence.
  --
  -- @function kong.request.get_query_arg
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn string|boolean|nil The value of the argument.
  -- @usage
  -- -- Given a request GET /test?foo=hello%20world&bar=baz&zzz&blo=&bar=bla&bar
  --
  -- kong.request.get_query_arg("foo") -- "hello world"
  -- kong.request.get_query_arg("bar") -- "baz"
  -- kong.request.get_query_arg("zzz") -- true
  -- kong.request.get_query_arg("blo") -- ""
  function _REQUEST.get_query_arg(name)
    check_phase(PHASES.request)

    if type(name) ~= "string" then
      error("query argument name must be a string", 2)
    end

    local arg_value = _REQUEST.get_query()[name]
    if type(arg_value) == "table" then
      return arg_value[1]
    end

    return arg_value
  end


  ---
  -- Returns the table of query arguments obtained from the query string. Keys
  -- are query argument names. Values are either a string with the argument
  -- value, a boolean `true` if an argument was not given a value, or an array
  -- if an argument was given in the query string multiple times. Keys and
  -- values are unescaped according to URL-encoded escaping rules.
  --
  -- Note that a query string `?foo&bar` translates to two boolean `true`
  -- arguments, and `?foo=&bar=` translates to two string arguments containing
  -- empty strings.
  --
  -- By default, this function returns up to **100** arguments (or what has been
  -- configured using `lua_max_uri_args`). The optional `max_args` argument can be
  -- specified to customize this limit, but must be greater than **1** and not
  -- greater than **1000**.
  --
  -- @function kong.request.get_query
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @tparam[opt] number max_args Sets a limit on the maximum number of parsed
  -- arguments.
  -- @treturn table A table representation of the query string.
  -- @usage
  -- -- Given a request GET /test?foo=hello%20world&bar=baz&zzz&blo=&bar=bla&bar
  --
  -- for k, v in pairs(kong.request.get_query()) do
  --   kong.log.inspect(k, v)
  -- end
  --
  -- -- Will print
  -- -- "foo" "hello world"
  -- -- "bar" {"baz", "bla", true}
  -- -- "zzz" true
  -- -- "blo" ""
  function _REQUEST.get_query(max_args)
    check_phase(PHASES.request)

    if max_args ~= nil then
      if type(max_args) ~= "number" then
        error("max_args must be a number", 2)
      end

      if max_args < MIN_QUERY_ARGS then
        error("max_args must be >= " .. MIN_QUERY_ARGS, 2)
      end

      if max_args > MAX_QUERY_ARGS then
        error("max_args must be <= " .. MAX_QUERY_ARGS, 2)
      end
    end

    local ctx = ngx.ctx
    if ctx.KONG_UNEXPECTED and _REQUEST.get_http_version() < 2 then
      local req_line = var.request
      local qidx = find(req_line, "?", 1, true)
      if not qidx then
        return {}
      end

      local eidx = find(req_line, " ", qidx + 1, true)
      if not eidx then
        -- HTTP 414, req_line is too long
        return {}
      end

      return decode_args(sub(req_line, qidx + 1, eidx - 1), max_args)
    end

    local uri_args, err = get_uri_args(max_args, ctx.uri_args)
    if uri_args then
      ctx.uri_args = uri_args
    end

    return uri_args, err
  end


  ---
  -- Returns the value of the specified request header.
  --
  -- The returned value is either a `string`, or can be `nil` if a header with
  -- `name` was not found in the request. If a header with the same name is
  -- present multiple times in the request, this function returns the value
  -- of the first occurrence of this header.
  --
  -- Header names in are case-insensitive and are normalized to lowercase, and
  -- dashes (`-`) can be written as underscores (`_`); that is, the header
  -- `X-Custom-Header` can also be retrieved as `x_custom_header`.
  --
  -- @function kong.request.get_header
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @tparam string name the name of the header to be returned
  -- @treturn string|nil the value of the header or nil if not present
  -- @usage
  -- -- Given a request with the following headers:
  --
  -- -- Host: foo.com
  -- -- X-Custom-Header: bla
  -- -- X-Another: foo bar
  -- -- X-Another: baz
  --
  -- kong.request.get_header("Host")            -- "foo.com"
  -- kong.request.get_header("x-custom-header") -- "bla"
  -- kong.request.get_header("X-Another")       -- "foo bar"
  function _REQUEST.get_header(name, ctx)
    check_phase(PHASES.request)

    if type(name) ~= "string" then
      error("header name must be a string", 2)
    end

    return http_get_header(name, ctx)
  end


  ---
  -- Returns a Lua table holding the request headers. Keys are header names.
  -- Values are either a string with the header value, or an array of strings
  -- if a header was sent multiple times. Header names in this table are
  -- case-insensitive and are normalized to lowercase, and dashes (`-`) can be
  -- written as underscores (`_`); that is, the header `X-Custom-Header` can
  -- also be retrieved as `x_custom_header`.
  --
  -- By default, this function returns up to **100** headers (or what has been
  -- configured using `lua_max_req_headers`). The optional `max_headers` argument
  -- can be specified to customize this limit, but must be greater than **1** and
  -- not greater than **1000**.
  --
  -- @function kong.request.get_headers
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @tparam[opt] number max_headers Sets a limit on the maximum number of
  -- parsed headers.
  -- @treturn table The request headers in table form.
  -- @usage
  -- -- Given a request with the following headers:
  --
  -- -- Host: foo.com
  -- -- X-Custom-Header: bla
  -- -- X-Another: foo bar
  -- -- X-Another: baz
  -- local headers = kong.request.get_headers()
  --
  -- headers.host            -- "foo.com"
  -- headers.x_custom_header -- "bla"
  -- headers.x_another[1]    -- "foo bar"
  -- headers["X-Another"][2] -- "baz"
  function _REQUEST.get_headers(max_headers)
    check_phase(PHASES.request)

    if max_headers == nil then
      return get_headers()
    end

    if type(max_headers) ~= "number" then
      error("max_headers must be a number", 2)
    elseif max_headers < MIN_HEADERS then
      error("max_headers must be >= " .. MIN_HEADERS, 2)
    elseif max_headers > MAX_HEADERS then
      error("max_headers must be <= " .. MAX_HEADERS, 2)
    end

    return get_headers(max_headers)
  end


  local before_content = phase_checker.new(PHASES.rewrite,
                                           PHASES.access,
                                           PHASES.response,
                                           PHASES.error,
                                           PHASES.admin_api)


  ---
  -- Returns the plain request body.
  --
  -- If the body has no size (empty), this function returns an empty string.
  --
  -- If the size of the body is greater than the Nginx buffer size (set by
  -- `client_body_buffer_size`), this function fails and returns an error
  -- message explaining this limitation, unless `max_allowed_file_size`
  -- is set and equal to 0 or larger than the body size buffered to disk.
  -- Use of `max_allowed_file_size` requires Kong to read data from filesystem
  -- and has performance implications.
  --
  -- @function kong.request.get_raw_body
  -- @phases rewrite, access, response, admin_api
  -- @max_allowed_file_size[opt] number the max allowed file size to be read from,
  -- 0 means unlimited, but the size of this body will still be limited
  -- by Nginx's client_max_body_size.
  -- @treturn string|nil The plain request body or nil if it does not fit into
  -- the NGINX temporary buffer.
  -- @treturn nil|string An error message.
  -- @usage
  -- -- Given a body with payload "Hello, Earth!":
  --
  -- kong.request.get_raw_body():gsub("Earth", "Mars") -- "Hello, Mars!"
  function _REQUEST.get_raw_body(max_allowed_file_size)
    check_phase(before_content)

    read_body()

    local body = get_body_data()
    if not body then
      local body_file = get_body_file()
      if not body_file then
        return ""
      end

      if not max_allowed_file_size or max_allowed_file_size < 0 then
        return nil, "request body did not fit into client body buffer, consider raising 'client_body_buffer_size'"
      end

      local file, err = io.open(body_file, "r")
      if not file then
        return nil, "failed to open cached request body '" .. body_file .. "': " .. err
      end

      local size = file:seek("end") or 0
      if max_allowed_file_size > 0 and size > max_allowed_file_size then
        return nil, ("request body file too big: %d > %d"):format(size, max_allowed_file_size)
      end

      -- go to beginning
      file:seek("set")
      local chunk = {}
      local chunk_idx = 1

      while true do
        local data, err = file:read(1048576) -- read in chunks of 1mb
        if not data then
          if err then
            return nil, "failed to read cached request body '" .. body_file .. "': " .. err
          end
          break
        end
        chunk[chunk_idx] = data
        chunk_idx = chunk_idx + 1

        yield() -- yield to prevent starvation while doing blocking IO-reads
      end

      file:close()

      return table.concat(chunk, "")
    end

    return body
  end


  ---
  -- Returns the request data as a key/value table.
  -- A high-level convenience function.
  --
  -- The body is parsed with the most appropriate format:
  --
  -- * If `mimetype` is specified, it decodes the body with the requested
  --   content type (if supported). This takes precedence over any content type
  --   present in the request.
  --
  --   The optional argument `mimetype` can be one of the following strings:
  --     * `application/x-www-form-urlencoded`
  --     * `application/json`
  --     * `multipart/form-data`
  --
  -- Whether `mimetype` is specified or a request content type is otherwise
  -- present in the request, each content type behaves as follows:
  --
  -- * If the request content type is `application/x-www-form-urlencoded`:
  --   * Returns the body as form-encoded.
  -- * If the request content type is `multipart/form-data`:
  --   * Decodes the body as multipart form data
  --     (same as `multipart(kong.request.get_raw_body(),
  --     kong.request.get_header("Content-Type")):get_all()` ).
  -- * If the request content type is `application/json`:
  --   * Decodes the body as JSON
  --     (same as `json.decode(kong.request.get_raw_body())`).
  --   * JSON types are converted to matching Lua types.
  -- * If the request contains none of the above and the `mimetype` argument is
  --   not set, returns `nil` and an error message indicating the
  --   body could not be parsed.
  --
  -- The optional argument `max_args` can be used to set a limit on the number
  -- of form arguments parsed for `application/x-www-form-urlencoded` payloads,
  -- which is by default **100** (or what has been configured using `lua_max_post_args`).
  --
  -- The third return value is string containing the mimetype used to parsed
  -- the body (as per the `mimetype` argument), allowing the caller to identify
  -- what MIME type the body was parsed as.
  --
  -- @function kong.request.get_body
  -- @phases rewrite, access, response, admin_api
  -- @tparam[opt] string mimetype The MIME type.
  -- @tparam[opt] number max_args Sets a limit on the maximum number of parsed
  -- @tparam[opt] number max_allowed_file_size the max allowed file size to be read from
  -- arguments.
  -- @treturn table|nil A table representation of the body.
  -- @treturn string|nil An error message.
  -- @treturn string|nil mimetype The MIME type used.
  -- @usage
  -- local body, err, mimetype = kong.request.get_body()
  -- body.name -- "John Doe"
  -- body.age  -- "42"
  function _REQUEST.get_body(mimetype, max_args, max_allowed_file_size)
    check_phase(before_content)
    local content_type = mimetype or ngx.var.http_content_type
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

      -- TODO: should we also compare content_length to client_body_buffer_size here?

      read_body()

      local pargs, err

      -- For some APIs, especially those using Lua C API (perhaps FFI too),
      -- there is a difference in passing nil and not passing anything.
      if max_args ~= nil then
        pargs, err = get_post_args(max_args)
      else
        pargs, err = get_post_args()
      end

      if not pargs then
        return nil, err, CONTENT_TYPE_POST
      end

      return pargs, nil, CONTENT_TYPE_POST

    elseif find(content_type_lower, CONTENT_TYPE_JSON, 1, true) == 1 then
      local body, err = _REQUEST.get_raw_body(max_allowed_file_size)
      if not body then
        return nil, err, CONTENT_TYPE_JSON
      end

      local json = cjson.decode_with_array_mt(body)
      if type(json) ~= "table" then
        return nil, "invalid json body", CONTENT_TYPE_JSON
      end

      return json, nil, CONTENT_TYPE_JSON

    elseif find(content_type_lower, CONTENT_TYPE_FORM_DATA, 1, true) == 1 then
      local body, err = _REQUEST.get_raw_body(max_allowed_file_size)
      if not body then
        return nil, err, CONTENT_TYPE_FORM_DATA
      end

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

  ---
  -- Returns the request start time, in Unix epoch milliseconds.
  --
  -- @function kong.request.get_start_time
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn number The timestamp
  -- @usage
  -- kong.request.get_start_time() -- 1649960273000
  function _REQUEST.get_start_time()
    check_phase(PHASES.request)

    return ngx.ctx.KONG_PROCESSING_START or (start_time() * 1000)
  end

  local EMPTY = {}

  local function capture_wrap(capture)
    local named_captures = {}
    local unnamed_captures = {}
    for k, v in pairs(capture) do
      local typ = type(k)
      if typ == "number" then
        unnamed_captures[k] = v

      elseif typ == "string" then
        named_captures[k] = v

      else
        kong.log.err("unknown capture key type: ", typ)
      end
    end

    return {
      unnamed = setmetatable(unnamed_captures, cjson.array_mt),
      named = named_captures,
    }
  end

  ---
  -- Returns the URI captures matched by the router.
  --
  -- @function kong.request.get_uri_captures
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn table tables containing unamed and named captures.
  -- @usage
  -- local captures = kong.request.get_uri_captures()
  -- for idx, value in ipairs(captures.unnamed) do
  --   -- do what you want to captures
  -- end
  -- for name, value in pairs(captures.named) do
  --   -- do what you want to captures
  -- end
  function _REQUEST.get_uri_captures(ctx)
    check_phase(PHASES.request)
    ctx = ctx or ngx.ctx

    local captures = ctx.router_matches and ctx.router_matches.uri_captures or EMPTY

    return capture_wrap(captures)
  end

  return _REQUEST
end


return {
  new = new,
}
