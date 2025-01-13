local ran_before


return function(options)

  if ran_before then
    ngx.log(ngx.WARN, debug.traceback("attempt to re-run the globalpatches", 2))
    return
  end
  ngx.log(ngx.DEBUG, "installing the globalpatches")
  ran_before = true


  options = options or {}
  local meta = require "kong.meta"
  local constants = require "kong.constants"


  local cjson_safe = require("cjson.safe")
  cjson_safe.encode_sparse_array(nil, nil, 2^15)
  cjson_safe.encode_number_precision(constants.CJSON_MAX_PRECISION)

  local pb = require "pb"

  -- let pb decode arrays to table cjson.empty_array_mt metatable
  -- so empty arrays are encoded as `[]` instead of `nil` or `{}` by cjson.
  pb.option("decode_default_array")
  pb.defaults("*array", cjson_safe.empty_array_mt)

  if options.cli then
    -- disable the _G write guard alert log introduced in OpenResty 1.15.8.1
    -- when in CLI or when running tests in resty-cli
    --local _G_mt = getmetatable(_G)
    setmetatable(_G, nil)
  end


  _G._KONG = {
    _NAME = meta._NAME,
    _VERSION = meta._VERSION
  }

  if options.cli then
    ngx.IS_CLI = true
    -- luacheck: globals ngx.exit
    ngx.exit = function() end
  end



  do -- implement `sleep` in the `init_worker` context

    -- initialization code regularly uses the shm and locks.
    -- the resty-lock is based on sleeping while waiting, but that api
    -- is unavailable. Hence we implement a BLOCKING sleep, only in
    -- the init_worker context.
    local get_phase = ngx.get_phase
    local ngx_sleep = ngx.sleep
    local alternative_sleep = function(t)
      require("socket").sleep(t)
      -- the ngx sleep will yield and hence update time, this implementation
      -- does not, so we must force a time update to prevent time based loops
      -- from getting into a deadlock/spin.
      -- See https://github.com/Kong/lua-resty-worker-events/issues/41
      ngx.update_time()
    end

    -- luacheck: globals ngx.sleep
    local blocking_sleep_phases = {
      init = true,
      init_worker = true,
    }
    ngx.sleep = function(s)
      if blocking_sleep_phases[get_phase()] then
        ngx.log(ngx.NOTICE, "executing a blocking 'sleep' (", s, " seconds)")
        return alternative_sleep(s)
      end
      return ngx_sleep(s)
    end

    _G.native_ngx_sleep = ngx_sleep

  end


  do
    _G.native_timer_at = ngx.timer.at
    _G.native_timer_every = ngx.timer.every

    local _timerng

    if options.cli or options.rbusted then
      _timerng = require("resty.timerng").new({
        min_threads = 16,
        max_threads = 32,
      })

      _timerng:start()

    else
      _timerng = require("resty.timerng").new({
        min_threads = 256,
        max_threads = 1024,
      })
    end

    _G.timerng = _timerng

    _G.ngx.timer.at = function (delay, callback, ...)
      return _timerng:at(delay, callback, ...)
    end

    _G.ngx.timer.every = function (interval, callback, ...)
      return _timerng:every(interval, callback, ...)
    end
  end


  do
    if ngx.config.subsystem == "http" then
      local get_request = require("resty.core.base").get_request

      local error = error

      local get_req_headers = ngx.req.get_headers
      local get_resp_headers = ngx.resp.get_headers
      local get_uri_args = ngx.req.get_uri_args
      local get_post_args = ngx.req.get_post_args
      local decode_args = ngx.decode_args
      local read_req_body = ngx.req.read_body

      local DEFAULT_MAX_REQ_HEADERS = 100
      local DEFAULT_MAX_RESP_HEADERS = 100
      local DEFAULT_MAX_URI_ARGS = 100
      local DEFAULT_MAX_POST_ARGS = 100
      local DEFAULT_MAX_DECODE_ARGS = 100

      local MAX_REQ_HEADERS
      local MAX_RESP_HEADERS
      local MAX_URI_ARGS
      local MAX_POST_ARGS
      local MAX_DECODE_ARGS

      -- REQUEST HEADERS [
      local function get_req_headers_real(max_req_headers, ...)
        local request_headers, err = get_req_headers(max_req_headers or MAX_REQ_HEADERS or DEFAULT_MAX_REQ_HEADERS, ...)
        if err == "truncated" then
          kong.log.notice("request headers truncated")
        end
        return request_headers, err
      end

      _G.ngx.req.get_headers = function(max_req_headers, ...)
        if not get_request() then
          error("no request found")
        end
        MAX_REQ_HEADERS = kong and kong.configuration and kong.configuration.lua_max_req_headers or DEFAULT_MAX_REQ_HEADERS
        _G.ngx.req.get_headers = get_req_headers_real
        return get_req_headers_real(max_req_headers or MAX_REQ_HEADERS, ...)
      end
      -- ]

      -- RESPONSE HEADERS [
      local function get_resp_headers_real(max_resp_headers, ...)
        local response_headers, err = get_resp_headers(max_resp_headers or MAX_RESP_HEADERS or DEFAULT_MAX_RESP_HEADERS, ...)
        if err == "truncated" then
          kong.log.notice("response headers truncated")
        end
        return response_headers, err
      end

      _G.ngx.resp.get_headers = function(max_resp_headers, ...)
        if not get_request() then
          error("no request found")
        end
        MAX_RESP_HEADERS = kong and kong.configuration and kong.configuration.lua_max_resp_headers or DEFAULT_MAX_RESP_HEADERS
        _G.ngx.resp.get_headers = get_resp_headers_real
        return get_resp_headers_real(max_resp_headers or MAX_RESP_HEADERS, ...)
      end
      -- ]

      -- URI ARGS [
      local function get_uri_args_real(max_uri_args, ...)
        local uri_args, err = get_uri_args(max_uri_args or MAX_URI_ARGS or DEFAULT_MAX_URI_ARGS, ...)
        if err == "truncated" then
          kong.log.notice("uri args truncated")
        end
        return uri_args, err
      end

      _G.ngx.req.get_uri_args = function(max_uri_args, ...)
        if not get_request() then
          error("no request found")
        end
        MAX_URI_ARGS = kong and kong.configuration and kong.configuration.lua_max_uri_args or DEFAULT_MAX_URI_ARGS
        _G.ngx.req.get_uri_args = get_uri_args_real
        return get_uri_args_real(max_uri_args or MAX_URI_ARGS, ...)
      end
      -- ]

      -- POST ARGS [
      local function get_post_args_real(max_post_args, ...)
        local post_args, err = get_post_args(max_post_args or MAX_POST_ARGS or DEFAULT_MAX_POST_ARGS, ...)
        if err == "truncated" then
          kong.log.notice("post args truncated")
        end
        return post_args, err
      end

      _G.ngx.req.get_post_args = function(max_post_args, ...)
        if not get_request() then
          error("no request found")
        end
        MAX_POST_ARGS = kong and kong.configuration and kong.configuration.lua_max_post_args or DEFAULT_MAX_POST_ARGS
        _G.ngx.req.get_post_args = get_post_args_real
        return get_post_args_real(max_post_args or MAX_POST_ARGS, ...)
      end
      -- ]

      -- DECODE ARGS [
      local function decode_args_real(str, max_args, ...)
        local args, err = decode_args(str, max_args or MAX_DECODE_ARGS or DEFAULT_MAX_DECODE_ARGS, ...)
        if err == "truncated" then
          kong.log.notice("decode args truncated")
        end
        return args, err
      end

      _G.ngx.decode_args = function(str, max_args, ...)
        -- Currently the kong.configuration.lua_max_uri_args is used for this too.
        MAX_DECODE_ARGS = kong and kong.configuration and kong.configuration.lua_max_uri_args or DEFAULT_MAX_DECODE_ARGS
        _G.ngx.decode_args = decode_args_real
        return decode_args_real(str, max_args or MAX_DECODE_ARGS, ...)
      end
      -- ]

      -- READ REQUEST BODY [
      _G.ngx.req.read_body = function()
        -- for the same request, only one `read_body` call is needed
        if not ngx.ctx.body_read then
          read_req_body()
          ngx.ctx.body_read = true
        end
      end
    end
  end


  do  -- implement a Lua based shm for: cli

    if options.cli and not options.rbusted then
      -- ngx.shared.DICT proxy
      -- https://github.com/bsm/fakengx/blob/master/fakengx.lua
      -- with minor fixes and additions such as exptime
      --
      -- See https://github.com/openresty/resty-cli/pull/12
      -- for a definitive solution of using shms in CLI
      local SharedDict = {}
      local function set(data, key, value, expire_at, flags)
        data[key] = {
          value = value,
          info = {expire_at = expire_at, flags=flags}
        }
        return data[key]
      end
      local function is_stale(item)
        return item.info.expire_at and item.info.expire_at <= ngx.now()
      end
      local function get(data, key)
        local item = data[key]
        if item and is_stale(item) then
          item = nil
        end
        return item
      end
      function SharedDict:new()
        return setmetatable({data = {}}, {__index = self})
      end
      function SharedDict:capacity()
        return 0
      end
      function SharedDict:free_space()
        return 0
      end
      function SharedDict:get(key)
        local item = get(self.data, key)
        if item then
          return item.value, item.info.flags
        end
        return nil
      end
      function SharedDict:get_stale(key)
        local item = self.data[key]
        if item then
          return item.value, item.info.flags, is_stale(item)
        end
        return nil
      end
      function SharedDict:set(key, value, exptime)
        local expire_at = (exptime and exptime ~= 0) and (ngx.now() + exptime)
        set(self.data, key, value, expire_at)
        return true, nil, false
      end
      SharedDict.safe_set = SharedDict.set
      function SharedDict:add(key, value, exptime)
        if get(self.data, key) then
          return false, "exists", false
        end

        return self:set(key, value, exptime)
      end
      SharedDict.safe_add = SharedDict.add
      function SharedDict:replace(key, value)
        if not get(key) then
          return false, "not found", false
        end
        set(self.data, key, value)
        return true, nil, false
      end
      function SharedDict:delete(key)
        if self.data[key] ~= nil then
          self.data[key] = nil
        end
        return true
      end
      function SharedDict:incr(key, value, init, init_ttl)
        local item = get(self.data, key)
        if not item then
          if not init then
            return nil, "not found"
          end
          item = set(self.data, key, init, init_ttl and ngx.now() + init_ttl)
        elseif type(item.value) ~= "number" then
          return nil, "not a number"
        end
        item.value = item.value + value
        return item.value, nil
      end
      function SharedDict:flush_all()
        for _, item in pairs(self.data) do
          item.info.expire_at = ngx.now()
        end
      end
      function SharedDict:flush_expired(n)
        local data = self.data
        local flushed = 0

        for key, item in pairs(self.data) do
          if is_stale(item) then
            data[key] = nil
            flushed = flushed + 1
            if n and flushed == n then
              break
            end
          end
        end
        self.data = data
        return flushed
      end
      function SharedDict:get_keys(n)
        n = n or 1024
        local i = 0
        local keys = {}
        for k, item in pairs(self.data) do
          if not is_stale(item) then
            keys[#keys+1] = k
            i = i + 1
            if n ~= 0 and i == n then
              break
            end
          end
        end
        return keys
      end
      function SharedDict:ttl(key)
        local item = self.data[key]
        if item == nil then
          return nil, "not found"
        end
        local expire_at = item.info.expire_at
        if expire_at == nil then
          return 0
        end
        -- There is a problem that also exists in the official OpenResty:
        -- 0 means the key never expires. So it's hard to distinguish between a
        -- never-expired key and an expired key with a TTL value of 0.
        return expire_at - ngx.now()
      end

      -- hack
      _G.ngx.shared = setmetatable({}, {
        __index = function(self, key)
          local shm = rawget(self, key)
          if not shm then
            shm = SharedDict:new()
            rawset(self, key, shm)
          end
          return shm
        end
      })
    end

  end



  do -- randomseeding patch for: cli, rbusted and OpenResty

    --- Seeds the random generator, use with care.
    -- Once - properly - seeded, this method is replaced with a stub
    -- one. This is to enforce best-practices for seeding in ngx_lua,
    -- and prevents third-party modules from overriding our correct seed
    -- (many modules make a wrong usage of `math.randomseed()` by calling
    -- it multiple times or by not using unique seeds for Nginx workers).
    --
    -- This patched method will create a unique seed per worker process,
    -- using a combination of both time and the worker's pid.
    local get_rand_bytes = require("kong.tools.rand").get_rand_bytes
    local seeded = {}
    local randomseed = math.randomseed

    if options.rbusted then
      _G.math.native_randomseed = randomseed
    end

    _G.math.randomseed = function()
      local pid = ngx.worker.pid()
      local id
      local is_seeded
      local phase = ngx.get_phase()
      if phase == "init" then
        id = "master"
        is_seeded = seeded.master

      else
        id = ngx.worker.id() or -1
        is_seeded = seeded[pid]
      end


      if is_seeded then
        ngx.log(ngx.DEBUG, debug.traceback("attempt to seed already seeded random number " ..
                                           "generator on process #" .. tostring(pid), 2))
        return
      end

      if not options.cli and (phase ~= "init_worker" and phase ~= "init") then
        ngx.log(ngx.WARN, debug.traceback("math.randomseed() must be called in " ..
                                          "init or init_worker context", 2))
      end

      local seed
      local bytes, err = get_rand_bytes(8)
      if bytes then
        ngx.log(ngx.DEBUG, "seeding PRNG from OpenSSL RAND_bytes()")

        local t = {}
        for i = 1, #bytes do
          local byte = string.byte(bytes, i)
          t[#t+1] = byte
        end

        local str = table.concat(t)
        if #str > 12 then
          -- truncate the final number to prevent integer overflow,
          -- since math.randomseed() could get cast to a platform-specific
          -- integer with a different size and get truncated, hence, lose
          -- randomness.
          -- double-precision floating point should be able to represent numbers
          -- without rounding with up to 15/16 digits but let's use 12 of them.
          str = string.sub(str, 1, 12)
        end

        seed = tonumber(str)

      else
        ngx.log(ngx.ERR, "could not seed from OpenSSL RAND_bytes, seeding ",
                         "PRNG with time and process id instead (this can ",
                         "result to duplicated seeds): ", err)

        seed = ngx.now() * 1000 + pid
      end

      if not options.cli then
        local kong_shm = ngx.shared.kong
        if id == "master" then
          local worker_count = ngx.worker.count()
          local old_worker_count = kong_shm:get("worker:count")
          if old_worker_count and old_worker_count > worker_count then
            for i = worker_count, old_worker_count - 1 do
              local old_worker_pid = kong_shm:get("pids:" .. i)
              if old_worker_pid then
                seeded[old_worker_pid] = nil
                kong_shm:delete("pids:" .. i)
                kong_shm:delete("kong:mem:" .. old_worker_pid)
              end
            end
          end

          if old_worker_count ~= worker_count then
            local ok, err = kong_shm:safe_set("worker:count", worker_count)
            if not ok then
              ngx.log(ngx.WARN, "could not store worker count in kong shm: ", err)
            end
          end

          seeded.master = true

        else
          local old_worker_pid = kong_shm:get("pids:" .. id)
          if old_worker_pid then
            seeded[old_worker_pid] = nil
            kong_shm:delete("kong:mem:" .. old_worker_pid)
          end

          local ok, err = kong_shm:safe_set("pids:" .. id, pid)
          if not ok then
            ngx.log(ngx.WARN, "could not store process id in kong shm: ", err)
          end

          seeded[pid] = true
        end
      end

      return randomseed(seed)
    end
  end

  do -- cosockets connect patch for dns resolution for: cli, rbusted and OpenResty
    local sub = string.sub

    local client = package.loaded["kong.resty.dns.client"]
    if not client then
      -- dns initialization here is essential for busted tests.
      client = require("kong.tools.dns")()
    end

    --- Patch the TCP connect and UDP setpeername methods such that all
    -- connections will be resolved first by the internal DNS resolver.
    -- STEP 1: load code that should not be using the patched versions
    require "resty.dns.resolver" -- will cache TCP and UDP functions

    -- STEP 2: forward declaration of locals to hold stuff loaded AFTER patching

    -- STEP 3: store original unpatched versions
    local old_tcp = ngx.socket.tcp
    local old_udp = ngx.socket.udp

    local old_tcp_connect
    local old_udp_setpeername

    local old_ngx_log = ngx.log

    -- need to do the extra check here: https://github.com/openresty/lua-nginx-module/issues/860
    local function strip_nils(first, second)
      if second then
        return first, second
      elseif first then
        return first
      end
    end

    local function resolve_connect(f, sock, host, port, opts)
      if sub(host, 1, 5) ~= "unix:" then
        local try_list
        host, port, try_list = client.toip(host, port)
        if not host then
          return nil, "[cosocket] DNS resolution failed: " .. tostring(port) ..
                      ". Tried: " .. tostring(try_list)
        end
      end

      return f(sock, host, strip_nils(port, opts))
    end

    local function tcp_resolve_connect(sock, host, port, opts)
      return resolve_connect(old_tcp_connect, sock, host, port, opts)
    end

    local function udp_resolve_setpeername(sock, host, port)
      return resolve_connect(old_udp_setpeername, sock, host, port)
    end

    -- STEP 4: patch globals
    _G.ngx.socket.tcp = function(...)
      local sock = old_tcp(...)

      if not old_tcp_connect then
        old_tcp_connect = sock.connect
      end

      sock.connect = tcp_resolve_connect

      return sock
    end

    _G.ngx.socket.udp = function(...)
      local sock = old_udp(...)

      if not old_udp_setpeername then
        old_udp_setpeername = sock.setpeername
      end

      sock.setpeername = udp_resolve_setpeername

      return sock
    end

    -- OTel-formatted logs feature
    local dynamic_hook = require "kong.dynamic_hook"
    local hook_called = false
    _G.ngx.log = function(...)
      if hook_called then
        -- detect recursive loops or yielding from the hook:
        old_ngx_log(ngx.ERR, debug.traceback("concurrent execution detected for: ngx.log", 2))
        return old_ngx_log(...)
      end

      -- stack level = 5:
      -- 1: maybe_push
      -- 2: dynamic_hook.pcall
      -- 3: dynamic_hook.run_hook
      -- 4: patched function
      -- 5: caller
      hook_called = true
      dynamic_hook.run_hook("observability_logs", "push", 5, nil, ...)
      hook_called = false
      return old_ngx_log(...)
    end
    -- export native ngx.log to be used where
    -- the patched code must not be executed
    _G.native_ngx_log = old_ngx_log

    if not options.cli and not options.rbusted then
      local timing = require "kong.timing"
      timing.register_hooks()
    end

    -- STEP 5: load code that should be using the patched versions, if any (because of dependency chain)
    do
      -- dns query patch
      local instrumentation = require "kong.observability.tracing.instrumentation"
      client.toip = instrumentation.get_wrapped_dns_query(client.toip)

      -- patch request_uri to record http_client spans
      instrumentation.http_client()
    end
  end

  require "kong.deprecation".init(options.cli)
end
