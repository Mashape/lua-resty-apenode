local Queue = require "kong.tools.queue"
local constants = require "kong.plugins.statsd.constants"
local statsd_logger = require "kong.plugins.statsd.statsd_logger"
local ws = require "kong.workspaces"

local ngx = ngx
local kong = kong
local ngx_time = ngx.time
local re_gsub = ngx.re.gsub
local pairs = pairs
local ipairs = ipairs
local string_format = string.format
local match = ngx.re.match
local ipairs = ipairs
local tonumber = tonumber
local knode = kong and kong.node or require "kong.pdk.node".new()
local null = ngx.null

local START_RANGE_IDX = 1
local END_RANGE_IDX   = 2

local result_cache = setmetatable({}, { __mode = "k" })
local range_cache  = setmetatable({}, { __mode = "k" })

local _M = {}


local function get_cache_value(cache, cache_key)
  local cache_value = cache[cache_key]
  if not cache_value then
    cache_value = {}
    cache[cache_key] = cache_value
  end
  return cache_value
end

local function extract_range(status_code_list, range)
  local start_code, end_code
  local ranges = get_cache_value(range_cache, status_code_list)

  -- If range isn't in the cache, extract and put it in
  if not ranges[range] then
    local range_result, err = match(range, constants.REGEX_SPLIT_STATUS_CODES_BY_DASH, "oj")

    if err then
      kong.log.err(err)
      return
    end
    ranges[range] = { range_result[START_RANGE_IDX], range_result[END_RANGE_IDX] }
  end

  start_code = ranges[range][START_RANGE_IDX]
  end_code = ranges[range][END_RANGE_IDX]

  return start_code, end_code
end

-- Returns true if a given status code is within status code ranges
local function is_in_range(status_code_list, status_code)
  -- If there is no configuration then pass all response codes
  if not status_code_list then
    return true
  end

  local result_list = get_cache_value(result_cache, status_code_list)
  local result = result_list[status_code]

  -- If result is found in a cache then return results instantly
  if result ~= nil then
    return result
  end

  for _, range in ipairs(status_code_list) do
    -- Get status code range splitting by "-" character
    local start_code, end_code = extract_range(status_code_list, range)

    -- Checks if there is both interval numbers
    if start_code and end_code then
      -- If HTTP response code is in the range return true
      if status_code >= tonumber(start_code) and status_code <= tonumber(end_code) then
        -- Storing results in a cache
        result_list[status_code] = true
        return true
      end
    end
  end

  -- Return false if there are no match for a given status code ranges and store it in cache
  result_list[status_code] = false
  return false
end


local worker_id
local hostname = re_gsub(knode.get_hostname(), [[\.]], "_", "oj")

-- downsample timestamp
local shdict_metrics_last_sent = 0
local SHDICT_METRICS_SEND_THRESHOLD = 60


local get_consumer_id = {
  consumer_id = function(consumer, cred)
    return consumer and consumer.id
  end,
  custom_id   = function(consumer, cred)
    return consumer and consumer.custom_id
  end,
  username    = function(consumer, cred)
    return consumer and consumer.username
  end,
  credential = function(consumer, cred)
    return cred and cred.id
  end,
}

local get_service_id = {
  service_id           = function(service)
    return service and service.id
  end,
  service_name         = function(service)
    return service and service.name
  end,
  service_host         = function(service)
    return service and service.host
  end,
  service_name_or_host = function(service)
    return service and (service.name ~= null and
      service.name or service.host)
  end
}

local get_workspace_id = {
  workspace_id   = function()
    return ws.get_workspace_id()
  end,
  workspace_name = function()
    return ws.get_workspace_name()
  end
}

local metrics = {
  unique_users = function (scope_name, message, metric_config, logger, conf, tags)
    if conf.tag_style then
      -- skip unique_users in tag mode
      return
    end
    local get_consumer_id = get_consumer_id[metric_config.consumer_identifier or conf.consumer_identifier_default]
    local consumer_id     = get_consumer_id(message.consumer, message.authenticated_entity)

    if consumer_id then
      local stat = string_format("%s.user.uniques", scope_name)
      logger:send_statsd(stat, consumer_id, logger.stat_types.set)
    end
  end,
  request_per_user = function (scope_name, message, metric_config, logger, conf, tags)
    if conf.tag_style then
      -- skip request_per_user in tag mode
      return
    end
    local get_consumer_id = get_consumer_id[metric_config.consumer_identifier or conf.consumer_identifier_default]
    local consumer_id     = get_consumer_id(message.consumer, message.authenticated_entity)

    if consumer_id then
      local stat = string_format("%s.user.%s.request.count", scope_name, consumer_id)
      logger:send_statsd(stat, 1, logger.stat_types.counter,
        metric_config.sample_rate)
    end
  end,
  status_count = function (scope_name, message, metric_config, logger, conf, tags)
    if conf.tag_style then
      -- skip status_count in tag mode
      return
    end

    logger:send_statsd(string_format("%s.status.%s", scope_name, message.response.status),
      1, logger.stat_types.counter, metric_config.sample_rate)
  end,
  status_count_per_user = function (scope_name, message, metric_config, logger, conf, tags)
    if conf.tag_style then
      -- skip status_count_per_user in tag mode
      return
    end
    local get_consumer_id = get_consumer_id[metric_config.consumer_identifier or conf.consumer_identifier_default]
    local consumer_id     = get_consumer_id(message.consumer, message.authenticated_entity)

    if consumer_id then
      logger:send_statsd(string_format("%s.user.%s.status.%s", scope_name,
        consumer_id, message.response.status),
        1, logger.stat_types.counter,
        metric_config.sample_rate)
    end
  end,
  status_count_per_workspace = function (scope_name, message, metric_config, logger, conf, tags)
    if conf.tag_style then
      -- skip status_count_per_workspace in tag mode
      return
    end
    local get_workspace_id = get_workspace_id[metric_config.workspace_identifier or conf.workspace_identifier_default]
    local workspace_id     = get_workspace_id()

    if workspace_id then
      logger:send_statsd(string_format("%s.workspace.%s.status.%s", scope_name,
        workspace_id, message.response.status),
        1, logger.stat_types.counter,
        metric_config.sample_rate)
    end
  end,
  status_count_per_user_per_route = function (_, message, metric_config, logger, conf, tags)
    if conf.tag_style then
      -- skip status_count_per_user_per_route in tag mode
      return
    end

    local get_consumer_id = get_consumer_id[metric_config.consumer_identifier or conf.consumer_identifier_default]
    local consumer_id     = get_consumer_id(message.consumer, message.authenticated_entity)
    if not consumer_id then
      return
    end

    local route = message.route

    if route.id then
      logger:send_statsd(string_format("route.%s.user.%s.status.%s", route.id,
        consumer_id, message.response.status),
        1, logger.stat_types.counter,
        metric_config.sample_rate)
    end
  end,
}

-- add shdict metrics
if ngx.config.ngx_lua_version >= 10011 then
  metrics.shdict_usage = function (_, message, metric_config, logger, conf, tags)
    -- we don't need this for every request, send every 1 minute
    -- also only one worker needs to send this because it's shared
    if worker_id ~= 0 then
      return
    end

    local now = ngx_time()
    if shdict_metrics_last_sent + SHDICT_METRICS_SEND_THRESHOLD < now then
      shdict_metrics_last_sent = now
      for shdict_name, shdict in pairs(ngx.shared) do
        if conf.tag_style then
          local tags = {
            ["node"] = hostname,
            ["shdict"] = shdict_name,
          }
          logger:send_statsd(string_format("shdict.free_space"),
            shdict:free_space(), logger.stat_types.gauge,
            metric_config.sample_rate, tags, conf.tag_style)
          logger:send_statsd(string_format("shdict.capacity"),
            shdict:capacity(), logger.stat_types.gauge,
            metric_config.sample_rate, tags, conf.tag_style)
        else
          if conf.hostname_in_prefix then
            logger:send_statsd(string_format("shdict.%s.free_space", shdict_name),
              shdict:free_space(), logger.stat_types.gauge,
              metric_config.sample_rate)
            logger:send_statsd(string_format("shdict.%s.capacity", shdict_name),
              shdict:capacity(), logger.stat_types.gauge,
              metric_config.sample_rate)
          else
            logger:send_statsd(string_format("node.%s.shdict.%s.free_space",
              hostname, shdict_name),
              shdict:free_space(), logger.stat_types.gauge,
              metric_config.sample_rate)
            logger:send_statsd(string_format("node.%s.shdict.%s.capacity",
              hostname, shdict_name),
              shdict:capacity(), logger.stat_types.gauge,
              metric_config.sample_rate)
          end
        end

      end
    end
  end
end

local function get_scope_name(conf, message, service_identifier)
  local api = message.api
  local service = message.service
  local scope_name

  if service then
    scope_name = "service."
    -- don't fail on ce schema where service_identifier is not defined
    if not service_identifier then
      service_identifier = "service_name_or_host"
    end

    local service_name = get_service_id[service_identifier](service)
    if not service_name or service_name == null  then
      scope_name = scope_name .. "unnamed"
    else
      scope_name = scope_name .. re_gsub(service_name, [[\.]], "_", "oj")
    end
  elseif api then
    scope_name = "api."

    if not api or api == null then
      scope_name = scope_name .. "unnamed"
    else
      scope_name = scope_name .. re_gsub(api.name, [[\.]], "_", "oj")
    end
  else
    -- TODO: this follows the pattern used by
    -- https://github.com/Kong/kong/pull/2702 (which prevents an error from
    -- being thrown and avoids confusing reports as per our metrics keys), but
    -- as it stands, hides traffic from monitoring tools when the plugin is
    -- configured globally. In fact, this basically disables this plugin when
    -- it is configured to run globally, or per-consumer without an
    -- API/Route/Service.

    -- Changes in statsd-advanced: we still log these requests, but into a namespace of
    -- "global.unmatched".
    -- And we don't send upstream_latency and metrics with consumer or route
    scope_name = "global.unmatched"
  end

  return scope_name
end


local function get_tags(conf, message, metric_config)
  local tags = {}

  local get_workspace_id = get_workspace_id[metric_config.workspace_identifier or conf.workspace_identifier_default]
  local workspace_id     = get_workspace_id()


  local get_service_id = get_service_id[metric_config.service_identifier or conf.service_identifier_default]
  local service_id = get_service_id(message.service)

  local get_consumer_id = get_consumer_id[metric_config.consumer_identifier or conf.consumer_identifier_default]
  local consumer_id = get_consumer_id(message.consumer)

  if service_id then
    tags["service"] = service_id
  else
    -- do not record any stats if the service is not present
    return
  end

  local route_name
  if message and message.route then
    route_name = message.route.name or message.route.id
    tags["route"] = route_name
  end

  if workspace_id then
    tags["workspace"] = workspace_id
  end

  if workspace_id then
    tags["consumer"] = consumer_id
  end

  if hostname then
    tags["node"] = hostname
  end

  if message and message.response and message.response.status then
    tags["status"] = message.response.status
  end

  return tags
end


local function send_entries_to_upstream_server(conf, messages)
  local logger, err = statsd_logger:new(conf)
  if err then
    kong.log.err("failed to create Statsd logger: ", err)
    return false, err
  end

  for _, message in ipairs(messages) do
    local stat_name  = {
      request_size     = "request.size",
      response_size    = "response.size",
      latency          = "latency",
      upstream_latency = "upstream_latency",
      kong_latency     = "kong_latency",
      request_count    = "request.count",
    }
    local stat_value = {
      request_size     = message.request.size,
      response_size    = message.response.size,
      latency          = message.latencies.request,
      upstream_latency = message.latencies.proxy,
      kong_latency     = message.latencies.kong,
      request_count    = 1,
    }

    for _, metric_config in pairs(conf.metrics) do
      local metric_config_name = metric_config.name
      local metric = metrics[metric_config_name]

      local name
      local tags
      if conf.tag_style then
        tags = get_tags(conf, message, metric_config)

      else
        name = get_scope_name(conf, message, metric_config.service_identifier or conf.service_identifier_default)
      end

      if metric then
        metric(name, message, metric_config, logger, conf, tags)

      else
        local stat_name = stat_name[metric_config_name]
        local stat_value = stat_value[metric_config_name]

        if stat_value ~= nil and stat_value ~= -1 then
          if conf.tag_style then
            logger:send_statsd(stat_name, stat_value,
              logger.stat_types[metric_config.stat_type],
              metric_config.sample_rate, tags, conf.tag_style)

          else
            logger:send_statsd(name .. "." .. stat_name, stat_value,
              logger.stat_types[metric_config.stat_type],
              metric_config.sample_rate)
          end
        end
      end
    end
  end

  logger:close_socket()
  return true
end



function _M.execute(conf)
  if not is_in_range(conf.allow_status_codes, ngx.status) then
    return
  end

  kong.log.debug("Status code is within given status code ranges")

  if not worker_id then
    worker_id = ngx.worker.id() or -1
  end

  conf._prefix = conf.prefix

  if conf.hostname_in_prefix and conf.tag_style == nil then
    conf._prefix = conf._prefix .. ".node." .. hostname
  end

  local message = kong.log.serialize({ngx = ngx, kong = kong, })
  message.cache_metrics = ngx.ctx.cache_metrics

  local ok, err = Queue.enqueue(
    Queue.get_plugin_params("statsd", conf),
    send_entries_to_upstream_server,
    conf,
    message
  )
  if not ok then
    kong.log.err("Failed to enqueue log entry to StatsD server: ", err)
  end
end

-- only for test
_M.is_in_range = is_in_range

return _M
