-- vim: ts=4 sts=4 sw=4 et:

local bit        = require "bit"
local new_tab    = require "table.new"
local lrucache   = require "resty.lrucache"
local resty_lock = require "resty.lock"
local tablepool  = require "tablepool"
local buffer     = require "string.buffer"


local bor          = bit.bor
local band         = bit.band
local lshift       = bit.lshift
local rshift       = bit.rshift
local min          = math.min
local ceil         = math.ceil
local fmt          = string.format
local type         = type
local pcall        = pcall
local xpcall       = xpcall
local traceback    = debug.traceback
local error        = error
local pairs        = pairs
local tostring     = tostring
local encode       = buffer.encode
local decode       = buffer.decode
local thread_spawn = ngx.thread.spawn
local thread_wait  = ngx.thread.wait
local setmetatable = setmetatable
local shared       = ngx.shared
local ngx_log      = ngx.log
local DEBUG        = ngx.DEBUG
local WARN         = ngx.WARN
local ERR          = ngx.ERR


local CACHE_MISS_SENTINEL_LRU = {}
local LOCK_KEY_PREFIX = "lua-resty-mlcache:lock:"
local LRU_INSTANCES = setmetatable({}, { __mode = "v" })
local SHM_SET_DEFAULT_TRIES = 3
local BULK_DEFAULT_CONCURRENCY = 3


local TYPES_SUPPORTED = {
    ["nil"] = true,
    number  = true,
    boolean = true,
    string  = true,
    table   = true,
}


-- The low bytes are used for flags,
-- e.g. high / low: 0xVersFlgs
local STALE_FLAG  = 0x00000001
local NO_TTL_FLAG = 0x00000002


local function set_flag(flags, flag)
    local low = band(flags, 0xffff)
    local high = band(rshift(flags, 16), 0xffff)
    return bor(bor(low, flag), lshift(high, 16))
end


local function has_flag(flags, flag)
    return band(band(flags, 0xffff), flag) ~= 0
end


local function get_version(flags)
    return band(rshift(flags, 16), 0xffff)
end


local function set_version(flags, version)
    local low = band(flags, 0xffff)
    return bor(low, lshift(version, 16))
end


local function rebuild_lru(self)
    if self.lru then
        self.lru:flush_all()
        return
    end

    -- Several mlcache instances can have the same name and hence, the same
    -- lru instance. We need to GC such LRU instance when all mlcache instances
    -- using them are GC'ed. We do this with a weak table.
    local lru = LRU_INSTANCES[self.name]
    if not lru then
        lru = lrucache.new(self.lru_size)
        LRU_INSTANCES[self.name] = lru
    end

    self.lru = lru
end


local _M     = {
    _VERSION = "2.6.0",
    _AUTHOR  = "Thibault Charbonnier",
    _LICENSE = "MIT",
    _URL     = "https://github.com/thibaultcha/lua-resty-mlcache",
}
local mt = { __index = _M }


function _M.new(name, shm, opts)
    if type(name) ~= "string" then
        error("name must be a string", 2)
    end

    if type(shm) ~= "string" then
        error("shm must be a string", 2)
    end

    if opts ~= nil then
        if type(opts) ~= "table" then
            error("opts must be a table", 2)
        end

        if opts.lru_size ~= nil and type(opts.lru_size) ~= "number" then
            error("opts.lru_size must be a number", 2)
        end

        if opts.ttl ~= nil then
            if type(opts.ttl) ~= "number" then
                error("opts.ttl must be a number", 2)
            end

            if opts.ttl < 0 then
                error("opts.ttl must be >= 0", 2)
            end
        end

        if opts.neg_ttl ~= nil then
            if type(opts.neg_ttl) ~= "number" then
                error("opts.neg_ttl must be a number", 2)
            end

            if opts.neg_ttl < 0 then
                error("opts.neg_ttl must be >= 0", 2)
            end
        end

        if opts.resurrect_ttl ~= nil then
            if type(opts.resurrect_ttl) ~= "number" then
                error("opts.resurrect_ttl must be a number", 2)
            end

            if opts.resurrect_ttl < 0 then
                error("opts.resurrect_ttl must be >= 0", 2)
            end
        end

        if opts.resty_lock_opts ~= nil
            and type(opts.resty_lock_opts) ~= "table"
        then
            error("opts.resty_lock_opts must be a table", 2)
        end

        if opts.ipc_shm ~= nil and type(opts.ipc_shm) ~= "string" then
            error("opts.ipc_shm must be a string", 2)
        end

        if opts.ipc ~= nil then
            if opts.ipc_shm then
                error("cannot specify both of opts.ipc_shm and opts.ipc", 2)
            end

            if type(opts.ipc) ~= "table" then
                error("opts.ipc must be a table", 2)
            end

            if type(opts.ipc.register_listeners) ~= "function" then
                error("opts.ipc.register_listeners must be a function", 2)
            end

            if type(opts.ipc.broadcast) ~= "function" then
                error("opts.ipc.broadcast must be a function", 2)
            end

            if opts.ipc.poll ~= nil and type(opts.ipc.poll) ~= "function" then
                error("opts.ipc.poll must be a function", 2)
            end
        end

        if opts.l1_serializer ~= nil
            and type(opts.l1_serializer) ~= "function"
        then
            error("opts.l1_serializer must be a function", 2)
        end

        if opts.shm_set_tries ~= nil then
            if type(opts.shm_set_tries) ~= "number" then
                error("opts.shm_set_tries must be a number", 2)
            end

            if opts.shm_set_tries < 1 then
                error("opts.shm_set_tries must be >= 1", 2)
            end
        end

        if opts.shm_miss ~= nil and type(opts.shm_miss) ~= "string" then
            error("opts.shm_miss must be a string", 2)
        end

        if opts.shm_locks ~= nil and type(opts.shm_locks) ~= "string" then
            error("opts.shm_locks must be a string", 2)
        end
    else
        opts = {}
    end

    local dict = shared[shm]
    if not dict then
        return nil, "no such lua_shared_dict: " .. shm
    end

    local dict_miss
    if opts.shm_miss then
        dict_miss = shared[opts.shm_miss]
        if not dict_miss then
            return nil, "no such lua_shared_dict for opts.shm_miss: "
                        .. opts.shm_miss
        end
    end

    if opts.shm_locks then
        local dict_locks = shared[opts.shm_locks]
        if not dict_locks then
            return nil, "no such lua_shared_dict for opts.shm_locks: "
                        .. opts.shm_locks
        end
    end

    local self          = {
        name            = name,
        dict            = dict,
        shm             = shm,
        dict_miss       = dict_miss,
        shm_miss        = opts.shm_miss,
        shm_locks       = opts.shm_locks or shm,
        ttl             = opts.ttl     or 30,
        neg_ttl         = opts.neg_ttl or 5,
        resurrect_ttl   = opts.resurrect_ttl,
        lru_size        = opts.lru_size or 100,
        resty_lock_opts = opts.resty_lock_opts,
        l1_serializer   = opts.l1_serializer,
        shm_set_tries   = opts.shm_set_tries or SHM_SET_DEFAULT_TRIES,
        debug           = opts.debug,
    }

    if opts.ipc_shm or opts.ipc then
        self.events = {
            ["invalidation"] = {
                channel = fmt("mlcache:invalidations:%s", name),
                handler = function(key)
                    self.lru:delete(key)
                end,
            },
            ["purge"] = {
                channel = fmt("mlcache:purge:%s", name),
                handler = function()
                    rebuild_lru(self)
                end,
            }
        }

        if opts.ipc_shm then
            local mlcache_ipc = require "kong.resty.mlcache.ipc"

            local ipc, err = mlcache_ipc.new(opts.ipc_shm, opts.debug)
            if not ipc then
                return nil, "failed to initialize mlcache IPC " ..
                            "(could not instantiate mlcache.ipc): " .. err
            end

            for _, ev in pairs(self.events) do
                ipc:subscribe(ev.channel, ev.handler)
            end

            self.broadcast = function(channel, data)
                return ipc:broadcast(channel, data)
            end

            self.poll = function(timeout)
                return ipc:poll(timeout)
            end

            self.ipc = ipc

        else
            -- opts.ipc
            local ok, err = opts.ipc.register_listeners(self.events)
            if not ok and err ~= nil then
                return nil, "failed to initialize custom IPC " ..
                            "(opts.ipc.register_listeners returned an error): "
                            .. err
            end

            self.broadcast = opts.ipc.broadcast
            self.poll = opts.ipc.poll

            self.ipc = true
        end
    end

    if opts.lru then
        self.lru = opts.lru

    else
        rebuild_lru(self)
    end

    return setmetatable(self, mt)
end


local function set_lru(self, key, value, ttl, neg_ttl, l1_serializer)
    if value == nil then
        ttl = neg_ttl
        value = CACHE_MISS_SENTINEL_LRU

    elseif l1_serializer then
        local ok, err
        ok, value, err = pcall(l1_serializer, value)
        if not ok then
            return nil, "l1_serializer threw an error: " .. value
        end

        if err then
            return nil, err
        end

        if value == nil then
            return nil, "l1_serializer returned a nil value"
        end
    end

    if ttl == 0 then
        -- indefinite ttl for lua-resty-lrucache is 'nil'
        ttl = nil
    end

    self.lru:set(key, value, ttl)

    return value
end


local function set_shm(self, shm_key, value, ttl, neg_ttl, flags, shm_set_tries,
                       throw_no_mem)
    local t = type(value)
    if not TYPES_SUPPORTED[t] then
        -- string buffer supports many types, but let's keep the original restrictions
        error("cannot cache value of type " .. t)
    end

    local shm_value, err = encode(value)
    if not shm_value then
        return nil, err
    end

    local shm = self.shm
    local dict = self.dict

    if value == nil then
        ttl = neg_ttl
        if self.dict_miss then
            shm = self.shm_miss
            dict = self.dict_miss
        end
    end

    -- we will call `set()` N times to work around potential shm fragmentation.
    -- when the shm is full, it will only evict about 30 to 90 items (via
    -- LRU), which could lead to a situation where `set()` still does not
    -- have enough memory to store the cached value, in which case we
    -- try again to try to trigger more LRU evictions.

    local tries = 0
    local ok, err

    if ttl == 0 then
        flags = set_flag(flags or 0, NO_TTL_FLAG)
    end

    while tries < shm_set_tries do
        tries = tries + 1
        ok, err = dict:set(shm_key, shm_value, ttl, flags or 0)
        if ok or err and err ~= "no memory" then
            break
        end
    end

    if not ok then
        if err ~= "no memory" or throw_no_mem then
            return nil, "could not write to lua_shared_dict '" .. shm
                        .. "': " .. err
        end

        ngx_log(WARN, "could not write to lua_shared_dict '",
                      shm, "' after ", tries, " tries (no memory), ",
                      "it is either fragmented or cannot allocate more ",
                      "memory, consider increasing 'opts.shm_set_tries'")
    end

    return true
end


local function del_shm(self, shm_key, value)
    local shm = self.shm
    local dict = self.dict

    if value == nil then
        if self.dict_miss then
            shm = self.shm_miss
            dict = self.dict_miss
        end
    end

    local ok, err = dict:delete(shm_key)

    if not ok then
        ngx_log(WARN, "could not delete from lua_shared_dict '" .. shm
                      .. "': " .. err)
        return
    end

    return true
end

local function set_shm_set_lru(self, key, shm_key, value, ttl, neg_ttl, flags,
                               shm_set_tries, l1_serializer, throw_no_mem)

    local ok, err = set_shm(self, shm_key, value, ttl, neg_ttl, flags,
                            shm_set_tries, throw_no_mem)
    if not ok then
        return nil, err
    end

    ok, err = set_lru(self, key, value, ttl, neg_ttl, l1_serializer)
    if not ok and err then
        -- l1_serializer returned nil + err, do not store the cached vaule in L2
        del_shm(self, shm_key, value)
    end

    return ok, err
end


local function get_shm_set_lru(self, key, shm_key, l1_serializer)
    local dict = self.dict
    local v, shmerr, went_stale = dict:get_stale(shm_key)
    if v == nil and shmerr then
        -- shmerr can be 'flags' upon successful get_stale() calls, so we
        -- also check v == nil
        return nil, "could not read from lua_shared_dict: " .. shmerr
    end

    if v == nil and self.dict_miss then
        dict = self.dict_miss
        -- if we cache misses in another shm, maybe it is there
        v, shmerr, went_stale = dict:get_stale(shm_key)
        if v == nil and shmerr then
            -- shmerr can be 'flags' upon successful get_stale() calls, so we
            -- also check v == nil
            return nil, "could not read from lua_shared_dict: " .. shmerr
        end
    end

    if v == nil then
        return
    end

    local value, err = decode(v)
    if err then
        return nil, "could not deserialize value after lua_shared_dict " ..
                    "retrieval: " .. err
    end

    if went_stale then
        return value, nil, went_stale
    end

    -- 'shmerr' is 'flags' on :get_stale() success
    local flags = shmerr or 0
    local is_stale = has_flag(flags, STALE_FLAG)

    local ttl
    if has_flag(flags, NO_TTL_FLAG) then
        ttl = 0

    else
        ttl = dict:ttl(shm_key)
        if not ttl or ttl <= 0 then
            return value, nil, nil, is_stale
        end
    end

    value, err = set_lru(self, key, value, ttl, ttl, l1_serializer)
    if err then
        return nil, err
    end

    return value, nil, nil, is_stale
end


local function check_opts(self, opts)
    local ttl
    local neg_ttl
    local resurrect_ttl
    local l1_serializer
    local shm_set_tries

    if opts ~= nil then
        if type(opts) ~= "table" then
            error("opts must be a table", 3)
        end

        ttl = opts.ttl
        if ttl ~= nil then
            if type(ttl) ~= "number" then
                error("opts.ttl must be a number", 3)
            end

            if ttl < 0 then
                error("opts.ttl must be >= 0", 3)
            end
        end

        neg_ttl = opts.neg_ttl
        if neg_ttl ~= nil then
            if type(neg_ttl) ~= "number" then
                error("opts.neg_ttl must be a number", 3)
            end

            if neg_ttl < 0 then
                error("opts.neg_ttl must be >= 0", 3)
            end
        end

        resurrect_ttl = opts.resurrect_ttl
        if resurrect_ttl ~= nil then
            if type(resurrect_ttl) ~= "number" then
                error("opts.resurrect_ttl must be a number", 3)
            end

            if resurrect_ttl < 0 then
                error("opts.resurrect_ttl must be >= 0", 3)
            end
        end

        l1_serializer = opts.l1_serializer
        if l1_serializer ~= nil and type(l1_serializer) ~= "function" then
           error("opts.l1_serializer must be a function", 3)
        end

        shm_set_tries = opts.shm_set_tries
        if shm_set_tries ~= nil then
            if type(shm_set_tries) ~= "number" then
                error("opts.shm_set_tries must be a number", 3)
            end

            if shm_set_tries < 1 then
                error("opts.shm_set_tries must be >= 1", 3)
            end
        end
    end

    if not ttl then
        ttl = self.ttl
    end

    if not neg_ttl then
        neg_ttl = self.neg_ttl
    end

    if not resurrect_ttl then
        resurrect_ttl = self.resurrect_ttl
    end

    if not l1_serializer then
        l1_serializer = self.l1_serializer
    end

    if not shm_set_tries then
        shm_set_tries = self.shm_set_tries
    end

    return ttl, neg_ttl, resurrect_ttl, l1_serializer, shm_set_tries
end


local function unlock_and_ret(lock, res, err, hit_lvl_or_ttl)
    local ok, lerr = lock:unlock()
    if not ok and lerr ~= "unlocked" then
        return nil, "could not unlock callback: " .. lerr
    end

    return res, err, hit_lvl_or_ttl
end


local function run_callback(self, key, shm_key, data, ttl, neg_ttl,
    went_stale, l1_serializer, resurrect_ttl, shm_set_tries, cb, ...)
    local lock, err = resty_lock:new(self.shm_locks, self.resty_lock_opts)
    if not lock then
        return nil, "could not create lock: " .. err
    end

    local elapsed, lerr = lock:lock(LOCK_KEY_PREFIX .. shm_key)
    if not elapsed and lerr ~= "timeout" then
        return nil, "could not acquire callback lock: " .. lerr
    end

    do
        -- check for another worker's success at running the callback, but
        -- do not return data if it is still the same stale value (this is
        -- possible if the value was still not evicted between the first
        -- get() and this one)

        local data2, err, went_stale2, stale2 = get_shm_set_lru(self, key,
                                                                shm_key,
                                                                l1_serializer,
                                                                ttl, neg_ttl)
        if err then
            return unlock_and_ret(lock, nil, err)
        end

        if data2 ~= nil and not went_stale2 then
            -- we got a fresh item from shm: other worker succeeded in running
            -- the callback
            if data2 == CACHE_MISS_SENTINEL_LRU then
                data2 = nil
            end

            return unlock_and_ret(lock, data2, nil, stale2 and 4 or 2)
        end
    end

    -- we are either the 1st worker to hold the lock, or
    -- a subsequent worker whose lock has timed out before the 1st one
    -- finished to run the callback

    if lerr == "timeout" then
        local errmsg = "could not acquire callback lock: timeout"

        -- no stale data nor desire to resurrect it
        if not went_stale or not resurrect_ttl then
            return nil, errmsg
        end

        -- do not resurrect the value here (another worker is running the
        -- callback and will either get the new value, or resurrect it for
        -- us if the callback fails)

        ngx_log(WARN, errmsg)

        -- went_stale is true, hence the value cannot be set in the LRU
        -- cache, and cannot be CACHE_MISS_SENTINEL_LRU

        return data, nil, 4
    end

    -- still not in shm, we are the 1st worker to hold the lock, and thus
    -- responsible for running the callback

    local pok, perr, err, new_ttl = xpcall(cb, traceback, ...)
    if not pok then
        return unlock_and_ret(lock, nil, "callback threw an error: " ..
                              tostring(perr))
    end

    if err then
        -- callback returned nil + err

        -- be resilient in case callbacks return wrong error type
        err = tostring(err)

        -- no stale data nor desire to resurrect it
        if not went_stale or not resurrect_ttl then
            return unlock_and_ret(lock, perr, err)
        end

        -- we got 'data' from the shm, even though it is stale
        --   1. log as warn that the callback returned an error
        --   2. resurrect: insert it back into shm if 'resurrect_ttl'
        --   3. signify the staleness with a high hit_lvl of '4'

        ngx_log(WARN, "callback returned an error (", err, ") but stale ",
                      "value found in shm will be resurrected for ",
                      resurrect_ttl, "s (resurrect_ttl)")

        local res_data, res_err = set_shm_set_lru(self, key, shm_key,
                                                  data, resurrect_ttl,
                                                  resurrect_ttl,
                                                  STALE_FLAG,
                                                  shm_set_tries, l1_serializer)
        if res_err then
            ngx_log(WARN, "could not resurrect stale data (", res_err, ")")
        end

        if res_data == CACHE_MISS_SENTINEL_LRU then
            res_data = nil
        end

        return unlock_and_ret(lock, res_data, nil, 4)
    end

    -- successful callback run returned 'data, nil, new_ttl?'

    data = perr

    -- override ttl / neg_ttl

    if type(new_ttl) == "number" then
        if new_ttl < 0 then
            -- bypass cache
            return unlock_and_ret(lock, data, nil, 3)
        end

        if data == nil then
            neg_ttl = new_ttl

        else
            ttl = new_ttl
        end
    end

    data, err = set_shm_set_lru(self, key, shm_key, data, ttl, neg_ttl, nil,
                                shm_set_tries, l1_serializer)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    if data == CACHE_MISS_SENTINEL_LRU then
        data = nil
    end

    -- unlock and return

    return unlock_and_ret(lock, data, nil, 3)
end


function _M:get(key, opts, cb, ...)
    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    if cb ~= nil and type(cb) ~= "function" then
        error("callback must be nil or a function", 2)
    end

    -- worker LRU cache retrieval

    local data = self.lru:get(key)
    if data == CACHE_MISS_SENTINEL_LRU then
        return nil, nil, 1
    end

    if data ~= nil then
        return data, nil, 1
    end

    -- not in worker's LRU cache, need shm lookup

    -- restrict this key to the current namespace, so we isolate this
    -- mlcache instance from potential other instances using the same
    -- shm
    local namespaced_key = self.name .. key

    -- opts validation

    local ttl, neg_ttl, resurrect_ttl, l1_serializer, shm_set_tries =
        check_opts(self, opts)

    local err, went_stale, is_stale
    data, err, went_stale, is_stale = get_shm_set_lru(self, key, namespaced_key,
                                                      l1_serializer)
    if err then
        return nil, err
    end

    if data ~= nil and not went_stale then
        if data == CACHE_MISS_SENTINEL_LRU then
            data = nil
        end

        return data, nil, is_stale and 4 or 2
    end

    -- not in shm either

    if cb == nil then
        -- no L3 callback, early exit
        return nil, nil, -1
    end

    -- L3 callback, single worker to run it

    return run_callback(self, key, namespaced_key, data, ttl, neg_ttl,
                        went_stale, l1_serializer, resurrect_ttl,
                        shm_set_tries, cb, ...)
end


function _M:renew(key, opts, cb, ...)
    if not self.broadcast then
        error("no ipc to propagate renew, specify opts.ipc_shm or opts.ipc", 2)
    end

    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    -- opts validation
    local ttl, neg_ttl, _, l1_serializer, shm_set_tries = check_opts(self, opts)

    if type(cb) ~= "function" then
        error("callback must be a function", 2)
    end

    -- restrict this key to the current namespace, so we isolate this
    -- mlcache instance from potential other instances using the same
    -- shm
    local namespaced_key = self.name .. key

    local v, shmerr = self.dict:get_stale(namespaced_key)
    if v == nil then
        if shmerr then
            -- shmerr can be 'flags' upon successful get_stale() calls, so we
            -- also check v == nil
            return nil, "could not read from lua_shared_dict: " .. shmerr
        end

        -- if we specified shm_miss, it might be a negative hit cached
        -- there
        if self.dict_miss then
            v, shmerr = self.dict_miss:get_stale(namespaced_key)
            if v == nil and shmerr then
                -- shmerr can be 'flags' upon successful get_stale() calls, so we
                -- also check v == nil
                return nil, "could not read from lua_shared_dict (miss): " .. shmerr
            end
        end
    end

    local version_before = get_version(shmerr or 0)

    local lock, lock_err = resty_lock:new(self.shm_locks, self.resty_lock_opts)
    if not lock then
        return nil, "could not create lock: " .. lock_err
    end

    local elapsed
    elapsed, lock_err = lock:lock(LOCK_KEY_PREFIX .. namespaced_key)
    if not elapsed and lock_err ~= "timeout"  then
        return nil, "could not acquire callback lock: " .. lock_err
    end

    local is_hit
    local is_miss

    v, shmerr = self.dict:get_stale(namespaced_key)
    if v ~= nil then
        is_hit = true

    else
        if shmerr then
            -- shmerr can be 'flags' upon successful get_stale() calls, so we
            -- also check v == nil
            if not lock_err then
                return unlock_and_ret(lock, nil,
                    "could not read from lua_shared_dict: " .. shmerr)
            end
            return nil, "could not acquire callback lock: " .. lock_err
        end

        -- if we specified shm_miss, it might be a negative hit cached
        -- there
        if self.dict_miss then
            v, shmerr = self.dict_miss:get_stale(namespaced_key)
            if v ~= nil then
                is_miss = true

            elseif shmerr then
                -- shmerr can be 'flags' upon successful get_stale() calls, so we
                -- also check v == nil
                if not lock_err then
                    return unlock_and_ret(lock, nil,
                        "could not read from lua_shared_dict (miss): " .. shmerr)
                end
                return nil, "could not acquire callback lock: " .. lock_err
            end
        end
    end

    local version_after
    if not shmerr then
        version_after = 0

    else
        version_after = get_version(shmerr or 0)
        if version_before ~= version_after then
            local ttl_left
            if is_miss then
                ttl_left = self.dict_miss:ttl(namespaced_key)
            else
                ttl_left = self.dict:ttl(namespaced_key)
            end

            if ttl_left then
                v = decode(v)
                if not lock_err then
                    return unlock_and_ret(lock, v, nil, ttl_left)
                end
                return v, nil, ttl_left
            end
        end
    end

    if lock_err == "timeout" then
        return nil, "could not acquire callback lock: timeout"
    end

    local ok, data, err, new_ttl = xpcall(cb, traceback, ...)
    if not ok then
        return unlock_and_ret(lock, nil, "callback threw an error: " .. tostring(data))
    end

    if err then
        return unlock_and_ret(lock, data, tostring(err))
    end

    if type(new_ttl) == "number" then
        if new_ttl < 0 then
            -- bypass cache
            return unlock_and_ret(lock, data, nil, new_ttl)
        end

        if data == nil then
            neg_ttl = new_ttl

        else
            ttl = new_ttl
        end
    end

    local version
    if data == nil then
        version = 0
    elseif version_after >= 65535 then
        version = 1
    else
        version = version_after + 1
    end

    local flags = set_version(0, version)

    data, err = set_shm_set_lru(self, key, namespaced_key, data, ttl, neg_ttl, flags,
                                shm_set_tries, l1_serializer)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    if data == CACHE_MISS_SENTINEL_LRU then
        data = nil
        if is_hit then
            ok, err = self.dict:delete(namespaced_key)
            if not ok then
                return unlock_and_ret(lock, nil, "could not delete from shm: " .. err)
            end
        end


    elseif is_miss then
        ok, err = self.dict_miss:delete(namespaced_key)
        if not ok then
            return unlock_and_ret(lock, nil, "could not delete from shm (miss): " .. err)
        end
    end

    _, err = self.broadcast(self.events.invalidation.channel, key)
    if err then
        return unlock_and_ret(lock, nil, "could not broadcast renew: " .. err)
    end

    -- unlock and return

    return unlock_and_ret(lock, data, nil, data == nil and neg_ttl or ttl)
end



do
local function run_thread(self, ops, from, to)
    for i = from, to do
        local ctx = ops[i]

        ctx.data, ctx.err, ctx.hit_lvl = run_callback(self, ctx.key,
                                                      ctx.shm_key, ctx.data,
                                                      ctx.ttl, ctx.neg_ttl,
                                                      ctx.went_stale,
                                                      ctx.l1_serializer,
                                                      ctx.resurrect_ttl,
                                                      ctx.shm_set_tries,
                                                      ctx.cb, ctx.arg)
    end
end


local bulk_mt = {}
bulk_mt.__index = bulk_mt


function _M.new_bulk(n_ops)
    local bulk = new_tab((n_ops or 2) * 4, 1) -- 4 slots per op
    bulk.n = 0

    return setmetatable(bulk, bulk_mt)
end


function bulk_mt:add(key, opts, cb, arg)
    local i = (self.n * 4) + 1
    self[i] = key
    self[i + 1] = opts
    self[i + 2] = cb
    self[i + 3] = arg
    self.n = self.n + 1
end


local function bulk_res_iter(res, i)
    local idx = i * 3 + 1
    if idx > res.n then
        return
    end

    i = i + 1

    local data = res[idx]
    local err = res[idx + 1]
    local hit_lvl = res[idx + 2]

    return i, data, err, hit_lvl
end


function _M.each_bulk_res(res)
    if not res.n then
        error("res must have res.n field; is this a get_bulk() result?", 2)
    end

    return bulk_res_iter, res, 0
end


function _M:get_bulk(bulk, opts)
    if type(bulk) ~= "table" then
        error("bulk must be a table", 2)
    end

    if not bulk.n then
        error("bulk must have n field", 2)
    end

    if opts then
        if type(opts) ~= "table" then
            error("opts must be a table", 2)
        end

        if opts.concurrency then
            if type(opts.concurrency) ~= "number" then
                error("opts.concurrency must be a number", 2)
            end

            if opts.concurrency <= 0 then
                error("opts.concurrency must be > 0", 2)
            end
        end
    end

    local n_bulk = bulk.n * 4
    local res = new_tab(n_bulk - n_bulk / 4, 1)
    local res_idx = 1

    -- only used if running L3 callbacks
    local n_cbs = 0
    local cb_ctxs

    -- bulk
    -- { "key", opts, cb, arg }
    --
    -- res
    -- { data, "err", hit_lvl }

    for i = 1, n_bulk, 4 do
        local b_key = bulk[i]
        local b_opts = bulk[i + 1]
        local b_cb = bulk[i + 2]

        if type(b_key) ~= "string" then
            error("key at index " .. i .. " must be a string for operation " ..
                  ceil(i / 4) .. " (got " .. type(b_key) .. ")", 2)
        end

        if type(b_cb) ~= "function" then
            error("callback at index " .. i + 2 .. " must be a function " ..
                  "for operation " .. ceil(i / 4) .. " (got " .. type(b_cb) ..
                  ")", 2)
        end

        -- worker LRU cache retrieval

        local data = self.lru:get(b_key)
        if data ~= nil then
            if data == CACHE_MISS_SENTINEL_LRU then
                data = nil
            end

            res[res_idx] = data
            --res[res_idx + 1] = nil
            res[res_idx + 2] = 1

        else
            local pok, ttl, neg_ttl, resurrect_ttl, l1_serializer, shm_set_tries
                = pcall(check_opts, self, b_opts)
            if not pok then
                -- strip the stacktrace
                local err = ttl:match("init%.lua:%d+:%s(.*)")
                error("options at index " .. i + 1 .. " for operation " ..
                      ceil(i / 4) .. " are invalid: " .. err, 2)
            end

            -- not in worker's LRU cache, need shm lookup
            -- we will prepare a task for each cache miss
            local namespaced_key = self.name .. b_key

            local err, went_stale, is_stale
            data, err, went_stale, is_stale = get_shm_set_lru(self, b_key,
                                                           namespaced_key,
                                                           l1_serializer)
            if err then
                --res[res_idx] = nil
                res[res_idx + 1] = err
                --res[res_idx + 2] = nil

            elseif data ~= nil and not went_stale then
                if data == CACHE_MISS_SENTINEL_LRU then
                    data = nil
                end

                res[res_idx] = data
                --res[res_idx + 1] = nil
                res[res_idx + 2] = is_stale and 4 or 2

            else
                -- not in shm either, we have to prepare a task to run the
                -- L3 callback

                n_cbs = n_cbs + 1

                if n_cbs == 1 then
                    cb_ctxs = tablepool.fetch("bulk_cb_ctxs", 1, 0)
                end

                local ctx = tablepool.fetch("bulk_cb_ctx", 0, 15)
                ctx.res_idx = res_idx
                ctx.cb = b_cb
                ctx.arg = bulk[i + 3] -- arg
                ctx.key = b_key
                ctx.shm_key = namespaced_key
                ctx.data = data
                ctx.ttl = ttl
                ctx.neg_ttl = neg_ttl
                ctx.went_stale = went_stale
                ctx.l1_serializer = l1_serializer
                ctx.resurrect_ttl = resurrect_ttl
                ctx.shm_set_tries = shm_set_tries
                ctx.data = data
                ctx.err = nil
                ctx.hit_lvl = nil

                cb_ctxs[n_cbs] = ctx
            end
        end

        res_idx = res_idx + 3
    end

    if n_cbs == 0 then
        -- no callback to run, all items were in L1/L2
        res.n = res_idx - 1
        return res
    end

    -- some L3 callbacks have to run
    -- schedule threads as per our concurrency settings
    -- we will use this thread as well

    local concurrency
    if opts then
        concurrency = opts.concurrency
    end

    if not concurrency then
        concurrency = BULK_DEFAULT_CONCURRENCY
    end

    local threads
    local threads_idx = 0

    do
        -- spawn concurrent threads
        local thread_size
        local n_threads = min(n_cbs, concurrency) - 1

        if n_threads >  0 then
            threads = tablepool.fetch("bulk_threads", n_threads, 0)
            thread_size = ceil(n_cbs / concurrency)
        end

        if self.debug then
            ngx_log(DEBUG, "spawning ", n_threads, " threads to run ", n_cbs, " callbacks")
        end

        local from = 1
        local rest = n_cbs

        for i = 1, n_threads do
            local to
            if rest >= thread_size then
                rest = rest - thread_size
                to = from + thread_size - 1
            else
                rest = 0
                to = from
            end

            if self.debug then
                ngx_log(DEBUG, "thread ", i, " running callbacks ", from, " to ", to)
            end

            threads_idx = threads_idx + 1
            threads[i] = thread_spawn(run_thread, self, cb_ctxs, from, to)

            from = from + thread_size

            if rest == 0 then
                break
            end
        end

        if rest > 0 then
            -- use this thread as one of our concurrent threads
            local to = from + rest - 1

            if self.debug then
                ngx_log(DEBUG, "main thread running callbacks ", from, " to ", to)
            end

            run_thread(self, cb_ctxs, from, to)
        end
    end

    -- wait for other threads

    for i = 1, threads_idx do
        local ok, err = thread_wait(threads[i])
        if not ok then
            -- when thread_wait() fails, we don't get res_idx, and thus
            -- cannot populate the appropriate res indexes with the
            -- error
            ngx_log(ERR, "failed to wait for thread number ", i, ": ", err)
        end
    end

    for i = 1, n_cbs do
        local ctx = cb_ctxs[i]
        local ctx_res_idx = ctx.res_idx

        res[ctx_res_idx] = ctx.data
        res[ctx_res_idx + 1] = ctx.err
        res[ctx_res_idx + 2] = ctx.hit_lvl

        tablepool.release("bulk_cb_ctx", ctx, true) -- no clear tab
    end

    tablepool.release("bulk_cb_ctxs", cb_ctxs)

    if threads then
        tablepool.release("bulk_threads", threads)
    end

    res.n = res_idx - 1

    return res
end


end -- get_bulk()


function _M:peek(key, stale)
    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    -- restrict this key to the current namespace, so we isolate this
    -- mlcache instance from potential other instances using the same
    -- shm
    local namespaced_key = self.name .. key

    local dict = self.dict
    local v, shmerr, went_stale = dict:get_stale(namespaced_key)
    if v == nil and shmerr then
        -- shmerr can be 'flags' upon successful get_stale() calls, so we
        -- also check v == nil
        return nil, "could not read from lua_shared_dict: " .. shmerr
    end

    -- if we specified shm_miss, it might be a negative hit cached
    -- there
    if v == nil and self.dict_miss then
        dict = self.dict_miss
        v, shmerr, went_stale = dict:get_stale(namespaced_key)
        if v == nil and shmerr then
            -- shmerr can be 'flags' upon successful get_stale() calls, so we
            -- also check v == nil
            return nil, "could not read from lua_shared_dict: " .. shmerr
        end
    end

    if v == nil or (went_stale and not stale) then
        return
    end

    local value, err = decode(v)
    if err then
        return nil, "could not deserialize value after lua_shared_dict " ..
                    "retrieval: " .. err
    end

    local flags = shmerr or 0
    local no_ttl = has_flag(flags, NO_TTL_FLAG)
    local ttl = dict:ttl(namespaced_key)
    return ttl, nil, value, went_stale, no_ttl
end


function _M:set(key, opts, value)
    if not self.broadcast then
        error("no ipc to propagate update, specify opts.ipc_shm or opts.ipc", 2)
    end

    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    do
        -- restrict this key to the current namespace, so we isolate this
        -- mlcache instance from potential other instances using the same
        -- shm
        local ttl, neg_ttl, _, l1_serializer, shm_set_tries = check_opts(self,
                                                                         opts)
        local namespaced_key = self.name .. key

        if self.dict_miss then
            -- since we specified a separate shm for negative caches, we
            -- must make sure that we clear any value that may have been
            -- set in the other shm
            local dict = value == nil and self.dict or self.dict_miss

            -- TODO: there is a potential race-condition here between this
            --       :delete() and the subsequent :set() in set_shm()
            local ok, err = dict:delete(namespaced_key)
            if not ok then
                return nil, "could not delete from shm: " .. err
            end
        end

        local _, err = set_shm_set_lru(self, key, namespaced_key, value, ttl,
                                       neg_ttl, nil, shm_set_tries,
                                       l1_serializer, true)
        if err then
            return nil, err
        end
    end

    local _, err = self.broadcast(self.events.invalidation.channel, key)
    if err then
        return nil, "could not broadcast update: " .. err
    end

    return true
end


function _M:delete(key)
    if not self.broadcast then
        error("no ipc to propagate deletion, specify opts.ipc_shm or opts.ipc",
              2)
    end

    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    -- delete from shm first
    do
        -- restrict this key to the current namespace, so we isolate this
        -- mlcache instance from potential other instances using the same
        -- shm
        local namespaced_key = self.name .. key

        local ok, err = self.dict:delete(namespaced_key)
        if not ok then
            return nil, "could not delete from shm: " .. err
        end

        -- instance uses shm_miss for negative caches, since we don't know
        -- where the cached value is (is it nil or not?), we must remove it
        -- from both
        if self.dict_miss then
            ok, err = self.dict_miss:delete(namespaced_key)
            if not ok then
                return nil, "could not delete from shm: " .. err
            end
        end
    end

    -- delete from LRU and propagate
    self.lru:delete(key)

    local _, err = self.broadcast(self.events.invalidation.channel, key)
    if err then
        return nil, "could not broadcast deletion: " .. err
    end

    return true
end


function _M:purge(flush_expired)
    if not self.broadcast then
        error("no ipc to propagate purge, specify opts.ipc_shm or opts.ipc", 2)
    end

    -- clear shm first
    self.dict:flush_all()

    -- clear negative caches shm if specified
    if self.dict_miss then
        self.dict_miss:flush_all()
    end

    if flush_expired then
        self.dict:flush_expired()

        if self.dict_miss then
            self.dict_miss:flush_expired()
        end
    end

    -- clear LRU content and propagate
    rebuild_lru(self)

    local _, err = self.broadcast(self.events.purge.channel, "")
    if err then
        return nil, "could not broadcast purge: " .. err
    end

    return true
end


function _M:update(timeout)
    if not self.poll then
        error("no polling configured, specify opts.ipc_shm or opts.ipc.poll", 2)
    end

    local _, err = self.poll(timeout)
    if err then
        return nil, "could not poll ipc events: " .. err
    end

    return true
end


_M.NO_TTL_FLAG = NO_TTL_FLAG


return _M
