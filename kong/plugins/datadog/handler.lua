local Queue = require "kong.tools.queue"
local statsd_logger = require "kong.plugins.datadog.statsd_logger"
local kong_meta = require "kong.meta"


local replace_dashes = require("kong.tools.string").replace_dashes


local kong     = kong
local ngx      = ngx
local null     = ngx.null
local insert   = table.insert
local gsub     = string.gsub
local pairs    = pairs
local ipairs   = ipairs


local get_consumer_id = {
  consumer_id = function(consumer)
    return consumer and replace_dashes(consumer.id)
  end,
  custom_id = function(consumer)
    return consumer and consumer.custom_id
  end,
  username = function(consumer)
    return consumer and consumer.username
  end
}


local function compose_tags(service_name, status, consumer_id, tags, conf, route_name)
  local result = {
    (conf.service_name_tag or "name") .. ":" .. service_name,
    (conf.status_tag or "status") .. ":" .. status,
    route_name and route_name ~= "" and ((conf.route_name_tag or "route") .. ":" .. route_name)
  }

  if consumer_id ~= nil then
    insert(result, (conf.consumer_tag or "consumer") .. ":" .. consumer_id)
  end

  if tags ~= nil then
    for _, v in pairs(tags) do
      insert(result, v)
    end
  end

  return result
end


local function send_entries_to_datadog(conf, messages)
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
      request_size     = message.request and message.request.size,
      response_size    = message.response and message.response.size,
      latency          = message.latencies.request,
      upstream_latency = message.latencies.proxy,
      kong_latency     = message.latencies.kong,
      request_count    = 1,
    }

    for _, metric_config in pairs(conf.metrics) do
      local stat_name       = stat_name[metric_config.name]
      if stat_name == nil then
        goto continue
      end

      local stat_value      = stat_value[metric_config.name]
      local get_consumer_id = get_consumer_id[metric_config.consumer_identifier]
      local consumer_id     = get_consumer_id and get_consumer_id(message.consumer) or nil
      local tags            = compose_tags(
                                message.service and gsub(message.service.name ~= null and
                                message.service.name or message.service.host, "%.", "_") or "",
                                message.response and message.response.status or "-",
                                consumer_id, metric_config.tags,
                                conf,
                                message.route and (message.route.name and gsub(message.route.name ~= null and
                                message.route.name, "%.", "_") or message.route.id) or "")

      logger:send_statsd(stat_name, stat_value,
                         logger.stat_types[metric_config.stat_type],
                         metric_config.sample_rate, tags)
      ::continue::
    end
  end

  logger:close_socket()
  return true
end


local DatadogHandler = {
  PRIORITY = 10,
  VERSION = kong_meta.version,
}

function DatadogHandler:log(conf)
  local ok, err = Queue.enqueue(
    Queue.get_plugin_params("datadog", conf),
    send_entries_to_datadog,
    conf,
    kong.log.serialize()
  )
  if not ok then
    kong.log.err("failed to enqueue log entry to Datadog: ", err)
  end
end


return DatadogHandler
