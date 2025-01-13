-- Use the new dns client library instead. If you want to switch to the original
-- one, you can set `new_dns_client = off` in kong.conf.
if ngx.shared.kong_dns_cache and _G.busted_new_dns_client ~= false then
  package.loaded["kong.dns.client"] = nil
  return require("kong.dns.client")
end

--------------------------------------------------------------------------
-- DNS client.
--
-- Works with OpenResty only. Requires the [`lua-resty-dns`](https://github.com/openresty/lua-resty-dns) module.
--
-- _NOTES_:
--
-- 1. parsing the config files upon initialization uses blocking i/o, so use with
-- care. See `init` for details.
-- 2. All returned records are directly from the cache. _So do not modify them!_
-- If you need to, copy them first.
-- 3. TTL for records is the TTL returned by the server at the time of fetching
-- and won't be updated while the client serves the records from its cache.
-- 4. resolving IPv4 (A-type) and IPv6 (AAAA-type) addresses is explicitly supported. If
-- the hostname to be resolved is a valid IP address, it will be cached with a ttl of
-- 10 years. So the user doesn't have to check for ip adresses.
--
-- @copyright 2016-2017 Kong Inc.
-- @author Thijs Schreijer
-- @license Apache 2.0

local _
local utils = require("kong.resty.dns.utils")
local fileexists = require("pl.path").exists
local semaphore = require("ngx.semaphore").new
local lrucache = require("resty.lrucache")
local resolver = require("resty.dns.resolver")
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy
local req_dyn_hook = require("kong.dynamic_hook")
local time = ngx.now
local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local ALERT = ngx.ALERT
local NOTICE = ngx.NOTICE
local DEBUG = ngx.DEBUG
--[[
  DEBUG = ngx.WARN
--]]
local PREFIX = "[dns-client] "
local timer_at = ngx.timer.at

local math_min = math.min
local math_max = math.max
local math_fmod = math.fmod
local math_random = math.random
local table_remove = table.remove
local table_concat = table.concat
local string_lower = string.lower
local string_byte  = string.byte

local req_dyn_hook_run_hook = req_dyn_hook.run_hook


local DOT   = string_byte(".")
local COLON = string_byte(":")
local DEFAULT_TIMEOUT = 2000 -- 2000 is openresty default


local EMPTY = require("kong.tools.table").EMPTY

-- resolver options
local config


local defined_hosts        -- hash table to lookup names originating from the hosts file
local emptyTtl             -- ttl (in seconds) for empty and 'name error' (3) errors
local badTtl               -- ttl (in seconds) for a other dns error results
local staleTtl             -- ttl (in seconds) to serve stale data (while new lookup is in progress)
local validTtl             -- ttl (in seconds) to use to override ttl of any valid answer
local cacheSize            -- size of the lru cache
local noSynchronisation
local orderValids = {"LAST", "SRV", "A", "AAAA", "CNAME"} -- default order to query
local typeOrder            -- array with order of types to try
local clientErrors = {     -- client specific errors
  [100] = "cache only lookup failed",
  [101] = "empty record received",
  [102] = "invalid name, bad IPv4",
  [103] = "invalid name, bad IPv6",
}

for _,v in ipairs(orderValids) do orderValids[v:upper()] = v end

-- create module table
local _M = {}
-- copy resty based constants for record types
for k,v in pairs(resolver) do
  if type(k) == "string" and k:sub(1,5) == "TYPE_" then
    _M[k] = v
  end
end
-- insert our own special value for "last success"
_M.TYPE_LAST = -1


-- ==============================================
--    Debugging aid
-- ==============================================
-- to be enabled manually by doing a replace-all on the
-- long comment start.
--[[
local json = require("cjson").encode

local function fquery(item)
  return (tostring(item):gsub("table: ", "query="))
end

local function frecord(record)
  if type(record) ~= "table" then
    return tostring(record)
  end
  return (tostring(record):gsub("table: ", "record=")) .. " " .. json(record)
end
--]]


-- ==============================================
--    In memory DNS cache
-- ==============================================

--- Caching.
-- The cache will not update the `ttl` field. So every time the same record
-- is served, the ttl will be the same. But the cache will insert extra fields
-- on the top-level; `touch` (timestamp of last access), `expire` (expiry time
-- based on `ttl`), and `expired` (boolean indicating it expired/is stale)
-- @section caching


-- hostname lru-cache indexed by "recordtype:hostname" returning address list.
-- short names are indexed by "recordtype:short:hostname"
-- Result is a list with entries.
-- Keys only by "hostname" only contain the last succesfull lookup type
-- for this name, see `resolve` function.
local dnscache

-- lookup a single entry in the cache.
-- @param qname name to lookup
-- @param qtype type number, any of the TYPE_xxx constants
-- @return cached record or nil
local cachelookup = function(qname, qtype)
  local now = time()
  local key = qtype..":"..qname
  local cached = dnscache:get(key)

  local ctx = ngx.ctx
  if ctx and ctx.has_timing then
    req_dyn_hook_run_hook("timing", "dns:cache_lookup", cached ~= nil)
  end

  if cached then
    cached.touch = now
    if (cached.expire < now) then
      cached.expired = true
      --[[
      log(DEBUG, PREFIX, "cache get (stale): ", key, " ", frecord(cached))
    else
      log(DEBUG, PREFIX, "cache get: ", key, " ", frecord(cached))
      --]]
    end
    --[[
  else
    log(DEBUG, PREFIX, "cache get (miss): ", key)
    --]]
  end

  return cached
end

-- inserts an entry in the cache.
-- @param entry the dns record list to store (may also be an error entry)
-- @param qname the name under which to store the record (optional for records, not for errors)
-- @param qtype the query type for which to store the record (optional for records, not for errors)
-- @return nothing
local cacheinsert = function(entry, qname, qtype)
  local key, lru_ttl
  local now = time()
  local e1 = entry[1]

  if not entry.expire then
    -- new record not seen before
    local ttl
    if e1 then
      -- an actual, non-empty, record
      key = (qtype or e1.type) .. ":" .. (qname or e1.name)

      ttl = validTtl or math.huge
      for i = 1, #entry do
        local record = entry[i]
        if validTtl then
          -- force configured ttl
          record.ttl = validTtl
        else
          -- determine minimum ttl of all answer records
          ttl = math_min(ttl, record.ttl)
        end
        -- update IPv6 address format to include square brackets
        if record.type == _M.TYPE_AAAA then
          record.address = utils.parseHostname(record.address)
        elseif record.type == _M.TYPE_SRV then -- SRV can also contain IPv6
          record.target = utils.parseHostname(record.target)
        end
      end

    elseif entry.errcode and entry.errcode ~= 3 then
      -- an error, but no 'name error' (3)
      if (cachelookup(qname, qtype) or EMPTY)[1] then
        -- we still have a stale record with data, so we're not replacing that
        --[[
        log(DEBUG, PREFIX, "cache set (skip on name error): ", key, " ", frecord(entry))
        --]]
        return
      end
      ttl = badTtl
      key = qtype..":"..qname

    elseif entry.errcode == 3 then
      -- a 'name error' (3)
      ttl = emptyTtl
      key = qtype..":"..qname

    else
      -- empty record
      if (cachelookup(qname, qtype) or EMPTY)[1] then
        -- we still have a stale record with data, so we're not replacing that
        --[[
        log(DEBUG, PREFIX, "cache set (skip on empty): ", key, " ", frecord(entry))
        --]]
        return
      end
      ttl = emptyTtl
      key = qtype..":"..qname
    end

    -- set expire time
    entry.touch = now
    entry.ttl = ttl
    entry.expire = now + ttl
    entry.expired = false
    lru_ttl = ttl + staleTtl
    --[[
    log(DEBUG, PREFIX, "cache set (new): ", key, " ", frecord(entry))
    --]]

  else
    -- an existing record reinserted (under a shortname for example)
    -- must calculate remaining ttl, cannot get it from lrucache
    key = (qtype or e1.type) .. ":" .. (qname or e1.name)
    lru_ttl = entry.expire - now + staleTtl
    --[[
    log(DEBUG, PREFIX, "cache set (existing): ", key, " ", frecord(entry))
    --]]
  end

  if lru_ttl <= 0 then
    -- item is already expired, so we do not add it
    dnscache:delete(key)
    --[[
    log(DEBUG, PREFIX, "cache set (delete on expired): ", key, " ", frecord(entry))
    --]]
    return
  end

  dnscache:set(key, entry, lru_ttl)
end

-- Lookup a shortname in the cache.
-- @param qname the name to lookup
-- @param qtype (optional) if not given a non-type specific query is done
-- @return same as cachelookup
local function cacheShortLookup(qname, qtype)
  return cachelookup("short:" .. qname, qtype or "none")
end

-- Inserts a shortname in the cache.
-- @param qname the name to lookup
-- @param qtype (optional) if not given a non-type specific insertion is done
-- @return nothing
local function cacheShortInsert(entry, qname, qtype)
  return cacheinsert(entry, "short:" .. qname, qtype or "none")
end

-- Lookup the last successful query type.
-- @param qname name to resolve
-- @return query/record type constant, or ˋnilˋ if not found
local function cachegetsuccess(qname)
  return dnscache:get(qname)
end

-- Sets the last successful query type.
-- Only if the type provided is in the list of types to try.
-- @param qname name resolved
-- @param qtype query/record type to set, or ˋnilˋ to clear
-- @return `true` if set, or `false` if not
local function cachesetsuccess(qname, qtype)

  -- Test whether the qtype value is in our search/order list
  local validType = false
  for _, t in ipairs(typeOrder) do
    if t == qtype then
      validType = true
      break
    end
  end
  if not validType then
    -- the qtype is not in the list, so we're not setting it as the
    -- success type
    --[[
    log(DEBUG, PREFIX, "cache set success (skip on bad type): ", qname, ", ", qtype)
    --]]
    return false
  end

  dnscache:set(qname, qtype)
  --[[
  log(DEBUG, PREFIX, "cache set success: ", qname, " = ", qtype)
  --]]
  return true
end


-- =====================================================
--    Try/status list for recursion checks and logging
-- =====================================================

local msg_mt = {
  __tostring = function(self)
    return table_concat(self, "/")
  end
}

local try_list_mt = {
  __tostring = function(self)
    local l, i = {}, 0
    for _, entry in ipairs(self) do
      l[i] = '","'
      l[i+1] = entry.qname
      l[i+2] = ":"
      l[i+3] = entry.qtype or "(na)"
      local m = tostring(entry.msg):gsub('"',"'")
      if m == "" then
        i = i + 4
      else
        l[i+4] = " - "
        l[i+5] = m
        i = i + 6
      end
    end
    -- concatenate result and encode as json array
    return '["' .. table_concat(l) .. '"]'
  end
}

-- adds a try to a list of tries.
-- The list keeps track of all queries tried so far. The array part lists the
-- order of attempts, whilst the `<qname>:<qtype>` key contains the index of that try.
-- @param self (optional) the list to add to, if omitted a new one will be created and returned
-- @param qname name being looked up
-- @param qtype query type being done
-- @param status (optional) message to be recorded
-- @return the list
local function try_add(self, qname, qtype, status)
  self = self or setmetatable({}, try_list_mt)
  local key = tostring(qname) .. ":" .. tostring(qtype)
  local idx = #self + 1
  self[idx] = {
    qname = qname,
    qtype = qtype,
    msg = setmetatable({ status }, msg_mt),
  }
  self[key] = idx
  return self
end

-- adds a status to the last try.
-- @param self the try_list to add to
-- @param status string with current status, added to the list for the current try
-- @return the try_list
local function add_status_to_try_list(self, status)
  local try_list = self[#self].msg
  try_list[#try_list + 1] = status
  return self
end


-- ==============================================
--    Main DNS functions for lookup
-- ==============================================

--- Resolving.
-- When resolving names, queries will be synchronized, such that only a single
-- query will be sent. If stale data is available, the request will return
-- stale data immediately, whilst continuing to resolve the name in the
-- background.
--
-- The `dnsCacheOnly` parameter found with `resolve` and `toip` can be used in
-- contexts where the co-socket api is unavailable. When the flag is set
-- only cached data is returned, but it will never use blocking io.
-- @section resolving


local resolve_max_wait

--- Initialize the client. Can be called multiple times. When called again it
-- will clear the cache.
-- @param options Same table as the [OpenResty dns resolver](https://github.com/openresty/lua-resty-dns),
-- with some extra fields explained in the example below.
-- @return `true` on success, `nil+error`, or throw an error on bad input
-- @usage -- config files to parse
-- -- `hosts` and `resolvConf` can both be a filename, or a table with file-contents
-- -- The contents of the `hosts` file will be inserted in the cache.
-- -- From `resolv.conf` the `nameserver`, `search`, `ndots`, `attempts` and `timeout` values will be used.
-- local hosts = {}  -- initialize without any blocking i/o
-- local resolvConf = {}  -- initialize without any blocking i/o
--
-- -- when getting nameservers from `resolv.conf`, get ipv6 servers?
-- local enable_ipv6 = false
--
-- -- Order in which to try different dns record types when resolving
-- -- 'last'; will try the last previously successful type for a hostname.
-- local order = { "last", "SRV", "A", "AAAA", "CNAME" }
--
-- -- Stale ttl for how long a stale record will be served from the cache
-- -- while a background lookup is in progress.
-- local staleTtl = 4.0    -- in seconds (can have fractions)
--
-- -- Cache ttl for empty and 'name error' (3) responses
-- local emptyTtl = 30.0   -- in seconds (can have fractions)
--
-- -- Cache ttl for other error responses
-- local badTtl = 1.0      -- in seconds (can have fractions)
--
-- -- Overriding ttl for valid queries, if given
-- local validTtl = nil    -- in seconds (can have fractions)
--
-- -- `ndots`, same as the `resolv.conf` option, if not given it is taken from
-- -- `resolv.conf` or otherwise set to 1
-- local ndots = 1
--
-- -- `no_random`, if set disables randomly picking the first nameserver, if not
-- -- given it is taken from `resolv.conf` option `rotate` (inverted).
-- -- Defaults to `true`.
-- local no_random = true
--
-- -- `search`, same as the `resolv.conf` option, if not given it is taken from
-- -- `resolv.conf`, or set to the `domain` option, or no search is performed
-- local search = {
--   "mydomain.com",
--   "site.domain.org",
-- }
--
-- -- Disables synchronization between queries, resulting in each lookup for the
-- -- same name being executed in it's own query to the nameservers. The default
-- -- (`false`) will synchronize multiple queries for the same name to a single
-- -- query to the nameserver.
-- noSynchronisation = false
--
-- assert(client.init({
--          hosts = hosts,
--          resolvConf = resolvConf,
--          ndots = ndots,
--          no_random = no_random,
--          search = search,
--          order = order,
--          badTtl = badTtl,
--          emptyTtl = emptTtl,
--          staleTtl = staleTtl,
--          validTtl = validTtl,
--          enable_ipv6 = enable_ipv6,
--          noSynchronisation = noSynchronisation,
--        })
-- )
_M.init = function(options)

  log(DEBUG, PREFIX, "(re)configuring dns client")
  local resolv, hosts, err
  options = options or {}

  staleTtl = options.staleTtl or 4
  log(DEBUG, PREFIX, "staleTtl = ", staleTtl)

  cacheSize = options.cacheSize or 10000  -- default set here to be able to reset the cache
  noSynchronisation = options.noSynchronisation
  log(DEBUG, PREFIX, "noSynchronisation = ", tostring(noSynchronisation))

  dnscache = lrucache.new(cacheSize)  -- clear cache on (re)initialization
  defined_hosts = {}  -- reset hosts hash table

  local order = options.order or orderValids
  typeOrder = {} -- clear existing upvalue
  local ip_preference
  for i,v in ipairs(order) do
    local t = v:upper()
    if not ip_preference and (t == "A" or t == "AAAA") then
      -- the first one up in the list is the IP type (v4 or v6) that we
      -- prefer
      ip_preference = t
    end
    assert(orderValids[t], "Invalid dns record type in order array; "..tostring(v))
    typeOrder[i] = _M["TYPE_"..t]
  end
  assert(#typeOrder > 0, "Invalid order list; cannot be empty")
  log(DEBUG, PREFIX, "query order = ", table_concat(order,", "))


  -- Deal with the `hosts` file

  local hostsfile = options.hosts or utils.DEFAULT_HOSTS

  if ((type(hostsfile) == "string") and (fileexists(hostsfile)) or
     (type(hostsfile) == "table")) then
    hosts, err = utils.parseHosts(hostsfile)  -- results will be all lowercase!
    if not hosts then return hosts, err end
  else
    log(WARN, PREFIX, "Hosts file not found: "..tostring(hostsfile))
    hosts = {}
  end

  -- treat `localhost` special, by always defining it, RFC 6761: Section 6.3.3
  if not hosts.localhost then
    hosts.localhost = {
      ipv4 = "127.0.0.1",
      ipv6 = "[::1]",
    }
  end

  -- Populate the DNS cache with the hosts (and aliasses) from the hosts file.
  local ttl = 10*365*24*60*60  -- use ttl of 10 years for hostfile entries
  for name, address in pairs(hosts) do
    name = string_lower(name)
    if address.ipv4 then
      cacheinsert({{  -- NOTE: nested list! cache is a list of lists
          name = name,
          address = address.ipv4,
          type = _M.TYPE_A,
          class = 1,
          ttl = ttl,
        }})
      defined_hosts[name..":".._M.TYPE_A] = true
      -- cache is empty so far, so no need to check for the ip_preference
      -- field here, just set ipv4 as success-type.
      cachesetsuccess(name, _M.TYPE_A)
      log(DEBUG, PREFIX, "adding A-record from 'hosts' file: ",name, " = ", address.ipv4)
    end
    if address.ipv6 then
      cacheinsert({{  -- NOTE: nested list! cache is a list of lists
          name = name,
          address = address.ipv6,
          type = _M.TYPE_AAAA,
          class = 1,
          ttl = ttl,
        }})
      defined_hosts[name..":".._M.TYPE_AAAA] = true
      -- do not overwrite the A success-type unless AAAA is preferred
      if ip_preference == "AAAA" or not cachegetsuccess(name) then
        cachesetsuccess(name, _M.TYPE_AAAA)
      end
      log(DEBUG, PREFIX, "adding AAAA-record from 'hosts' file: ",name, " = ", address.ipv6)
    end
  end

  -- see: https://github.com/Kong/kong/issues/7444
  -- since the validTtl affects ttl of caching entries,
  -- only set it after hosts entries are inserted
  -- so that the 10 years of TTL for hosts file actually takes effect.
  validTtl = options.validTtl
  log(DEBUG, PREFIX, "validTtl = ", tostring(validTtl))

  -- Deal with the `resolv.conf` file

  local resolvconffile = options.resolvConf or utils.DEFAULT_RESOLV_CONF

  if ((type(resolvconffile) == "string") and (fileexists(resolvconffile)) or
     (type(resolvconffile) == "table")) then
    resolv, err = utils.applyEnv(utils.parseResolvConf(resolvconffile))
    if not resolv then return resolv, err end
  else
    log(WARN, PREFIX, "Resolv.conf file not found: "..tostring(resolvconffile))
    resolv = {}
  end
  if not resolv.options then resolv.options = {} end

  if #(options.nameservers or {}) == 0 and resolv.nameserver then
    options.nameservers = {}
    -- some systems support port numbers in nameserver entries, so must parse those
    for _, address in ipairs(resolv.nameserver) do
      local ip, port, t = utils.parseHostname(address)
      if t == "ipv6" and not options.enable_ipv6 then
        -- should not add this one
        log(DEBUG, PREFIX, "skipping IPv6 nameserver ", port and (ip..":"..port) or ip)
      elseif t == "ipv6" and ip:find([[%]], nil, true) then
        -- ipv6 with a scope
        log(DEBUG, PREFIX, "skipping IPv6 nameserver (scope not supported) ", port and (ip..":"..port) or ip)
      else
        if port then
          options.nameservers[#options.nameservers + 1] = { ip, port }
        else
          options.nameservers[#options.nameservers + 1] = ip
        end
      end
    end
  end
  options.nameservers = options.nameservers or {}
  if #options.nameservers == 0 then
    log(WARN, PREFIX, "Invalid configuration, no valid nameservers found")
  else
    for _, r in ipairs(options.nameservers) do
      log(DEBUG, PREFIX, "nameserver ", type(r) == "table" and (r[1]..":"..r[2]) or r)
    end
  end

  options.retrans = options.retrans or resolv.options.attempts or 5 -- 5 is openresty default
  log(DEBUG, PREFIX, "attempts = ", options.retrans)

  if options.no_random == nil then
    options.no_random = not resolv.options.rotate
  else
    options.no_random = not not options.no_random -- force to boolean
  end
  log(DEBUG, PREFIX, "no_random = ", options.no_random)

  if not options.timeout then
    if resolv.options.timeout then
      options.timeout = resolv.options.timeout * 1000
    else
      options.timeout = DEFAULT_TIMEOUT
    end
  end
  if options.timeout > 0 then
    log(DEBUG, PREFIX, "timeout = ", options.timeout, " ms")
  else
    log(NOTICE, PREFIX, "timeout = ", DEFAULT_TIMEOUT, " ms (a non-positive timeout of ", options.timeout, " configured - using default timeout)")
    options.timeout = DEFAULT_TIMEOUT
  end

  -- setup the search order
  options.ndots = options.ndots or resolv.options.ndots or 1
  log(DEBUG, PREFIX, "ndots = ", options.ndots)
  options.search = options.search or resolv.search or { resolv.domain }
  log(DEBUG, PREFIX, "search = ", table_concat(options.search,", "))

  -- check if there is special domain like "."
  for i = #options.search, 1, -1 do
    if options.search[i] == "." then
      table_remove(options.search, i)
    end
  end

  -- other options

  badTtl = options.badTtl or 1
  log(DEBUG, PREFIX, "badTtl = ", badTtl, " s")
  emptyTtl = options.emptyTtl or 30
  log(DEBUG, PREFIX, "emptyTtl = ", emptyTtl, " s")

  -- options.no_recurse = -- not touching this one for now

  config = options -- store it in our module level global

  -- maximum time to wait for the dns resolver to hit its timeouts
  -- + 1s to ensure some delay in timer execution and semaphore return are accounted for
  resolve_max_wait = options.timeout / 1000 * options.retrans + 1

  return true
end


-- Removes records with non-matching types, updates the cache.
-- Parameter `answers` is updated in-place.
-- @return `true`
local function parseAnswer(qname, qtype, answers, try_list)

  -- check the answers and store records with matching types in the cache
  -- eg. A, AAAA, SRV records may be accompanied by CNAME records

  -- remove last '.' from FQDNs as the answer does not contain it
  local check_qname do
    if string_byte(qname, -1) == DOT then
      check_qname = qname:sub(1, -2) -- FQDN, drop the last dot
    else
      check_qname = qname
    end
  end

  for i = #answers, 1, -1 do -- we're deleting entries, so reverse the traversal
    local answer = answers[i]

    -- normalize casing
    answer.name = string_lower(answer.name)

    if answer.type ~= qtype then
      table_remove(answers, i)  -- remove records with non-matching types
    else
      answer.name = check_qname
    end
  end

  -- now insert actual target record in cache
  cacheinsert(answers, qname, qtype)
  return true
end


-- executes 1 individual query.
-- This query will not be synchronized, every call will be 1 query.
-- @param qname the name to query for
-- @param r_opts a table with the query options
-- @param try_list the try_list object to add to
-- @return `result + nil + try_list`, or `nil + err + try_list` in case of errors
local function individualQuery(qname, r_opts, try_list)
  local r, err = resolver:new(config)
  if not r then
    return r, "failed to create a resolver: " .. err, try_list
  end

  add_status_to_try_list(try_list, "querying")

  local result
  result, err = r:query(qname, r_opts)
  -- Manually destroy the resolver.
  -- When resovler is initialized, some socket resources are also created inside
  -- resolver. As the resolver is created in timer-ng, the socket resources are
  -- not released automatically, we have to destroy the resolver manually.
  -- resolver:destroy is patched in build phase, more information can be found in
  -- build/openresty/patches/lua-resty-dns-0.22_01-destroy_resolver.patch
  r:destroy()
  if not result then
    return result, err, try_list
  end

  parseAnswer(qname, r_opts.qtype, result, try_list)

  return result, nil, try_list
end

local queue = setmetatable({}, {__mode = "v"})

local function enqueue_query(key, qname, r_opts, try_list)
  local item = {
    key = key,
    semaphore = semaphore(),
    qname = qname,
    r_opts = cycle_aware_deep_copy(r_opts),
    try_list = try_list,
    expire_time = time() + resolve_max_wait,
  }
  queue[key] = item
  return item
end


local function dequeue_query(item)
  if queue[item.key] == item then
    -- query done, but by now many others might be waiting for our result.
    -- 1) stop new ones from adding to our lock/semaphore
    queue[item.key] = nil
    -- 2) release all waiting threads
    item.semaphore:post(math_max(item.semaphore:count() * -1, 1))
    item.semaphore = nil
  end
end


local function queue_get_query(key, try_list)
  local item = queue[key]

  if not item then
    return nil
  end

  -- bug checks: release it actively if the waiting query queue is blocked
  if item.expire_time < time() then
    local err = "stale query, key:" ..  key
    add_status_to_try_list(try_list, err)
    log(ALERT, PREFIX, err)
    dequeue_query(item)
    return nil
  end

  return item
end


-- to be called as a timer-callback, performs a query and returns the results
-- in the `item` table.
local function executeQuery(premature, item)
  if premature then return end

  item.result, item.err = individualQuery(item.qname, item.r_opts, item.try_list)

  dequeue_query(item)
end


-- schedules an async query.
-- This will be synchronized, so multiple calls (sync or async) might result in 1 query.
-- @param qname the name to query for
-- @param r_opts a table with the query options
-- @param try_list the try_list object to add to
-- @return `item` table which will receive the `result` and/or `err` fields, and a
-- `semaphore` field that can be used to wait for completion (once complete
-- the `semaphore` field will be removed). Upon error it returns `nil+error`.
local function asyncQuery(qname, r_opts, try_list)
  local key = qname..":"..r_opts.qtype
  local item = queue_get_query(key, try_list)
  if item then
    --[[
    log(DEBUG, PREFIX, "Query async (exists): ", key, " ", fquery(item))
    --]]
    add_status_to_try_list(try_list, "in progress (async)")
    return item    -- already in progress, return existing query
  end

  item = enqueue_query(key, qname, r_opts, try_list)

  local ok, err = timer_at(0, executeQuery, item)
  if not ok then
    queue[key] = nil
    log(ERR, PREFIX, "Failed to create a timer: ", err)
    return nil, "asyncQuery failed to create timer: "..err
  end
  --[[
  log(DEBUG, PREFIX, "Query async (scheduled): ", key, " ", fquery(item))
  --]]
  add_status_to_try_list(try_list, "scheduled")

  return item
end


-- schedules a sync query.
-- This will be synchronized, so multiple calls (sync or async) might result in 1 query.
-- The maximum delay would be `options.timeout * options.retrans`.
-- @param qname the name to query for
-- @param r_opts a table with the query options
-- @param try_list the try_list object to add to
-- @return `result + nil + try_list`, or `nil + err + try_list` in case of errors
local function syncQuery(qname, r_opts, try_list)
  local key = qname..":"..r_opts.qtype

  local item = queue_get_query(key, try_list)

  -- If nothing is in progress, we start a new sync query
  if not item then
    item = enqueue_query(key, qname, r_opts, try_list)

    item.result, item.err = individualQuery(qname, item.r_opts, try_list)

    dequeue_query(item)

    return item.result, item.err, try_list
  end

  -- If the query is already in progress, we wait for it.

  add_status_to_try_list(try_list, "in progress (sync)")

  -- block and wait for the async query to complete
  local ok, err = item.semaphore:wait(resolve_max_wait)
  if ok and item.result then
    -- we were released, and have a query result from the
    -- other thread, so all is well, return it
    --[[
    log(DEBUG, PREFIX, "Query sync result: ", key, " ", fquery(item),
           " result: ", json({ result = item.result, err = item.err}))
    --]]
    return item.result, item.err, try_list
  end

  -- bug checks
  if not ok and not item.err then
    item.err = err  -- only first expired wait() reports error
    log(ALERT, PREFIX, "semaphore:wait(", resolve_max_wait, ") failed: ", err,
                       ", count: ", item.semaphore and item.semaphore:count(),
                       ", qname: ", qname)
  end

  err = err or item.err or "unknown"
  add_status_to_try_list(try_list, "error: "..err)

  -- don't block on the same thread again, so remove it from the queue
  if queue[key] == item then
    queue[key] = nil
  end

  -- there was an error, either a semaphore timeout, or a lookup error
  return nil, err
end

-- will lookup a name in the cache, or alternatively query the nameservers.
-- If nothing is in the cache, a synchronous query is performewd. If the cache
-- contains stale data, that stale data is returned while an asynchronous
-- lookup is started in the background.
-- @param qname the name to look for
-- @param r_opts a table with the query options
-- @param dnsCacheOnly if true, no active lookup is done when there is no (stale)
-- data. In that case an error is returned (as a dns server failure table).
-- @param try_list the try_list object to add to
-- @param force_no_sync force noSyncronisation
-- @return `entry + nil + try_list`, or `nil + err + try_list`
local function lookup(qname, r_opts, dnsCacheOnly, try_list, force_no_sync)
  local no_sync = noSynchronisation or force_no_sync or false
  local entry = cachelookup(qname, r_opts.qtype)
  if not entry then
    --not found in cache
    if dnsCacheOnly then
      -- we can't do a lookup, so return an error
      --[[
      log(DEBUG, PREFIX, "Lookup, cache only failure: ", qname, " = ", r_opts.qtype)
      --]]
      try_list = try_add(try_list, qname, r_opts.qtype, "cache only lookup failed")
      return {
        errcode = 100,
        errstr = clientErrors[100]
      }, nil, try_list
    end
    -- perform a sync lookup, as we have no stale data to fall back to
    try_list = try_add(try_list, qname, r_opts.qtype, "cache-miss")
    -- while kong is exiting, we cannot use timers and hence we run all our queries without synchronization
    if no_sync then
      return individualQuery(qname, r_opts, try_list)
    elseif ngx.worker and ngx.worker.exiting() then
      log(DEBUG, PREFIX, "DNS query not synchronized because the worker is shutting down")
      return individualQuery(qname, r_opts, try_list)
    end
    return syncQuery(qname, r_opts, try_list)
  end

  try_list = try_add(try_list, qname, r_opts.qtype, "cache-hit")
  if entry.expired then
    -- the cached record is stale but usable, so we do a refresh query in the background
    add_status_to_try_list(try_list, "stale")
    asyncQuery(qname, r_opts, try_list)
  end

  return entry, nil, try_list
end

-- checks the query to be a valid IPv6. Inserts it in the cache or inserts
-- an error if it is invalid
-- @param qname the IPv6 address to check
-- @param qtype query type performed, any of the `TYPE_xx` constants
-- @param try_list the try_list object to add to
-- @return record as cached, nil, try_list
local function check_ipv6(qname, qtype, try_list)
  try_list = try_add(try_list, qname, qtype, "IPv6")

  local record = cachelookup(qname, qtype)
  if record then
    add_status_to_try_list(try_list, "cached")
    return record, nil, try_list
  end

  local check = qname:match("^%[(.+)%]$")  -- grab contents of "[ ]"
  if not check then
    -- no square brackets found
    check = qname
  end

  if string_byte(check, 1)  == COLON then check = "0"..check end
  if string_byte(check, -1) == COLON then check = check.."0" end
  if check:find("::") then
    -- expand double colon
    local _, count = check:gsub(":","")
    local ins = ":"..string.rep("0:", 8 - count)
    check = check:gsub("::", ins, 1)  -- replace only 1 occurence!
  end
  if qtype == _M.TYPE_AAAA and
     check:match("^%x%x?%x?%x?:%x%x?%x?%x?:%x%x?%x?%x?:%x%x?%x?%x?:%x%x?%x?%x?:%x%x?%x?%x?:%x%x?%x?%x?:%x%x?%x?%x?$") then
    add_status_to_try_list(try_list, "validated")
    record = {{
      address = qname,
      type = _M.TYPE_AAAA,
      class = 1,
      name = qname,
      ttl = 10 * 365 * 24 * 60 * 60 -- TTL = 10 years
    }}
    cachesetsuccess(qname, _M.TYPE_AAAA)
  else
    -- not a valid IPv6 address, or a bad type (non ipv6)
    -- return a "server error"
    add_status_to_try_list(try_list, "bad IPv6")
    record = {
      errcode = 103,
      errstr = clientErrors[103],
    }
  end
  cacheinsert(record, qname, qtype)
  return record, nil, try_list
end

-- checks the query to be a valid IPv4. Inserts it in the cache or inserts
-- an error if it is invalid
-- @param qname the IPv4 address to check
-- @param qtype query type performed, any of the `TYPE_xx` constants
-- @param try_list the try_list object to add to
-- @return record as cached, nil, try_list
local function check_ipv4(qname, qtype, try_list)
  try_list = try_add(try_list, qname, qtype, "IPv4")

  local record = cachelookup(qname, qtype)
  if record then
    add_status_to_try_list(try_list, "cached")
    return record, nil, try_list
  end

  if qtype == _M.TYPE_A then
    add_status_to_try_list(try_list, "validated")
    record = {{
      address = qname,
      type = _M.TYPE_A,
      class = 1,
      name = qname,
      ttl = 10 * 365 * 24 * 60 * 60 -- TTL = 10 years
    }}
    cachesetsuccess(qname, _M.TYPE_A)
  else
    -- bad query type for this ipv4 address
    -- return a "server error"
    add_status_to_try_list(try_list, "bad IPv4")
    record = {
      errcode = 102,
      errstr = clientErrors[102],
    }
  end
  cacheinsert(record, qname, qtype)
  return record, nil, try_list
end


-- iterator that iterates over all names and types to look up based on the
-- provided name, the `typeOrder`, `hosts`, `ndots` and `search` settings
-- @param qname the name to look up
-- @param qtype (optional) the type to look for, if omitted it will try the
-- full `typeOrder` list
-- @return in order all the fully qualified names + types to look up
local function search_iter(qname, qtype)
  local _, dots = qname:gsub("%.", "")

  local type_list = qtype and { qtype } or typeOrder
  local type_start = 0
  local type_end = #type_list

  local i_type = type_start
  local search do
    if string_byte(qname, -1) == DOT then
      -- this is a FQDN, so no searches
      search = {}
    else
      search = config.search
    end
  end
  local i_search, search_start, search_end
  local type_done = {}
  local type_current

  return  function()
            while true do
              -- advance the type-loop
              -- we need a while loop to make sure we skip LAST if already done
              while (not type_current) or type_done[type_current] do
                i_type = i_type + 1        -- advance type-loop
                if i_type > type_end then
                  return                   -- we reached the end, done iterating
                end

                type_current = type_list[i_type]
                if type_current == _M.TYPE_LAST then
                  type_current = cachegetsuccess(qname)
                end

                if type_current then
                  -- configure the search-loop
                  if (dots < config.ndots) and (not defined_hosts[qname..":"..type_current]) then
                    search_start = 0
                    search_end = #search + 1  -- +1: bare qname at the end
                  else
                    search_start = -1         -- -1: bare qname as first entry
                    search_end = #search
                  end
                  i_search = search_start    -- reset the search-loop
                end
              end

              -- advance the search-loop
              i_search = i_search + 1
              if i_search <= search_end then
                -- got the next one, return full search name and type
                local domain = search[i_search]
                return domain and qname.."."..domain or qname, type_current
              end

              -- finished the search-loop for this type, move to next type
              type_done[type_current] = true   -- mark current type as done
            end
          end
end

--- Resolve a name.
-- If `r_opts.qtype` is given, then it will fetch that specific type only. If
-- `r_opts.qtype` is not provided, then it will try to resolve
-- the name using the record types, in the order as provided to `init`.
--
-- Note that unless explicitly requesting a CNAME record (by setting `r_opts.qtype`) this
-- function will dereference the CNAME records.
--
-- So requesting `my.domain.com` (assuming to be an AAAA record, and default `order`) will try to resolve
-- it (the first time) as;
--
-- - SRV,
-- - then A,
-- - then AAAA (success),
-- - then CNAME (after AAAA success, this will not be tried)
--
-- A second lookup will now try (assuming the cached entry expired);
--
-- - AAAA (as it was the last successful lookup),
-- - then SRV,
-- - then A,
-- - then CNAME.
--
-- The outer loop will be based on the `search` and `ndots` options. Within each of
-- those, the inner loop will be the query/record type.
-- @function resolve
-- @param qname Name to resolve
-- @param r_opts Options table, see remark about the `qtype` field above and
-- [OpenResty docs](https://github.com/openresty/lua-resty-dns) for more options.
-- @param dnsCacheOnly Only check the cache, won't do server lookups
-- @param try_list (optional) list of tries to add to
-- @param force_no_sync force noSynchronisation
-- @return `list of records + nil + try_list`, or `nil + err + try_list`.
local function resolve(qname, r_opts, dnsCacheOnly, try_list, force_no_sync)
  qname = string_lower(qname)
  local qtype = (r_opts or EMPTY).qtype
  local err, records

  local opts = {}
  if r_opts then
    for k,v in pairs(r_opts) do opts[k] = v end  -- copy the options table
  end

  -- avoid parsing ip addresses that do not match the qname
  opts.additional_section = nil

  -- first check for shortname in the cache
  -- we do this only to prevent iterating over the SEARCH directive and
  -- potentially requerying failed lookups in that process as the ttl for
  -- errors is relatively short (1 second default)
  records = cacheShortLookup(qname, qtype)
  if records then
    if try_list then
      -- check for recursion
      if try_list["(short)"..qname..":"..tostring(qtype)] then
        err = "recursion detected"
        add_status_to_try_list(try_list, err)
        return nil, err, try_list
      end
    end

    try_list = try_add(try_list, "(short)"..qname, qtype, "cache-hit")
    if records.expired then
      -- if the record is already stale/expired we have to traverse the
      -- iterator as that is required to start the async refresh queries
      try_list = add_status_to_try_list(try_list, "stale")

    else
      -- a valid non-stale record
      -- check for CNAME records, and dereferencing the CNAME
      if (records[1] or EMPTY).type == _M.TYPE_CNAME and qtype ~= _M.TYPE_CNAME then
        opts.qtype = nil
        add_status_to_try_list(try_list, "dereferencing CNAME")
        return resolve(records[1].cname, opts, dnsCacheOnly, try_list, force_no_sync)
      end

      -- return the shortname cache hit
      return records, nil, try_list
    end
  else
    try_list = try_add(try_list, "(short)"..qname, qtype, "cache-miss")
  end

  -- check for qname being an ip address
  local name_type = utils.hostnameType(qname)
  if name_type ~= "name" then
    if name_type == "ipv4" then
      -- if no qtype is given, we're supposed to search, so forcing TYPE_A is safe
      records, _, try_list = check_ipv4(qname, qtype or _M.TYPE_A, try_list)

    else
      -- it is 'ipv6'
      -- if no qtype is given, we're supposed to search, so forcing TYPE_AAAA is safe
      records, _, try_list = check_ipv6(qname, qtype or _M.TYPE_AAAA, try_list)
    end

    if records.errcode then
      -- the query type didn't match the ip address, or a bad ip address
      return nil,
             ("dns client error: %s %s"):format(records.errcode, records.errstr),
             try_list
    end
    -- valid ipv4 or ipv6
    return records, nil, try_list
  end

  -- go try a sequence of record types
  for try_name, try_type in search_iter(qname, qtype) do
    if try_list and try_list[try_name..":"..try_type] then
      -- recursion, been here before
      err = "recursion detected"
      break
    end

    -- go look it up
    opts.qtype = try_type
    records, err, try_list = lookup(try_name, opts, dnsCacheOnly, try_list, force_no_sync)
    if not records then
      -- An error has occurred, terminate the lookup process.  We don't want to try other record types because
      -- that would potentially cause us to respond with wrong answers (i.e. the contents of an A record if the
      -- query for the SRV record failed due to a network error).
      break
    end

    if records.errcode then
      -- dns error: fall through to the next entry in our search sequence
      err = ("dns server error: %s %s"):format(records.errcode, records.errstr)

    elseif #records == 0 then
      -- empty: fall through to the next entry in our search sequence
      err = ("dns client error: %s %s"):format(101, clientErrors[101])

    else
      -- we got some records, update the cache
      if not dnsCacheOnly then
        if not qtype then
          -- only set the last succes, if we're not searching for a specific type
          -- and we're not limited by a cache-only request
          cachesetsuccess(try_name, try_type) -- set last succesful type resolved
        end
      end

      if qtype ~= _M.TYPE_SRV and try_type == _M.TYPE_SRV then
        -- check for recursive records, but NOT when requesting SRV explicitly
        local cnt = 0
        for _, record in ipairs(records) do
          if record.target == try_name then
            -- recursive record, pointing to itself
            cnt = cnt + 1
          end
        end

        if cnt == #records then
          -- fully recursive SRV record, specific Kubernetes problem
          -- which generates a SRV record for each host, pointing to
          -- itself, hence causing a recursion loop.
          -- So we delete the record, set an error, so it falls through
          -- and retries other record types in the main loop here.
          records = nil
          err = "recursion detected"
        end
      end

      if records then
        -- cache it under its shortname
        if not dnsCacheOnly then
          cacheShortInsert(records, qname, qtype)
        end

        -- dereference CNAME
        if records[1].type == _M.TYPE_CNAME and qtype ~= _M.TYPE_CNAME then
          opts.qtype = nil
          add_status_to_try_list(try_list, "dereferencing CNAME")
          return resolve(records[1].cname, opts, dnsCacheOnly, try_list, force_no_sync)
        end

        return records, nil, try_list
      end
    end

    -- we had some error, record it in the status list
    add_status_to_try_list(try_list, err)
  end

  -- we failed, clear cache and return last error
  if not dnsCacheOnly then
    cachesetsuccess(qname, nil)
  end
  return nil, err, try_list
end


-- Create a metadata cache, using weak keys so it follows the dns record cache.
-- The cache will hold pointers and lists for (weighted) round-robin schemes
local metadataCache = setmetatable({}, { __mode = "k" })

-- returns the index of the record next up in the round-robin scheme.
local function roundRobin(rec)
  local md = metadataCache[rec]
  if not md then
    md = {}
    metadataCache[rec] = md
  end
  local cursor = md.lastCursor or 0 -- start with first entry, trust the dns server! no random pick
  if cursor == #rec then
    cursor = 1
  else
    cursor = cursor + 1
  end
  md.lastCursor = cursor
  return cursor
end

-- greatest common divisor of 2 integers.
-- @return greatest common divisor
local function gcd(m, n)
  while m ~= 0 do
    m, n = math_fmod(n, m), m
  end
  return n
end

-- greatest common divisor of a list of integers.
-- @return 2 values; greatest common divisor for the whole list and
-- the sum of all weights
local function gcdl(list)
  local m = list[1]
  local n = list[2]
  if not n then return 1, m end
  local t = m
  local i = 2
  repeat
    t = t + n
    m = gcd(m, n)
    i = i + 1
    n = list[i]
  until not n
  return m, t
end

-- reduce a list of weights to their smallest relative counterparts.
-- eg. 20, 5, 5 --> 4, 1, 1
-- @return 2 values; reduced list (index == original index) and
-- the sum of all the (reduced) weights
local function reducedWeights(list)
  local gcd, total = gcdl(list)
  local l = {}
  for i, val in  ipairs(list) do
    l[i] = val/gcd
  end
  return l, total/gcd
end

-- returns the index of the SRV entry next up in the weighted round-robin scheme.
local function roundRobinW(rec)
  local md = metadataCache[rec]
  if not md then
    md = {}
    metadataCache[rec] = md
  end

  -- determine priority; stick to current or lower priority
  local prioList = md.prioList -- list with indexes-to-entries having the lowest priority

  if not prioList then
    -- 1st time we're seeing this record, so go and
    -- find lowest priorities
    local topPriority = 999999
    local weightList -- weights for the entry
    local n = 0
    for i, r in ipairs(rec) do
      -- when weight == 0 then minimal possibility of hitting it
      -- should occur. Setting it to 1 will prevent the weight-reduction
      -- from succeeding, hence a longer RR list is created, with
      -- lower probability of the 0-one being hit.
      local weight = (r.weight ~= 0 and r.weight or 1)
      if r.priority == topPriority then
        n = n + 1
        prioList[n] = i
        weightList[n] = weight
      elseif r.priority < topPriority then
        n = 1
        topPriority = r.priority
        prioList = { i }
        weightList = { weight }
      end
    end
    md.prioList = prioList
    md.weightList = weightList
    return prioList[1]  -- start with first entry, trust the dns server!
  end

  local rrwList = md.rrwList
  local rrwPointer = md.rrwPointer

  if not rrwList then
    -- 2nd time we're seeing this record
    -- 1st time we trusted the dns server, now we do WRR by our selves, so
    -- must create a list based on the weights. We do this only when necessary
    -- for performance reasons, so only on 2nd or later calls. Especially for
    -- ttl=0 scenarios where there might only be 1 call ever.
    local weightList = reducedWeights(md.weightList)
    rrwList = {}
    local x = 0
    -- create a list of entries, where each entry is repeated based on its
    -- relative weight.
    for i, idx in ipairs(prioList) do
      for _ = 1, weightList[i] do
        x = x + 1
        rrwList[x] = idx
      end
    end
    md.rrwList = rrwList
    -- The list has 2 parts, lower-part is yet to be used, higher-part was
    -- already used. The `rrwPointer` points to the last entry of the lower-part.
    -- On the initial call we served the first record, so we must rotate
    -- that initial call to be up-to-date.
    rrwList[1], rrwList[x] = rrwList[x], rrwList[1]
    rrwPointer = x-1  -- we have 1 entry in the higher-part now
    if rrwPointer == 0 then rrwPointer = x end
  end

  -- all structures are in place, so we can just serve the next up record
  local idx = math_random(1, rrwPointer)
  local target = rrwList[idx]

  -- rotate to next
  rrwList[idx], rrwList[rrwPointer] = rrwList[rrwPointer], rrwList[idx]
  if rrwPointer == 1 then
    md.rrwPointer = #rrwList
  else
    md.rrwPointer = rrwPointer-1
  end

  return target
end

--- Resolves to an IP and port number.
-- Builds on top of `resolve`, but will also further dereference SRV type records.
--
-- When calling multiple times on cached records, it will apply load-balancing
-- based on a round-robin (RR) scheme. For SRV records this will be a _weighted_
-- round-robin (WRR) scheme (because of the weights it will be randomized). It will
-- apply the round-robin schemes on each level
-- individually.
--
-- __Example__;
--
-- SRV record for "my.domain.com", containing 2 entries (this is the 1st level);
--
--   - `target = 127.0.0.1, port = 80, weight = 10`
--   - `target = "other.domain.com", port = 8080, weight = 5`
--
-- A record for "other.domain.com", containing 2 entries (this is the 2nd level);
--
--   - `ip = 127.0.0.2`
--   - `ip = 127.0.0.3`
--
-- Now calling `local ip, port = toip("my.domain.com", 123)` in a row 6 times will result in;
--
--   - `127.0.0.1, 80`
--   - `127.0.0.2, 8080` (port from SRV, 1st IP from A record)
--   - `127.0.0.1, 80`   (completes WRR 1st level, 1st run)
--   - `127.0.0.3, 8080` (port from SRV, 2nd IP from A record, completes RR 2nd level)
--   - `127.0.0.1, 80`
--   - `127.0.0.1, 80`   (completes WRR 1st level, 2nd run, with different order as WRR is randomized)
--
-- __Debugging__:
--
-- This function both takes and returns a `try_list`. This is an internal object
-- representing the entire resolution history for a call. To prevent unnecessary
-- string concatenations on a hot code path, it is not logged in this module.
-- If you need to log it, just log `tostring(try_list)` from the caller code.
-- @function execute_toip
-- @param qname hostname to resolve
-- @param port (optional) default port number to return if none was found in
-- the lookup chain (only SRV records carry port information, SRV with `port=0` will be ignored)
-- @param dnsCacheOnly Only check the cache, won't do server lookups (will
-- not invalidate any ttl expired data and will hence possibly return expired data)
-- @param try_list (optional) list of tries to add to
-- @param force_no_sync force noSynchronisation = true for a single call
-- @return `ip address + port + try_list`, or in case of an error `nil + error + try_list`
local function execute_toip(qname, port, dnsCacheOnly, try_list, force_no_sync)
  local rec, err
  rec, err, try_list = resolve(qname, nil, dnsCacheOnly, try_list, force_no_sync)
  if err then
    return nil, err, try_list
  end

  if rec[1].type == _M.TYPE_SRV then
    local entry = rec[roundRobinW(rec)]
    -- our SRV entry might still contain a hostname, so recurse, with found port number
    local srvport = (entry.port ~= 0 and entry.port) or port -- discard port if it is 0
    add_status_to_try_list(try_list, "dereferencing SRV")
    return execute_toip(entry.target, srvport, dnsCacheOnly, try_list, force_no_sync)
  end

  -- must be A or AAAA
  return rec[roundRobin(rec)].address, port, try_list
end

-- @see execute_toip
local function toip(...)
  return execute_toip(...)
end


-- This function calls execute_toip() forcing it to always execute an individual
-- query for each resolve, ignoring the noSynchronisation option.
-- @see execute_toip
local function individual_toip(qname, port, dnsCacheOnly, try_list)
  return execute_toip(qname, port, dnsCacheOnly, try_list, true)
end


--- Socket functions
-- @section sockets

--- Implements tcp-connect method with dns resolution.
-- This builds on top of `toip`. If the name resolves to an SRV record,
-- the port returned by the DNS server will override the one provided.
--
-- __NOTE__: can also be used for other connect methods, eg. http/redis
-- clients, as long as the argument order is the same
-- @function connect
-- @param sock the tcp socket
-- @param host hostname to connect to
-- @param port port to connect to (will be overridden if `toip` returns a port)
-- @param opts the options table
-- @return `success`, or `nil + error`
local function connect(sock, host, port, sock_opts)
  local targetIp, targetPort, tryList = toip(host, port)

  if not targetIp then
    return nil, tostring(targetPort) .. ". Tried: " .. tostring(tryList)
  end

  return sock:connect(targetIp, targetPort, sock_opts)
end


--- Implements udp-setpeername method with dns resolution.
-- This builds on top of `toip`. If the name resolves to an SRV record,
-- the port returned by the DNS server will override the one provided.
-- @function setpeername
-- @param sock the udp socket
-- @param host hostname to connect to
-- @param port port to connect to (will be overridden if `toip` returns a port)
-- @return `success`, or `nil + error`
local function setpeername(sock, host, port)
  local targetIp, targetPort, tryList
  if host:sub(1,5) == "unix:" then
    targetIp = host  -- unix domain socket, nothing to resolve
  else
    targetIp, targetPort, tryList = toip(host, port)
    if not targetIp then
      return nil, tostring(targetPort) .. ". Tried: " .. tostring(tryList)
    end
  end
  return sock:connect(targetIp, targetPort)
end


-- export local functions
_M.resolve = resolve
_M.toip = toip
_M.individual_toip = individual_toip
_M.connect = connect
_M.setpeername = setpeername

-- export the locals in case we're testing
if package.loaded.busted then
  _M.getcache = function() return dnscache end
  _M._search_iter = search_iter -- export as different name!
end

return _M
