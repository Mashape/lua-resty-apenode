---
-- This namespace contains an instance of a logging facility, which is a
-- table containing all of the methods described below.
--
-- This instance is namespaced per plugin. Before
-- executing a plugin, Kong swaps this instance with a logging facility
-- dedicated to the plugin. This allows the logs to be prefixed with the
-- plugin's name for debugging purposes.
--
-- @module kong.log


local buffer = require("string.buffer")
local errlog = require("ngx.errlog")
local ngx_re = require("ngx.re")
local inspect = require("inspect")
local phase_checker = require("kong.pdk.private.phases")
local constants = require("kong.constants")
local clear_tab = require("table.clear")
local ngx_null = ngx.null


local request_id_get = require("kong.observability.tracing.request_id").get
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy
local get_tls1_version_str = require("ngx.ssl").get_tls1_version_str
local get_workspace_name = require("kong.workspaces").get_workspace_name
local dynamic_hook = require("kong.dynamic_hook")


local sub = string.sub
local type = type
local error = error
local pairs = pairs
local ipairs = ipairs
local find = string.find
local select = select
local concat = table.concat
local insert = table.insert
local getinfo = debug.getinfo
local reverse = string.reverse
local tostring = tostring
local tonumber = tonumber
local setmetatable = setmetatable
local ngx = ngx
local kong = kong
local check_phase = phase_checker.check
local byte = string.byte


local DOT_BYTE = byte(".")
local FFI_ERROR = require("resty.core.base").FFI_ERROR


local _PREFIX = "[kong] "
local _DEFAULT_FORMAT = "%file_src:%line_src %message"
local _DEFAULT_NAMESPACED_FORMAT = "%file_src:%line_src [%namespace] %message"
local PHASES = phase_checker.phases
local PHASES_LOG = PHASES.log
local QUESTION_MARK = byte("?")
local TYPE_NAMES = constants.RESPONSE_SOURCE.NAMES


local ngx_lua_ffi_raw_log do
  if ngx.config.subsystem == "http" or ngx.config.is_console then -- luacheck: ignore
    ngx_lua_ffi_raw_log = require("ffi").C.ngx_http_lua_ffi_raw_log

  elseif ngx.config.subsystem == "stream" then
    ngx_lua_ffi_raw_log = require("ffi").C.ngx_stream_lua_ffi_raw_log
  end
end


local phases_with_ctx =
    phase_checker.new(PHASES.rewrite,
                      PHASES.access,
                      PHASES.header_filter,
                      PHASES.response,
                      PHASES.body_filter,
                      PHASES_LOG)
local _LEVELS = {
  debug = ngx.DEBUG,
  info = ngx.INFO,
  notice = ngx.NOTICE,
  warn = ngx.WARN,
  err = ngx.ERR,
  crit = ngx.CRIT,
  alert = ngx.ALERT,
  emerg = ngx.EMERG,
}


local _MODIFIERS = {
  ["%file_src"] = {
    flag = "S",
    info = function(info)
      local short_src = info.short_src
      if short_src then
        local rev_src = reverse(short_src)
        local idx = find(rev_src, "/", nil, true)
        if idx then
          return sub(short_src, #rev_src - idx + 2)
        end

        return short_src
      end
    end
  },

  ["%line_src"] = {
    flag = "l",
    info_key = "currentline",
  },

  ["%func_name"] = {
    flag = "n",
    info_key = "name",
  },

  ["%message"] = {
    message = true,
  },

  -- %namespace -- precompiled
}


local function parse_modifiers(format)
  local buf, err = ngx_re.split(format, [==[(?<!%)(%[a-z_]+)]==], nil, nil, 0)
  if not buf then
    return nil, "could not parse format: " .. err
  end

  local buf_len = #buf

  for i = 1, buf_len do
    local mod = _MODIFIERS[buf[i]]
    if mod then
      if mod.message then
        buf.message_idxs = buf.message_idxs or {}
        insert(buf.message_idxs, i)

      else
        buf.debug_flags = (buf.debug_flags or "") .. mod.flag

        buf.modifiers = buf.modifiers or {}
        insert(buf.modifiers, {
          idx = i,
          info = mod.info,
          info_key = mod.info_key,
        })
      end
    end
  end

  buf.n_modifiers = buf.modifiers and #buf.modifiers or 0
  buf.n_messages = buf.message_idxs and #buf.message_idxs or 0
  buf.n_len = buf_len

  return buf
end


local serializers = {
  [1] = function(buf, sep, to_string, ...)
    buf:put(to_string((select(1, ...))))
  end,

  [2] = function(buf, sep, to_string, ...)
    buf:put(to_string((select(1, ...))), sep,
            to_string((select(2, ...))))
  end,

  [3] = function(buf, sep, to_string, ...)
    buf:put(to_string((select(1, ...))), sep,
            to_string((select(2, ...))), sep,
            to_string((select(3, ...))))
  end,

  [4] = function(buf, sep, to_string, ...)
    buf:put(to_string((select(1, ...))), sep,
            to_string((select(2, ...))), sep,
            to_string((select(3, ...))), sep,
            to_string((select(4, ...))))
  end,

  [5] = function(buf, sep, to_string, ...)
    buf:put(to_string((select(1, ...))), sep,
            to_string((select(2, ...))), sep,
            to_string((select(3, ...))), sep,
            to_string((select(4, ...))), sep,
            to_string((select(5, ...))))
  end,
}

local function raw_log_inspect(level, msg)
  if type(level) ~= "number" then
    error("bad argument #1 to 'raw_log' (must be a number)", 2)
  end

  if type(msg) ~= "string" then
    error("bad argument #2 to 'raw_log' (must be a string)", 2)
  end

  local rc = ngx_lua_ffi_raw_log(nil, level, msg, #msg)
  if rc == FFI_ERROR then
    error("bad log level", 2)
  end
end


--- Writes a log line to the location specified by the current Nginx
-- configuration block's `error_log` directive, with the `notice` level (similar
-- to `print()`).
--
-- The Nginx `error_log` directive is set via the `log_level`, `proxy_error_log`
-- and `admin_error_log` Kong configuration properties.
--
-- Arguments given to this function are concatenated similarly to
-- `ngx.log()`, and the log line reports the Lua file and line number from
-- which it was invoked. Unlike `ngx.log()`, this function prefixes error
-- messages with `[kong]` instead of `[lua]`.
--
-- Arguments given to this function can be of any type, but table arguments
-- are converted to strings via `tostring` (thus potentially calling a
-- table's `__tostring` metamethod if set). This behavior differs from
-- `ngx.log()` (which only accepts table arguments if they define the
-- `__tostring` metamethod) with the intent to simplify its usage and be more
-- forgiving and intuitive.
--
-- Produced log lines have the following format when logging is invoked from
-- within the core:
--
-- ``` plain
-- [kong] %file_src:%line_src %message
-- ```
--
-- In comparison, log lines produced by plugins have the following format:
--
-- ``` plain
-- [kong] %file_src:%line_src [%namespace] %message
-- ```
--
-- Where:
--
-- * `%namespace`: The configured namespace (in this case, the plugin name).
-- * `%file_src`: The filename the log was called from.
-- * `%line_src`: The line number the log was called from.
-- * `%message`: The message, made of concatenated arguments given by the caller.
--
-- For example, the following call:
--
-- ``` lua
-- kong.log("hello ", "world")
-- ```
--
-- would, within the core, produce a log line similar to:
--
-- ``` plain
-- 2017/07/09 19:36:25 [notice] 25932#0: *1 [kong] some_file.lua:54 hello world, client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- If invoked from within a plugin (for example, `key-auth`) it would include the
-- namespace prefix:
--
-- ``` plain
-- 2017/07/09 19:36:25 [notice] 25932#0: *1 [kong] some_file.lua:54 [key-auth] hello world, client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- @function kong.log
-- @phases init_worker, certificate, rewrite, access, header_filter, response, body_filter, log
-- @param ... All params will be concatenated and stringified before being sent to the log.
-- @return Nothing. Throws an error on invalid inputs.
--
-- @usage
-- kong.log("hello ", "world") -- alias to kong.log.notice()

---
-- Similar to `kong.log()`, but the produced log has the severity given by
-- `<level>`, instead of `notice`. For each message written to the logs,
-- carefully consider who the target audience is, and set the level accordingly.
-- The supported levels are:
--
-- function | usage | audience
-- -|-|-
-- `kong.log.alert()` | Conditions that require immediate intervention. | Platform operators
-- `kong.log.crit()`  | Errors that indicate serious failures in Kong or the underlying system. | Platform operators
-- `kong.log.err()`   | Serious issues that prevent proper request handling but do not cause Kong to stop/fail. | Platform operators
-- `kong.log.warn()`  | Warnings about potential issues that may require intervention but are not immediate failures. | Platform operators
-- `kong.log.notice()`| Typically used for plugin flow analysis, eg. authentication failures. | Plugin author/user
-- `kong.log.info()`  | Used for debugging plugins. Consider this the `debug` level for plugins. | Plugin author
-- `kong.log.debug()` | Reserved for the core engine debug logs, do not use this for plugins. | Kong support/engineering
--
-- Logs have the same format as that of `kong.log()`. For
-- example, the following call:
--
-- ``` lua
--  kong.log.err("hello ", "world")
-- ```
--
-- would, within the core, produce a log line similar to:
--
-- ``` plain
-- 2017/07/09 19:36:25 [error] 25932#0: *1 [kong] some_file.lua:54 hello world, client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- If invoked from within a plugin (for example, `key-auth`) it would include the
-- namespace prefix:
--
-- ``` plain
-- 2017/07/09 19:36:25 [error] 25932#0: *1 [kong] some_file.lua:54 [key-auth] hello world, client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- @function kong.log.LEVEL
-- @phases init_worker, certificate, rewrite, access, header_filter, response, body_filter, log
-- @param ... All params will be concatenated and stringified before being sent to the log.
-- @return Nothing. Throws an error on invalid inputs.
-- @usage
-- kong.log.warn("something require attention")
-- kong.log.err("something failed: ", err)
-- kong.log.alert("something requires immediate action")
local function gen_log_func(lvl_const, imm_buf, to_string, stack_level, sep)
  local get_sys_filter_level = errlog.get_sys_filter_level
  local get_phase = ngx.get_phase

  to_string = to_string or tostring
  stack_level = stack_level or 2

  local variadic_buf = buffer.new()

  return function(...)
    local sys_log_level = nil

    if get_phase() ~= "init" then
      -- only grab sys_log_level after init_by_lua, where it is
      -- hard-coded
      sys_log_level = get_sys_filter_level()
    end

    if sys_log_level and lvl_const > sys_log_level then
      -- early exit if sys_log_level is higher than the current
      -- log call
      return
    end

    -- OpenTelemetry Logs
    -- stack level otel logs = stack_level + 3:
    -- 1: maybe_push
    -- 2: dynamic_hook.pcall
    -- 3: dynamic_hook.run_hook
    dynamic_hook.run_hook("observability_logs", "push", stack_level + 3, nil, lvl_const, ...)

    local n = select("#", ...)

    if imm_buf.debug_flags then
      local info = getinfo(stack_level, imm_buf.debug_flags)

      for i = 1, imm_buf.n_modifiers do
        local mod = imm_buf.modifiers[i]

        if not info then
          imm_buf[mod.idx] = "?"

        elseif mod.info then
          imm_buf[mod.idx] = mod.info(info) or "?"

        else
          imm_buf[mod.idx] = info[mod.info_key] or "?"
        end
      end
    end

    if serializers[n] then
      serializers[n](variadic_buf, sep or "" , to_string, ...)

    else
      for i = 1, n - 1 do
        variadic_buf:put(to_string((select(i, ...))), sep or "")
      end
      variadic_buf:put(to_string((select(n, ...))))
    end

    local msg = variadic_buf:get()

    for i = 1, imm_buf.n_messages do
      imm_buf[imm_buf.message_idxs[i]] = msg
    end

    local fullmsg = concat(imm_buf, nil, 1, imm_buf.n_len)

    if to_string == inspect then
      local fullmsg_len = #fullmsg
      local WRAP = 120

      local i = fullmsg:find("\n") + 1
      local header = fullmsg:sub(1, i - 2) .. ("-"):rep(WRAP - i + 3) .. "+"

      raw_log_inspect(lvl_const, header)

      while i <= fullmsg_len do
        local part = sub(fullmsg, i, i + WRAP - 1)
        local nl = part:match("()\n")

        if nl then
          part = sub(fullmsg, i, i + nl - 2)
          i = i + nl

        else
          i = i + WRAP
        end

        part = part .. (" "):rep(WRAP - #part)
        raw_log_inspect(lvl_const, "|" .. part .. "|")

        if i > fullmsg_len then
          raw_log_inspect(lvl_const, "+" .. ("-"):rep(WRAP) .. "+")
        end
      end

      return
    end

    errlog.raw_log(lvl_const, fullmsg)
  end
end


--- Write a deprecation log line (similar to `kong.log.warn`).
--
-- Arguments given to this function can be of any type, but table arguments
-- are converted to strings via `tostring` (thus potentially calling a
-- table's `__tostring` metamethod if set). When the last argument is a table,
-- it is considered as a deprecation metadata. The table can include the
-- following properties:
--
-- ``` lua
-- {
--   after = "2.5.0",   -- deprecated after Kong version 2.5.0 (defaults to `nil`)
--   removal = "3.0.0", -- about to be removed with Kong version 3.0.0 (defaults to `nil`)
--   trace = true,      -- writes stack trace along with the deprecation message (defaults to `nil`)
-- }
-- ```
--
-- For example, the following call:
--
-- ``` lua
-- kong.log.deprecation("hello ", "world")
-- ```
--
-- would, within the core, produce a log line similar to:
--
-- ``` plain
-- 2017/07/09 19:36:25 [warn] 25932#0: *1 [kong] some_file.lua:54 hello world, client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- If invoked from within a plugin (for example, `key-auth`) it would include the
-- namespace prefix:
--
-- ``` plain
-- 2017/07/09 19:36:25 [warn] 25932#0: *1 [kong] some_file.lua:54 [key-auth] hello world, client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- And with metatable, the following call:
--
-- ``` lua
-- kong.log.deprecation("hello ", "world", { after = "2.5.0", removal = "3.0.0" })
-- ```
--
-- would, within the core, produce a log line similar to:
--
-- ``` plain
-- 2017/07/09 19:36:25 [warn] 25932#0: *1 [kong] some_file.lua:54 hello world (deprecated after 2.5.0, scheduled for removal in 3.0.0), client: 127.0.0.1, server: localhost, request: "GET /log HTTP/1.1", host: "localhost"
-- ```
--
-- @function kong.log.deprecation
-- @phases init_worker, certificate, rewrite, access, header_filter, response, body_filter, log
-- @param ... all params will be concatenated and stringified before being sent to the log
--            (if the last param is a table, it is considered as a deprecation metadata)
-- @return Nothing; throws an error on invalid inputs.
--
-- @usage
-- kong.log.deprecation("hello ", "world")
-- kong.log.deprecation("hello ", "world", { after = "2.5.0" })
-- kong.log.deprecation("hello ", "world", { removal = "3.0.0" })
-- kong.log.deprecation("hello ", "world", { after = "2.5.0", removal = "3.0.0" })
-- kong.log.deprecation("hello ", "world", { trace = true })
local new_deprecation do
  local mt = getmetatable(require("kong.deprecation"))
  new_deprecation = function(write)
    return setmetatable({ write = write }, mt)
  end
end


---
-- Like `kong.log()`, this function produces a log with a `notice` level
-- and accepts any number of arguments. If inspect logging is disabled
-- via `kong.log.inspect.off()`, then this function prints nothing, and is
-- aliased to a "NOP" function to save CPU cycles.
--
-- This function differs from `kong.log()` in the sense that arguments will be
-- concatenated with a space(`" "`), and each argument is
-- pretty-printed:
--
-- * Numbers are printed (e.g. `5` -> `"5"`)
-- * Strings are quoted (e.g. `"hi"` -> `'"hi"'`)
-- * Array-like tables are rendered (e.g. `{1,2,3}` -> `"{1, 2, 3}"`)
-- * Dictionary-like tables are rendered on multiple lines
--
-- This function is intended for debugging, and usage
-- in production code paths should be avoided due to the expensive formatting
-- operations it can perform. Existing statements can be left in production code
-- but nopped by calling `kong.log.inspect.off()`.
--
-- When writing logs, `kong.log.inspect()` always uses its own format, defined
-- as:
--
-- ``` plain
-- %file_src:%func_name:%line_src %message
-- ```
--
-- Where:
--
-- * `%file_src`: The filename the log was called from.
-- * `%func_name`: The name of the function the log was called from.
-- * `%line_src`: The line number the log was called from.
-- * `%message`: The message, made of concatenated, pretty-printed arguments
--   given by the caller.
--
-- This function uses the [inspect.lua](https://github.com/kikito/inspect.lua)
-- library to pretty-print its arguments.
--
-- @function kong.log.inspect
-- @phases init_worker, certificate, rewrite, access, header_filter, response, body_filter, log
-- @param ... Parameters are concatenated with spaces between them and
-- rendered as described.
-- @usage
-- kong.log.inspect("some value", a_variable)
local new_inspect

do
  local function nop() end


  local _inspect_mt = {
    __call = function(self, ...)
      self.print(...)
    end,
  }


  new_inspect = function(namespace)
    local _INSPECT_FORMAT = _PREFIX .. "%file_src:%func_name:%line_src ["..namespace.."]\n%message"
    local inspect_buf = assert(parse_modifiers(_INSPECT_FORMAT))

    local self = {}


    ---
    -- Enables inspect logs for this logging facility. Calls to
    -- `kong.log.inspect` will be writing log lines with the appropriate
    -- formatting of arguments.
    --
    -- @function kong.log.inspect.on
    -- @phases init_worker, certificate, rewrite, access, header_filter, response, body_filter, log
    -- @usage
    -- kong.log.inspect.on()
    function self.on()
      self.print = gen_log_func(_LEVELS.notice, inspect_buf, inspect, 3, " ")
    end


    ---
    -- Disables inspect logs for this logging facility. All calls to
    -- `kong.log.inspect()` will be nopped.
    --
    -- @function kong.log.inspect.off
    -- @phases init_worker, certificate, rewrite, access, header_filter, response, body_filter, log
    -- @usage
    -- kong.log.inspect.off()
    function self.off()
      self.print = nop
    end


    self.on()


    return setmetatable(self, _inspect_mt)
  end
end


local _log_mt = {
  __call = function(self, ...)
    return self.notice(...)
  end,
}


---
-- Sets a value to be used on the `serialize` custom table.
--
-- Logging plugins use the output of `kong.log.serialize()` as a base for their logs.
-- This function lets you customize the log output.
--
-- It can be used to replace existing values in the output, or to delete
-- existing values by passing `nil`.
--
-- **Note:** The type-checking of the `value` parameter can take some time, so
-- it is deferred to the `serialize()` call, which happens in the log
-- phase in most real-usage cases.
--
-- @function kong.log.set_serialize_value
-- @phases certificate, rewrite, access, header_filter, response, body_filter, log
-- @tparam string key The name of the field.
-- @tparam number|string|boolean|table value Value to be set. When a table is used, its keys must be numbers, strings, or booleans, and its values can be numbers, strings, or other tables like itself, recursively.
-- @tparam table options Can contain two entries: options.mode can be `set` (the default, always sets), `add` (only add if entry does not already exist) and `replace` (only change value if it already exists).
-- @treturn table The request information table.
-- @usage
-- -- Adds a new value to the serialized table
-- kong.log.set_serialize_value("my_new_value", 1)
-- assert(kong.log.serialize().my_new_value == 1)
--
-- -- Value can be a table
-- kong.log.set_serialize_value("my", { new = { value = 2 } })
-- assert(kong.log.serialize().my.new.value == 2)
--
-- -- It is possible to change an existing serialized value
-- kong.log.set_serialize_value("my_new_value", 3)
-- assert(kong.log.serialize().my_new_value == 3)
--
-- -- Unset an existing value by setting it to nil
-- kong.log.set_serialize_value("my_new_value", nil)
-- assert(kong.log.serialize().my_new_value == nil)
--
-- -- Dots in the key are interpreted as table accesses
-- kong.log.set_serialize_value("my.new.value", 4)
-- assert(kong.log.serialize().my.new.value == 4)
--
local function set_serialize_value(key, value, options)
  check_phase(phases_with_ctx)

  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  local mode = options and options.mode or "set"
  if mode ~= "set" and mode ~= "add" and mode ~= "replace" then
    error("mode must be 'set', 'add' or 'replace'", 2)
  end

  local data = {
    key = key,
    value = value,
    mode = mode,
  }

  local ongx = options and options.ngx or ngx
  local ctx = ongx.ctx
  local serialize_values = ctx.serialize_values
  if serialize_values then
    serialize_values[#serialize_values + 1] = data
  else
    ctx.serialize_values = { data }
  end
end


local serialize
do
  local VISITED = {}

  local function is_valid_value(v, visited)
    local t = type(v)

    -- cdata is not supported by cjson.encode
    if type(v) == 'cdata' then
        return false

    elseif v == nil or v == ngx_null or t == "number" or t == "string" or t == "boolean" then
      return true
    end

    if t ~= "table" then
      return false
    end

    if not visited then
      clear_tab(VISITED)
      visited = VISITED

    elseif visited[v] then
      return false
    end

    visited[v] = true

    for k, val in pairs(v) do
      t = type(k)
      if (t ~= "string" and t ~= "number" and t ~= "boolean")
      or not is_valid_value(val, visited)
      then
        return false
      end
    end

    return true
  end


  -- Modify returned table with values set with kong.log.set_serialize_values
  local function edit_result(root, serialize_values)
    for _, item in ipairs(serialize_values) do
      local new_value = item.value
      if not is_valid_value(new_value) then
        error("value must be nil, a number, string, boolean or a non-self-referencial table containing numbers, string and booleans", 3)
      end

      -- Split key by ., creating sub-tables when needed
      local key = item.key
      local mode = item.mode
      local is_set_or_add = mode == "set" or mode == "add"
      local node = root
      local start = 1
      for i = 2, #key do
        if byte(key, i) == DOT_BYTE then
          local subkey = sub(key, start, i - 1)
          start = i + 1
          if node[subkey] == nil then
            if is_set_or_add then
              node[subkey] = {} -- add sub-tables as needed
            else
              node = nil
              break -- mode == replace; and we have a missing link on the "chain"
            end

          elseif type(node[subkey]) ~= "table" then
            error("The key '" .. key .. "' could not be used as a serialize value. " ..
                  "Subkey '" .. subkey .. "' is not a table. It's " .. tostring(node[subkey]))
          end

          node = node[subkey]
        end
      end

      if type(node) == "table" then
        local last_subkey = sub(key, start)
        local existing_value = node[last_subkey]
        if (mode == "set")
        or (mode == "add"     and existing_value == nil)
        or (mode == "replace" and existing_value ~= nil)
        then
          node[last_subkey] = new_value
        end
      end
    end

    return root
  end

  local function build_authenticated_entity(ctx)
    local credential = ctx.authenticated_credential
    if credential ~= nil then
      local consumer_id = credential.consumer_id
      if not consumer_id then
        local consumer = ctx.authenticate_consumer
        if consumer ~= nil then
          consumer_id = consumer.id
        end
      end

      return {
        id = credential.id,
        consumer_id = consumer_id,
      }
    end
  end

  local function build_tls_info(var, override)
    local tls_info_ver = get_tls1_version_str()
    if tls_info_ver then
      return {
        version = tls_info_ver,
        cipher = var.ssl_cipher,
        client_verify = override or var.ssl_client_verify,
      }
    end
  end

  local function to_decimal(str)
    local n = tonumber(str, 10)
    return n or str
  end

  ---
  -- Generates a table with useful information for logging.
  --
  -- This method can be used in the `http` subsystem.
  --
  -- The following fields are included in the returned table:
  -- * `client_ip` - client IP address in textual format.
  -- * `latencies` - request/proxy latencies.
  -- * `request.id` - request id.
  -- * `request.headers` - request headers.
  -- * `request.method` - request method.
  -- * `request.querystring` - request query strings.
  -- * `request.size` - size of request.
  -- * `request.url` and `request.uri` - URL and URI of request.
  -- * `response.headers` - response headers.
  -- * `response.size` - size of response.
  -- * `response.status` - response HTTP status code.
  -- * `route` - route object matched.
  -- * `service` - service object used.
  -- * `started_at` - timestamp this request came in, in milliseconds.
  -- * `tries` - Upstream information; this is an array and if any balancer retries occurred, will contain more than one entry.
  -- * `upstream_uri` - request URI sent to Upstream.
  --
  -- The following fields are only present in an authenticated request (with consumer):
  --
  -- * `authenticated_entity` - credential used for authentication.
  -- * `consumer` - consumer entity accessing the resource.
  --
  -- The following fields are only present in a TLS/HTTPS request:
  -- * `request.tls.version` - TLS/SSL version used by the connection.
  -- * `request.tls.cipher` - TLS/SSL cipher used by the connection.
  -- * `request.tls.client_verify` - mTLS validation result. Contents are the same as described in [$ssl_client_verify](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#var_ssl_client_verify).
  --
  -- The following field is only present in requests where a tracing plugin (OpenTelemetry or Zipkin) is executed:
  -- * `trace_id` - trace ID.
  --
  -- The following field is only present in requests where the Correlation ID plugin is executed:
  -- * `correlation_id` - correlation ID.
  --
  -- **Warning:** This function may return sensitive data (e.g., API keys).
  -- Consider filtering before writing it to unsecured locations.
  --
  -- All fields in the returned table may be altered using `kong.log.set_serialize_value`.
  --
  -- The following HTTP authentication headers are redacted by default, if they appear in the request:
  -- * `request.headers.authorization`
  -- * `request.headers.proxy-authorization`
  --
  -- To see what content is present in your setup, enable any of the logging
  -- plugins (e.g., `file-log`) and the output written to the log file is the table
  -- returned by this function JSON-encoded.
  --
  -- @function kong.log.serialize
  -- @phases log
  -- @treturn table the request information table
  -- @usage
  -- kong.log.serialize()

  if ngx.config.subsystem == "http" then
    function serialize(options)
      check_phase(PHASES_LOG)

      local ongx = options and options.ngx or ngx
      local okong = options and options.kong or kong
      local okong_request = okong.request

      local ctx = ongx.ctx
      local var = ongx.var

      local request_uri = ctx.request_uri or var.request_uri or ""
      local upstream_uri = var.upstream_uri or ""
      if upstream_uri ~= "" and not find(upstream_uri, "?", nil, true) then
        if byte(request_uri, -1) == QUESTION_MARK then
          upstream_uri = upstream_uri .. "?"
        elseif var.is_args == "?" then
          upstream_uri = upstream_uri .. "?" .. (var.args or "")
        end
      end

      -- THIS IS AN INTERNAL ONLY FLAG TO SKIP FETCHING HEADERS,
      -- AND THIS FLAG MIGHT BE REMOVED IN THE FUTURE
      -- WITHOUT ANY NOTICE AND DEPRECATION.
      local request_headers
      local response_headers
      if not (options and options.__skip_fetch_headers__) then
        request_headers = okong_request.get_headers()
        response_headers = ongx.resp.get_headers()
        if request_headers["authorization"] ~= nil then
          request_headers["authorization"] = "REDACTED"
        end
        if request_headers["proxy-authorization"] ~= nil then
          request_headers["proxy-authorization"] = "REDACTED"
        end
      end

      local url
      local host_port = ctx.host_port or tonumber(var.server_port, 10)
      if host_port then
        url = var.scheme .. "://" .. var.host .. ":" .. host_port .. request_uri
      else
        url = var.scheme .. "://" .. var.host .. request_uri
      end

      local root = {
        request = {
          id = request_id_get() or "",
          uri = request_uri,
          url = url,
          querystring = okong_request.get_query(), -- parameters, as a table
          method = okong_request.get_method(), -- http method
          headers = request_headers,
          size = to_decimal(var.request_length),
          tls = build_tls_info(var, ctx.CLIENT_VERIFY_OVERRIDE),
        },
        upstream_uri = upstream_uri,
        upstream_status = var.upstream_status or ctx.buffered_status or "",
        response = {
          status = ongx.status,
          headers = response_headers,
          size = to_decimal(var.bytes_sent),
        },
        latencies = {
          kong = ctx.KONG_PROXY_LATENCY or ctx.KONG_RESPONSE_LATENCY or 0,
          proxy = ctx.KONG_WAITING_TIME or -1,
          request = tonumber(var.request_time) * 1000,
          receive = ctx.KONG_RECEIVE_TIME or 0,
        },
        tries = ctx.balancer_data and ctx.balancer_data.tries,
        authenticated_entity = build_authenticated_entity(ctx),
        route = cycle_aware_deep_copy(ctx.route),
        service = cycle_aware_deep_copy(ctx.service),
        consumer = cycle_aware_deep_copy(ctx.authenticated_consumer),
        client_ip = var.remote_addr,
        started_at = okong_request.get_start_time(),
        source = TYPE_NAMES[okong.response.get_source(ctx)],
        workspace = ctx.workspace,
        workspace_name = get_workspace_name(),
      }

      local serialize_values = ctx.serialize_values
      if serialize_values then
        root = edit_result(root, serialize_values)
      end

      return root
    end

  else
    function serialize(options)
      check_phase(PHASES_LOG)

      local ongx = options and options.ngx or ngx
      local okong = options and options.kong or kong

      local ctx = ongx.ctx
      local var = ongx.var

      local root = {
        session = {
          tls = build_tls_info(var, ctx.CLIENT_VERIFY_OVERRIDE),
          received = to_decimal(var.bytes_received),
          sent = to_decimal(var.bytes_sent),
          status = ongx.status,
          server_port = ctx.host_port or tonumber(var.server_port, 10),
        },
        upstream = {
          received = to_decimal(var.upstream_bytes_received),
          sent = to_decimal(var.upstream_bytes_sent),
        },
        latencies = {
          kong = ctx.KONG_PROXY_LATENCY or ctx.KONG_RESPONSE_LATENCY or 0,
          session = var.session_time * 1000,
        },
        tries = ctx.balancer_data and ctx.balancer_data.tries,
        authenticated_entity = build_authenticated_entity(ctx),
        route = cycle_aware_deep_copy(ctx.route),
        service = cycle_aware_deep_copy(ctx.service),
        consumer = cycle_aware_deep_copy(ctx.authenticated_consumer),
        client_ip = var.remote_addr,
        started_at = okong.request.get_start_time(),
        workspace = ctx.workspace,
        workspace_name = get_workspace_name(),
      }

      local serialize_values = ctx.serialize_values
      if serialize_values then
        root = edit_result(root, serialize_values)
      end

      return root
    end
  end
end


local IS_TESTING
local NOOP = function() end


local function new_log(namespace, format)
  if type(namespace) ~= "string" then
    error("namespace must be a string", 2)
  end

  if namespace == "" then
    error("namespace cannot be an empty string", 2)
  end

  if format then
    if type(format) ~= "string" then
      error("format must be a string if specified", 2)
    end

    if format == "" then
      error("format cannot be an empty string if specified", 2)
    end
  end

  local self = {}

  function self.set_format(fmt)
    if fmt and type(fmt) ~= "string" then
      error("format must be a string", 2)

    elseif not fmt then
      fmt = _DEFAULT_NAMESPACED_FORMAT
    end

    -- pre-compile namespace into format
    local format = _PREFIX .. fmt:gsub("([^%%])%%namespace", "%1" .. namespace)

    local buf, err = parse_modifiers(format)
    if not buf then
      error(err, 2)
    end

    for log_lvl_name, log_lvl in pairs(_LEVELS) do
      self[log_lvl_name] = gen_log_func(log_lvl, buf)
    end

    self.deprecation = new_deprecation(gen_log_func(_LEVELS.warn, buf, nil, 5))
  end

  self.set_format(format)

  self.inspect = new_inspect(namespace)

  if IS_TESTING then
    self.trace = self.debug
  else
    self.trace = NOOP
  end

  self.set_serialize_value = set_serialize_value
  self.serialize = serialize

  return setmetatable(self, _log_mt)
end


_log_mt.__index = _log_mt
_log_mt.new = new_log


return {
  new = function()
    if IS_TESTING == nil then
      IS_TESTING = os.getenv("KONG_IS_TESTING") == "1"
    end
    return new_log("core", _DEFAULT_FORMAT)
  end,
}
