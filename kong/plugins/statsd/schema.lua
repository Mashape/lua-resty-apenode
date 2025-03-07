local typedefs = require "kong.db.schema.typedefs"
local constants = require "kong.plugins.statsd.constants"


local METRIC_NAMES = {
  "kong_latency", "latency", "request_count", "request_per_user",
  "request_size", "response_size", "status_count", "status_count_per_user",
  "unique_users", "upstream_latency",
  "status_count_per_workspace", "status_count_per_user_per_route",
  "shdict_usage",
}


local STAT_TYPES = {
  "counter", "gauge", "histogram", "meter", "set", "timer",
}


local CONSUMER_IDENTIFIERS = {
  "consumer_id", "custom_id", "username", "credential"
}

local SERVICE_IDENTIFIERS = {
  "service_id", "service_name", "service_host", "service_name_or_host",
}

local WORKSPACE_IDENTIFIERS = {
  "workspace_id", "workspace_name",
}

local DEFAULT_METRICS = {
  {
    name                  = "request_count",
    stat_type             = "counter",
    sample_rate           = 1,
    service_identifier    = nil,
    consumer_identifier   = nil,
    workspace_identifier  = nil,
  },
  {
    name                = "latency",
    stat_type           = "timer",
    service_identifier  = nil,
    consumer_identifier = nil,
    workspace_identifier = nil,
  },
  {
    name                  = "request_size",
    stat_type             = "counter",
    sample_rate           = 1,
    service_identifier    = nil,
    consumer_identifier   = nil,
    workspace_identifier  = nil,
  },
  {
    name               = "status_count",
    stat_type          = "counter",
    sample_rate        = 1,
    service_identifier = nil,
  },
  {
    name                  = "response_size",
    stat_type             = "counter",
    sample_rate           = 1,
    service_identifier    = nil,
    consumer_identifier   = nil,
    workspace_identifier  = nil,
  },
  {
    name                = "unique_users",
    stat_type           = "set",
    consumer_identifier = nil,
    service_identifier  = nil,
  },
  {
    name                = "request_per_user",
    stat_type           = "counter",
    sample_rate         = 1,
    consumer_identifier = nil,
    service_identifier  = nil,
  },
  {
    name                  = "upstream_latency",
    stat_type             = "timer",
    service_identifier    = nil,
    consumer_identifier   = nil,
    workspace_identifier  = nil,
  },
  {
    name                  = "kong_latency",
    stat_type             = "timer",
    service_identifier    = nil,
    consumer_identifier   = nil,
    workspace_identifier  = nil,
  },
  {
    name                = "status_count_per_user",
    stat_type           = "counter",
    sample_rate         = 1,
    consumer_identifier = nil,
    service_identifier  = nil,
  },
  {
    name                 = "status_count_per_workspace",
    stat_type            = "counter",
    sample_rate          = 1,
    workspace_identifier = nil,
  },
  {
    name                = "status_count_per_user_per_route",
    stat_type           = "counter",
    sample_rate         = 1,
    consumer_identifier = nil,
    service_identifier  = nil,
  },
  {
    name               = "shdict_usage",
    stat_type          = "gauge",
    sample_rate        = 1,
    service_identifier = nil,
  },
}


local TAG_TYPE = {
  "dogstatsd", "influxdb",
  "librato", "signalfx",
}

local MUST_IDENTIFIER = {}

for _, metric in ipairs(DEFAULT_METRICS) do
  for _, id in ipairs({ "service", "consumer", "workspace"}) do
    if metric[id .. "_identifier"] then
      if not MUST_IDENTIFIER[id] then
        MUST_IDENTIFIER[id] = { metric.name }
      else
        MUST_IDENTIFIER[id][#MUST_IDENTIFIER[id]+1] = metric.name
      end
    end
  end
end

return {
  name = "statsd",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { host = typedefs.host({
              default = "localhost",
              description = "The IP address or hostname of StatsD server to send data to."
            })
          },
          { port = typedefs.port({
              default = 8125,
              description = "The port of StatsD server to send data to."
            })
          },
          { prefix = { description = "String to prefix to each metric's name.", type = "string", default = "kong" }, },
          { metrics = { description = "List of metrics to be logged.", type = "array",
              default = DEFAULT_METRICS,
              elements = {
                type = "record",
                fields = {
                  { name = { description = "StatsD metric’s name.", type = "string", required = true, one_of = METRIC_NAMES }, },
                  { stat_type = { description = "Determines what sort of event a metric represents.", type = "string", required = true, one_of = STAT_TYPES }, },
                  { sample_rate = { description = "Sampling rate", type = "number", gt = 0 }, },
                  { consumer_identifier = { description = "Authenticated user detail.", type = "string", one_of = CONSUMER_IDENTIFIERS }, },
                  { service_identifier = { description = "Service detail.", type = "string", one_of = SERVICE_IDENTIFIERS }, },
                  { workspace_identifier = { description = "Workspace detail.", type = "string", one_of = WORKSPACE_IDENTIFIERS }, },
                },
                entity_checks = {
                  { conditional = {
                    if_field = "stat_type",
                    if_match = { one_of = { "counter", "gauge" }, },
                    then_field = "sample_rate",
                    then_match = { required = true },
                  }, },
                },
              },
          }, },
          { allow_status_codes = { description = "List of status code ranges that are allowed to be logged in metrics.", type = "array",
            elements = {
              type = "string",
              match = constants.REGEX_STATUS_CODE_RANGE,
            },
          }, },
          -- combine udp packet up to this value, don't combine if it's 0
          -- 65,507 bytes (65,535 − 8 byte UDP header − 20 byte IP header) -- Wikipedia
          { udp_packet_size = { type = "number", between = {0, 65507}, default = 0 }, },
          { use_tcp = { type = "boolean", default = false }, },
          { hostname_in_prefix = { type = "boolean", default = false }, },
          { consumer_identifier_default = { type = "string", required = true, default = "custom_id", one_of = CONSUMER_IDENTIFIERS }, },
          { service_identifier_default = { type = "string", required = true, default = "service_name_or_host", one_of = SERVICE_IDENTIFIERS }, },
          { workspace_identifier_default = { type = "string", required = true, default = "workspace_id", one_of = WORKSPACE_IDENTIFIERS }, },
          { retry_count = {
              type = "integer",
              deprecation = {
                message = "statsd: config.retry_count no longer works, please use config.queue.max_retry_time instead",
                removal_in_version = "4.0",
                old_default = 10 }, }, },
          { queue_size = {
              type = "integer",
              deprecation = {
                message = "statsd: config.queue_size is deprecated, please use config.queue.max_batch_size instead",
                removal_in_version = "4.0",
                old_default = 1 }, }, },
          { flush_timeout = {
              type = "number",
              deprecation = {
                message = "statsd: config.flush_timeout is deprecated, please use config.queue.max_coalescing_delay instead",
                removal_in_version = "4.0",
                old_default = 2 }, }, },
          { tag_style = { type = "string", required = false, one_of = TAG_TYPE }, },
          { queue = typedefs.queue },
        },
      },
    },
  },
}
