local policies = require "kong.plugins.response-ratelimiting.policies"
local timestamp = require "kong.tools.timestamp"


local kong = kong
local next = next
local pairs = pairs
local error = error
local tostring = tostring


local EMPTY = require("kong.tools.table").EMPTY
local HTTP_TOO_MANY_REQUESTS = 429
local RATELIMIT_REMAINING = "X-RateLimit-Remaining"


local function get_identifier(conf)
  local identifier

  if conf.limit_by == "consumer" then
    identifier = (kong.client.get_consumer() or
                  kong.client.get_credential() or
                  EMPTY).id

  elseif conf.limit_by == "credential" then
    identifier = (kong.client.get_credential() or
                  EMPTY).id
  end

  return identifier or kong.client.get_forwarded_ip()
end


local function get_usage(conf, identifier, limits, current_timestamp)
  local usage = {}

  for k, v in pairs(limits) do -- Iterate over limit names
    for lk, lv in pairs(v) do -- Iterare over periods
      local current_usage, err = policies[conf.policy].usage(conf, identifier, k, lk, current_timestamp)
      if err then
        return nil, err
      end

      if not usage[k] then
        usage[k] = {}
      end

      if not usage[k][lk] then
        usage[k][lk] = {}
      end

      usage[k][lk].limit = lv
      usage[k][lk].remaining = lv - current_usage
    end
  end

  return usage
end


local _M = {}


function _M.execute(conf)
  if not next(conf.limits) then
    return
  end

  -- Load info
  local current_timestamp = timestamp.get_utc()
  kong.ctx.plugin.current_timestamp = current_timestamp -- For later use
  local identifier = get_identifier(conf)
  kong.ctx.plugin.identifier = identifier -- For later use

  -- Load current metric for configured period
  local usage, err = get_usage(conf, identifier, conf.limits, current_timestamp)
  if err then
    if not conf.fault_tolerant then
      return error(err)
    end

    kong.log.err("failed to get usage: ", tostring(err))
    return
  end

  -- Append usage headers to the upstream request. Also checks "block_on_first_violation".
  for k in pairs(conf.limits) do
    local remaining
    for _, lv in pairs(usage[k]) do
      if conf.block_on_first_violation and lv.remaining == 0 then
        return kong.response.error(HTTP_TOO_MANY_REQUESTS,
          "API rate limit exceeded for '" .. k .. "'")
      end

      if not remaining or lv.remaining < remaining then
        remaining = lv.remaining
      end
    end

    kong.service.request.set_header(RATELIMIT_REMAINING .. "-" .. k, remaining)
  end

  kong.ctx.plugin.usage = usage -- For later use
end


return _M
