local resty_mlcache = require "kong.resty.mlcache"
local buffer = require "string.buffer"
local resty_counter = require "resty.counter"


local encode = buffer.encode
local type = type
local pairs = pairs
local error = error
local max = math.max
local ngx = ngx
local shared = ngx.shared
local ngx_log = ngx.log
local get_phase = ngx.get_phase



local ERR = ngx.ERR
local NOTICE = ngx.NOTICE
local DEBUG = ngx.DEBUG


local NO_TTL_FLAG = resty_mlcache.NO_TTL_FLAG


local CHANNEL_NAME = "mlcache"
local DEFAULT_COUNTER_SYNC_INTERVAL = 5
local DEFAULT_COUNTER_SHM_NAME = "kong"


--[[
Hypothesis
----------

Item size:        1024 bytes
Max memory limit: 500 MiBs

LRU size must be: (500 * 2^20) / 1024 = 512000
Floored: 500.000 items should be a good default
--]]
local LRU_SIZE = 5e5


local _init = {}


local function log(lvl, ...)
  return ngx_log(lvl, "[DB cache] ", ...)
end


local _M = {}
local mt = { __index = _M }


function _M.new(opts)
  opts = opts or {}

  -- opts validation

  if type(opts.shm_name) ~= "string" then
    error("opts.shm_name must be a string", 2)
  end

  if _init[opts.shm_name] then
    error("kong.cache (" .. opts.shm_name .. ") was already created", 2)
  end

  if not opts.cluster_events then
    error("opts.cluster_events is required", 2)
  end

  if not opts.worker_events then
    error("opts.worker_events is required", 2)
  end

  if opts.ttl and type(opts.ttl) ~= "number" then
    error("opts.ttl must be a number", 2)
  end

  if opts.neg_ttl and type(opts.neg_ttl) ~= "number" then
    error("opts.neg_ttl must be a number", 2)
  end

  if opts.cache_pages and opts.cache_pages ~= 1 and opts.cache_pages ~= 2 then
    error("opts.cache_pages must be 1 or 2", 2)
  end

  if opts.resty_lock_opts and type(opts.resty_lock_opts) ~= "table" then
    error("opts.resty_lock_opts must be a table", 2)
  end

  if opts.invalidation_channel and type(opts.invalidation_channel) ~= "string" then
    error("opts.invalidation_channel must be a string", 2)
  end

  if opts.stats_counter_shm_name and type(opts.stats_counter_shm_name) ~= "string" then
    error("opts.stats_counter_shm_name must be a string", 2)
  end

  if opts.stats_counter_sync_interval and type(opts.stats_counter_sync_interval) ~= "number" then
    error("opts.stats_counter_sync_interval must be a number", 2)
  end

  local shm_name = opts.shm_name
  if not shared[shm_name] then
    log(ERR, "shared dictionary ", shm_name, " not found")
  end

  local shm_miss_name = shm_name .. "_miss"
  if not shared[shm_miss_name] then
    log(ERR, "shared dictionary ", shm_miss_name, " not found")
  end

  local ttl = max(opts.ttl or 3600, 0)
  local neg_ttl = max(opts.neg_ttl or 300, 0)
  local worker_events = opts.worker_events
  local mlcache, err = resty_mlcache.new(shm_name, shm_name, {
    shm_miss         = shm_miss_name,
    shm_locks        = "kong_locks",
    shm_set_tries    = 3,
    lru_size         = opts.lru_size or LRU_SIZE,
    ttl              = ttl,
    neg_ttl          = neg_ttl,
    resurrect_ttl    = opts.resurrect_ttl or 30,
    resty_lock_opts  = opts.resty_lock_opts,
    ipc = {
      register_listeners = function(events)
        for _, event_t in pairs(events) do
          worker_events.register(function(data)
            event_t.handler(data)
          end, CHANNEL_NAME, event_t.channel)
        end
      end,
      broadcast = function(channel, data)
        local ok, err = worker_events.post(CHANNEL_NAME, channel, data)
        if not ok then
          log(ERR, "failed to post event '", CHANNEL_NAME, "', '",
                   channel, "': ", err)
        end
      end
    }
  })

  if not mlcache then
    return nil, "failed to instantiate mlcache: " .. err
  end

  local cluster_events = opts.cluster_events
  local invalidation_channel = opts.invalidation_channel
                               or ("invalidations_" .. shm_name)
  local self       = {
    cluster_events = cluster_events,
    mlcache        = mlcache,
    dict           = shared[shm_name],
    shm_name       = shm_name,
    ttl            = ttl,
    neg_ttl        = neg_ttl,
    invalidation_channel = invalidation_channel,
  }

  local ok, err = cluster_events:subscribe(self.invalidation_channel, function(key)
    log(DEBUG, self.shm_name .. " received invalidate event from cluster for key: '", key, "'")
    self:invalidate_local(key)
  end)
  if not ok then
    return nil, "failed to subscribe to invalidations cluster events " ..
                "channel: " .. err
  end

  local stats_counter do
    local function generate_counter_keys(shm, op, stat)
      return "cache_stat_cnt" .. ":" .. shm .. ":" .. op .. ":" .. stat
    end

    local stats_counter_shm_name = opts.stats_counter_shm_name or DEFAULT_COUNTER_SHM_NAME
    local stats_counter_sync_interval = opts.stats_counter_sync_interval or DEFAULT_COUNTER_SYNC_INTERVAL
    local err
    stats_counter, err = resty_counter.new(
      stats_counter_shm_name, stats_counter_sync_interval)
    if err then
      return nil, "failed to create stats counter instance: " .. err
    end

    self.stats_counter = stats_counter
    self._stats_counter_keys = {
      get = {
        errors = generate_counter_keys(shm_name, "get", "errors"),
        hit_lvl = {
          [1] = generate_counter_keys(shm_name, "get", "hits"),
          [2] = generate_counter_keys(shm_name, "get", "hits"),
          [3] = generate_counter_keys(shm_name, "get", "misses"),
          [4] = generate_counter_keys(shm_name, "get", "resurrects"),
          [-1] = generate_counter_keys(shm_name, "get", "negatives"),
        },
      }
    }
  end

  _init[shm_name] = true

  return setmetatable(self, mt)
end


function _M:get(key, opts, cb, ...)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  local v, err, hit_lvl = self.mlcache:get(key, opts, cb, ...)
  if err then
    self.stats_counter:incr(self._stats_counter_keys.get.errors, 1)
    return nil, "failed to get from node cache: " .. err
  end

  self.stats_counter:incr(self._stats_counter_keys.get.hit_lvl[hit_lvl], 1)
  return v, nil, hit_lvl
end


function _M:renew(key, opts, cb, ...)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  local v, err, ttl = self.mlcache:renew(key, opts, cb, ...)
  if err then
    return nil, "failed to renew key in node cache: " .. err
  end

  return v, nil, ttl
end


function _M:get_bulk(bulk, opts)
  if type(bulk) ~= "table" then
    error("bulk must be a table", 2)
  end

  if opts ~= nil and type(opts) ~= "table" then
    error("opts must be a table", 2)
  end

  local res, err = self.mlcache:get_bulk(bulk, opts)
  if err then
    return nil, "failed to get_bulk from node cache: " .. err
  end

  return res
end


function _M:safe_set(key, value)
  local marshalled, err = encode(value)
  if err then
    return nil, err
  end

  return self.dict:safe_set(self.shm_name .. key, marshalled, self.ttl, self.ttl == 0 and NO_TTL_FLAG or 0)
end


function _M:probe(key)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  local ttl, err, v = self.mlcache:peek(key)
  if err then
    return nil, "failed to probe from node cache: " .. err
  end

  return ttl, nil, v
end


function _M:invalidate_local(key)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  log(DEBUG, self.shm_name, " invalidating (local): '", key, "'")

  local ok, err = self.mlcache:delete(key)
  if not ok then
    log(ERR, "failed to delete entity from node cache: ", err)
  end
end


function _M:invalidate(key)
  if type(key) ~= "string" then
    error("key must be a string", 2)
  end

  self:invalidate_local(key)

  log(DEBUG, "broadcasting (cluster) invalidation for key: '", key, "'")

  local ok, err = self.cluster_events:broadcast(self.invalidation_channel, key)
  if not ok then
    log(ERR, "failed to broadcast cached entity invalidation: ", err)
  end
end


function _M:purge()
  if get_phase() ~= "timer" then
    log(NOTICE, "purging (local) cache")
  end
  local ok, err = self.mlcache:purge(true)
  if not ok then
    log(ERR, "failed to purge cache: ", err)
  end
end


function _M:stats()
  self.stats_counter:sync()
  local res = {}
  for _, vals in pairs(self._stats_counter_keys) do
    if type(vals) == "string" then
      res[vals], _ = self.stats_counter:get(vals)

    else
      for _, counter_key in pairs(vals) do
        res[counter_key], _ = self.stats_counter:get(counter_key)
      end
    end
  end

  return res
end


return _M
