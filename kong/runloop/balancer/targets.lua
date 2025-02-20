---
--- manages a cache of targets belonging to an upstream.
--- each one represents a hostname with a weight,
--- health status and a list of addresses.
---
--- maybe it could eventually be merged into the DAO object?
---

local dns_client = require "kong.resty.dns.client"
local upstreams = require "kong.runloop.balancer.upstreams"
local balancers = require "kong.runloop.balancer.balancers"
local dns_utils = require "kong.resty.dns.utils"

local ngx = ngx
local null = ngx.null
local ngx_now = ngx.now
local log = ngx.log
local string_format = string.format
local string_match  = string.match
local ipairs = ipairs
local tonumber = tonumber
local table_sort = table.sort
local assert = assert
local exiting = ngx.worker.exiting
local get_updated_now_ms = require("kong.tools.time").get_updated_now_ms

local CRIT = ngx.CRIT
local DEBUG = ngx.DEBUG
local ERR = ngx.ERR
local WARN = ngx.WARN

local SRV_0_WEIGHT = 1      -- SRV record with weight 0 should be hit minimally, hence we replace by 1
local EMPTY = require("kong.tools.table").EMPTY
local GLOBAL_QUERY_OPTS = { workspace = null, show_ws_id = true }

-- global binary heap for all balancers to share as a single update timer for
-- renewing DNS records
local renewal_heap = require("binaryheap").minUnique()
local renewal_weak_cache = setmetatable({}, { __mode = "v" })

local targets_by_upstream_id = {}

local targets_M = {}

-- forward local declarations
local resolve_timer_callback
local resolve_timer_running
local queryDns

function targets_M.init()
  dns_client = assert(package.loaded["kong.resty.dns.client"])
  if renewal_heap:size() > 0 then
    renewal_heap = require("binaryheap").minUnique()
    renewal_weak_cache = setmetatable({}, { __mode = "v" })    
  end


  if not resolve_timer_running then
    resolve_timer_running = assert(ngx.timer.at(1, resolve_timer_callback))
  end
end


local _rtype_to_name
function targets_M.get_dns_name_from_record_type(rtype)
  if not _rtype_to_name then
    _rtype_to_name = {}

    for k, v in pairs(dns_client) do
      if tostring(k):sub(1,5) == "TYPE_" then
        _rtype_to_name[v] = k:sub(6,-1)
      end
    end
  end

  return _rtype_to_name[rtype] or "unknown"
end

------------------------------------------------------------------------------
-- Loads the targets from the DB.
-- @param upstream_id Upstream uuid for which to load the target
-- @return The target array, with target entity tables.
local function load_targets_into_memory(upstream_id)

  local targets, err, err_t = kong.db.targets:select_by_upstream_raw(
      { id = upstream_id }, GLOBAL_QUERY_OPTS)

  if not targets then
    return nil, err, err_t
  end

  -- perform some raw data updates
  for _, target in ipairs(targets) do
    -- split `target` field into `name` and `port`
    local port
    target.name, port = string_match(target.target, "^(.-):(%d+)$")
    target.port = tonumber(port)
    target.addresses = {}
    target.totalWeight = 0
    target.unavailableWeight = 0
    target.nameType = dns_utils.hostnameType(target.name)
  end

  return targets
end
--_load_targets_into_memory = load_targets_into_memory


local function get_dns_renewal_key(target)
  if target and (target.balancer or target.upstream) then
    local id = (target.balancer and target.balancer.upstream_id) or (target.upstream and target.upstream.id)
    if target.target then
      return id .. ":" .. target.target
    elseif target.name and target.port then
      return id .. ":" .. target.name .. ":" .. target.port
    end

  end

  return nil, "target object does not contain name and port"
end


------------------------------------------------------------------------------
-- Fetch targets, from cache or the DB.
-- @param upstream The upstream entity object
-- @return The targets array, with target entity tables.
function targets_M.fetch_targets(upstream)
  local targets_cache_key = "balancer:targets:" .. upstream.id

  if targets_by_upstream_id[targets_cache_key] == nil then
    targets_by_upstream_id[targets_cache_key] = load_targets_into_memory(upstream.id)
  end

  return targets_by_upstream_id[targets_cache_key]
end


function targets_M.clean_targets_cache(upstream)
  local targets_cache_key = "balancer:targets:" .. upstream.id
  targets_by_upstream_id[targets_cache_key] = nil
end


function targets_M.resolve_targets(targets_list)
  for _, target in ipairs(targets_list) do
    queryDns(target)
  end

  return targets_list
end

--==============================================================================
-- Event Callbacks
--==============================================================================



--------------------------------------------------------------------------------
-- Called on any changes to a target.
-- @param operation "create", "update" or "delete"
-- @param target Target table with `upstream.id` field
function targets_M.on_target_event(operation, target)
  local upstream_id = target.upstream.id
  local upstream_name = target.upstream.name

  log(DEBUG, "target ", operation, " for upstream ", upstream_id,
    upstream_name and " (" .. upstream_name ..")" or "")

  local targets_list = targets_by_upstream_id["balancer:targets:" .. upstream_id]
  targets_by_upstream_id["balancer:targets:" .. upstream_id] = nil

  local upstream = upstreams.get_upstream_by_id(upstream_id)
  if not upstream then
    log(ERR, "target ", operation, ": upstream not found for ", upstream_id,
      upstream_name and " (" .. upstream_name ..")" or "")
    return
  end

  for _, t in ipairs(targets_list) do
    -- cancel DNS renewal
    if operation ~= "create" then
      local key, err = get_dns_renewal_key(target)
      if key then
        renewal_weak_cache[key] = nil
        renewal_heap:remove(key)
      else
        log(ERR, "could not stop DNS renewal for target ", t, " removed from ", upstream_id, ": ", err)
      end
    end
  end

-- move this to upstreams?
  local balancer = balancers.get_balancer_by_id(upstream_id)
  if not balancer then
    log(ERR, "target ", operation, ": balancer not found for ", upstream_id,
      upstream_name and " (" .. upstream_name ..")" or "")
    return
  end

  local new_balancer, err = balancers.create_balancer(upstream, true)
  if not new_balancer then
    return nil, err
  end

  return true
end


--==============================================================================
-- DNS
--==============================================================================


-- define sort order for DNS query results
local sortQuery = function(a,b) return a.__balancerSortKey < b.__balancerSortKey end
local sorts = {
  [dns_client.TYPE_A] = function(result)
    local sorted = {}
    -- build table with keys
    for i, v in ipairs(result) do
      sorted[i] = v
      v.__balancerSortKey = v.address
    end
    -- sort by the keys
    table_sort(sorted, sortQuery)
    -- reverse index
    for i, v in ipairs(sorted) do sorted[v.__balancerSortKey] = i end
    return sorted
  end,

  [dns_client.TYPE_SRV] = function(result)
    local sorted = {}
    -- build table with keys
    for i, v in ipairs(result) do
      sorted[i] = v
      v.__balancerSortKey = string_format("%06d:%s:%s", v.priority, v.target, v.port)
    end
    -- sort by the keys
    table_sort(sorted, sortQuery)
    -- reverse index
    for i, v in ipairs(sorted) do sorted[v.__balancerSortKey] = i end
    return sorted
  end,
}

sorts[dns_client.TYPE_AAAA] = sorts[dns_client.TYPE_A] -- A and AAAA use the same sorting order

sorts = setmetatable(sorts,{
  -- all record types not mentioned above are unsupported, throw error
  __index = function(_, key)
    error("Unknown/unsupported DNS record type; "..tostring(key))
  end,
})


local atomic_tracker = setmetatable({},{ __mode = "k" })
local function assert_atomicity(f, self, ...)
  -- if the following assertion failed, then the function probably yielded and
  -- allowed other threads to enter simultaneously.
  -- This was added to prevent issues like
  -- https://github.com/Kong/lua-resty-dns-client/issues/49
  -- to reappear in the future, providing a clear understanding of what is wrong
  atomic_tracker[self.balancer] = assert(not atomic_tracker[self.balancer],
    "Failed to run atomically, multiple threads updating balancer simultaneously")

  local ok, err = f(self, ...)
  atomic_tracker[self.balancer] = nil

  return ok, err
end


-- Timer invoked to update DNS records
function resolve_timer_callback(premature)
  if premature then
    return
  end

  local now = ngx_now()

  while (renewal_heap:peekValue() or math.huge) < now do
    local key    = renewal_heap:pop()
    local target = renewal_weak_cache[key] -- can return nil if GC'ed
    if target then
      log(DEBUG, "executing requery for: ", target.name)
      queryDns(target, false) -- timer-context; cacheOnly always false
    end
  end

  if exiting() then
    return
  end

  local err
  resolve_timer_running, err = ngx.timer.at(1, resolve_timer_callback)
  if not resolve_timer_running then
    log(CRIT, "could not reschedule DNS resolver timer: ", err)
  end
end



-- schedules a DNS update for a host in the global timer queue. This uses only
-- a single timer for all balancers.
-- IMPORTANT: this construct should not prevent GC of the Host object
local function schedule_dns_renewal(target)
  local record_expiry = (target.lastQuery or EMPTY).expire or 0

  local key, err = get_dns_renewal_key(target)
  if err then
    local tgt_name = target.name or target.target or "[empty hostname]"
    log(ERR, "could not schedule DNS renewal for target ", tgt_name, ":", err)
    return
  end

  -- because of the DNS cache, a stale record will most likely be returned by the
  -- client, and queryDns didn't do anything, other than start a background renewal
  -- query. In that case record_expiry is based on the stale old query (lastQuery)
  -- and it will be in the past. So we schedule a renew at least 0.5 seconds in
  -- the future, so by then the background query is complete and that second call
  -- to queryDns will do the actual updates. Without math.max is would create a
  -- busy loop and hang.
  local new_renew_at = math.max(ngx_now(), record_expiry) + 0.5
  local old_renew_at = renewal_heap:valueByPayload(key)

  -- always store the host in the registry, because the same key might be reused
  -- by a new host-object for the same hostname in case of quick delete/add sequence
  renewal_weak_cache[key] = target

  if old_renew_at then
    renewal_heap:update(key, new_renew_at)
  else
    renewal_heap:insert(new_renew_at, key)
  end
end


local function update_dns_result(target, newQuery)
  local balancer = target and target.balancer

  local oldQuery = target.lastQuery or {}
  local oldSorted = target.lastSorted or {}

  -- we're using the dns' own cache to check for changes.
  -- if our previous result is the same table as the current result, then nothing changed
  if oldQuery == newQuery then
    log(DEBUG, "no dns changes detected for ", target.name)

    return true    -- exit, nothing changed
  end

  -- To detect ttl = 0 we validate both the old and new record. This is done to ensure
  -- we do not hit the edgecase of https://github.com/Kong/lua-resty-dns-client/issues/51
  -- So if we get a ttl=0 twice in a row (the old one, and the new one), we update it. And
  -- if the very first request ever reports ttl=0 (we assume we're not hitting the edgecase
  -- in that case)
  if (newQuery[1] or EMPTY).ttl == 0 and
     (((oldQuery[1] or EMPTY).ttl or 0) == 0 or oldQuery.__ttl0Flag)
  then
    -- ttl = 0 means we need to lookup on every request.
    -- To enable lookup on each request we 'abuse' a virtual SRV record. We set the ttl
    -- to `ttl0Interval` seconds, and set the `target` field to the hostname that needs
    -- resolving. Now `getPeer` will resolve on each request if the target is not an IP address,
    -- and after `ttl0Interval` seconds we'll retry to see whether the ttl has changed to non-0.
    -- Note: if the original record is an SRV we cannot use the dns provided weights,
    -- because we can/are not going to possibly change weights on each request
    -- so we fix them at the `nodeWeight` property, as with A and AAAA records.
    if oldQuery.__ttl0Flag then
      -- still ttl 0 so nothing changed
      oldQuery.touched = ngx_now()
      oldQuery.expire = oldQuery.touched + balancer.ttl0Interval
      log(DEBUG, "no dns changes detected for ",
              target.name, ", still using ttl=0")
      return true
    end

    log(DEBUG, "ttl=0 detected for ", target.name)
    newQuery = {
        {
          type = dns_client.TYPE_SRV,
          target = target.name,
          name = target.name,
          port = target.port,
          weight = target.weight,
          priority = 1,
          ttl = balancer.ttl0Interval,
        },
        expire = ngx_now() + balancer.ttl0Interval,
        touched = ngx_now(),
        __ttl0Flag = true,        -- flag marking this record as a fake SRV one
      }
  end

  -- a new dns record, was returned, but contents could still be the same, so check for changes
  -- sort table in unique order
  local rtype = (newQuery[1] or EMPTY).type
  if not rtype then
    -- we got an empty query table, so assume A record, because it's empty
    -- all existing addresses will be removed
    log(DEBUG, "blank dns record for ", target.name, ", assuming A-record")
    rtype = dns_client.TYPE_A
  end
  local newSorted = sorts[rtype](newQuery)
  local dirty

  if rtype ~= (oldSorted[1] or EMPTY).type then
    -- DNS recordtype changed; recycle everything
    log(DEBUG, "dns record type changed for ",
            target.name, ", ", (oldSorted[1] or EMPTY).type, " -> ",rtype)
    for i = #oldSorted, 1, -1 do  -- reverse order because we're deleting items
      balancer:disableAddress(target, oldSorted[i])
    end
    for _, entry in ipairs(newSorted) do -- use sorted table for deterministic order
      balancer:addAddress(target, entry)
    end
    dirty = true
  else
    -- new record, but the same type
    local topPriority = (newSorted[1] or EMPTY).priority -- nil for non-SRV records
    local done = {}
    local dCount = 0
    for _, newEntry in ipairs(newSorted) do
      if newEntry.priority ~= topPriority then break end -- exit when priority changes, as SRV only uses top priority

      local key = newEntry.__balancerSortKey
      local oldEntry = oldSorted[oldSorted[key] or "__key_not_found__"]
      if not oldEntry then
        -- it's a new entry
        log(DEBUG, "new dns record entry for ",
                target.name, ": ", (newEntry.target or newEntry.address),
                ":", newEntry.port) -- port = nil for A or AAAA records
        balancer:addAddress(target, newEntry)
        dirty = true
      else
        -- it already existed (same ip, port)
        if newEntry.weight and
           newEntry.weight ~= oldEntry.weight and
           not (newEntry.weight == 0  and oldEntry.weight == SRV_0_WEIGHT)
        then
          -- weight changed (can only be an SRV)
          --host:findAddress(oldEntry):change(newEntry.weight == 0 and SRV_0_WEIGHT or newEntry.weight)
          balancer:changeWeight(target, oldEntry, newEntry.weight == 0 and SRV_0_WEIGHT or newEntry.weight)
          dirty = true
        else
          log(DEBUG, "unchanged dns record entry for ",
                  target.name, ": ", (newEntry.target or newEntry.address),
                  ":", newEntry.port) -- port = nil for A or AAAA records
        end
        done[key] = true
        dCount = dCount + 1
      end
    end
    if dCount ~= #oldSorted then
      -- not all existing entries were handled, remove the ones that are not in the
      -- new query result
      for _, entry in ipairs(oldSorted) do
        if not done[entry.__balancerSortKey] then
          log(DEBUG, "removed dns record entry for ",
                  target.name, ": ", (entry.target or entry.address),
                  ":", entry.port) -- port = nil for A or AAAA records
          balancer:disableAddress(target, entry)
        end
      end
      dirty = true
    end
  end

  target.lastQuery  = newQuery
  target.lastSorted = newSorted

  if dirty then
    -- above we already added and updated records. Removed addresses are disabled, and
    -- need yet to be deleted from the Host
    log(DEBUG, "updating balancer based on dns changes for ",
            target.name)

    -- allow balancer to update its algorithm
    balancer:afterHostUpdate(target)

    -- delete addresses previously disabled
    balancer:deleteDisabledAddresses(target)
  end

  log(DEBUG, "querying dns and updating for ", target.name, " completed")
  return true
end


-- Queries the DNS for this hostname. Updates the underlying address objects.
-- This method always succeeds, but it might leave the balancer in a 0-weight
-- state if none of the hosts resolves.
function queryDns(target, cacheOnly)
  log(DEBUG, "querying dns for ", target.name)

  -- first thing we do is the dns query, this is the only place we possibly
  -- yield (cosockets in the dns lib). So once that is done, we're 'atomic'
  -- again, and we shouldn't have any nasty race conditions.
  -- Note: the other place we may yield would be the callbacks, who's content
  -- we do not control, hence they are executed delayed, to ascertain
  -- atomicity.
  local newQuery, err, try_list = dns_client.resolve(target.name, nil, cacheOnly)

  if err then
    log(WARN, "querying dns for ", target.name,
            " failed: ", err , ". Tried ", tostring(try_list))

    -- query failed, create a fake record
    -- the empty record will cause all existing addresses to be removed
    newQuery = {
      expire = ngx_now() + target.balancer.requeryInterval,
      touched = ngx_now(),
      __dnsError = err,
    }
  end

  assert_atomicity(update_dns_result, target, newQuery)

  schedule_dns_renewal(target)
end


local function targetExpired(target)
  return not target.lastQuery or target.lastQuery.expire < ngx_now()
end


function targets_M.getAddressPeer(address, cacheOnly)
  if not address.available then
    return nil, balancers.errors.ERR_ADDRESS_UNAVAILABLE
  end

  local ctx = ngx.ctx
  local target = address.target
  if targetExpired(target) and not cacheOnly then
    queryDns(target, cacheOnly)
    ctx.KONG_UPSTREAM_DNS_END_AT = get_updated_now_ms()
    if address.target ~= target then
      return nil, balancers.errors.ERR_DNS_UPDATED
    end
  end

  if address.ipType == "name" then    -- missing classification. (can it be a "name"?)
    -- SRV type record with a named target
    local ip, port, try_list = dns_client.toip(address.ip, address.port, cacheOnly)
    if not ip then
      port = tostring(port) .. ". Tried: " .. tostring(try_list)
      return ip, port
    end

    return ip, port, address.hostHeader
  end

  return address.ip, address.port, address.hostHeader

end


return targets_M
