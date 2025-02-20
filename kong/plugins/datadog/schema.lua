local typedefs = require "kong.db.schema.typedefs"

local STAT_NAMES = {
  "kong_latency",
  "latency",
  "request_count",
  "request_size",
  "response_size",
  "upstream_latency",
}

local STAT_TYPES = {
  "counter",
  "gauge",
  "histogram",
  "meter",
  "set",
  "timer",
  "distribution",
}

local CONSUMER_IDENTIFIERS = {
  "consumer_id",
  "custom_id",
  "username",
}

local DEFAULT_METRICS = {
  {
    name                = "request_count",
    stat_type           = "counter",
    sample_rate         = 1,
    tags                = { "app:kong" },
    consumer_identifier = "custom_id"
  },
  {
    name                = "latency",
    stat_type           = "timer",
    tags                = { "app:kong" },
    consumer_identifier = "custom_id"
  },
  {
    name                = "request_size",
    stat_type           = "timer",
    tags                = { "app:kong" },
    consumer_identifier = "custom_id"
  },
  {
    name                = "response_size",
    stat_type           = "timer",
    tags                = { "app:kong" },
    consumer_identifier = "custom_id"
  },
  {
    name                = "upstream_latency",
    stat_type           = "timer",
    tags                = { "app:kong" },
    consumer_identifier = "custom_id"
  },
  {
    name                = "kong_latency",
    stat_type           = "timer",
    tags                = { "app:kong" },
    consumer_identifier = "custom_id"
  },
}


return {
  name = "datadog",
  fields = {
    { protocols = typedefs.protocols },
    {
      config = {
        type = "record",
        fields = {
          { host = typedefs.host({ referenceable = true, default = "localhost" }), },
          { port = typedefs.port({ default = 8125 }), },
          { prefix = { description = "String to be attached as a prefix to a metric's name.", type = "string",
            default = "kong" }, },
          {
              service_name_tag = { description = "String to be attached as the name of the service.", type = "string",
              default = "name" }, },
          {
              route_name_tag = { description = "String to be attached as the name of the route.", type = "string",
              default = "route" }, },
          {
              status_tag = { description = "String to be attached as the tag of the HTTP status.", type = "string",
              default = "status" }, },
          {
              consumer_tag = { description = "String to be attached as tag of the consumer.", type = "string",
              default = "consumer" }, },
          {
              retry_count = {
                description = "Number of times to retry when sending data to the upstream server.",
                type = "integer",
                deprecation = {
                  message = "datadog: config.retry_count no longer works, please use config.queue.max_retry_time instead",
                  removal_in_version = "4.0",
                  old_default = 10 }, }, },
          {
              queue_size = {
                description = "Maximum number of log entries to be sent on each message to the upstream server.",
                type = "integer",
                deprecation = {
                  message = "datadog: config.queue_size is deprecated, please use config.queue.max_batch_size instead",
                  removal_in_version = "4.0",
                  old_default = 1 }, }, },
          {
              flush_timeout = {
                description =
                  "Optional time in seconds. If `queue_size` > 1, this is the max idle time before sending a log with less than `queue_size` records.",
                type = "number",
                deprecation = {
                  message = "datadog: config.flush_timeout is deprecated, please use config.queue.max_coalescing_delay instead",
                  removal_in_version = "4.0",
                  old_default = 2 }, }, },
          { queue = typedefs.queue },
          {
            metrics = {
              description =
              "List of metrics to be logged.",
              type = "array",
              required = true,
              default  = DEFAULT_METRICS,
              elements = {
                type = "record",
                fields = {
                  { name = { description = "Datadog metric’s name", type = "string", required = true,
                    one_of = STAT_NAMES }, },
                  {
                      stat_type = { description = "Determines what sort of event the metric represents", type = "string",
                      required = true, one_of = STAT_TYPES }, },
                  { tags = { description = "List of tags", type = "array",
                    elements = { type = "string", match = "^.*[^:]$" }, }, },
                  { sample_rate = { description = "Sampling rate", type = "number", between = { 0, 1 }, }, },
                  { consumer_identifier = { description = "Authenticated user detail", type = "string",
                    one_of = CONSUMER_IDENTIFIERS }, },
                },
                entity_checks = {
                  {
                    conditional = {
                      if_field = "stat_type",
                      if_match = { one_of = { "counter", "gauge" }, },
                      then_field = "sample_rate",
                      then_match = { required = true },
                    },
                  }, },
              },
            },
          },
        },
      },
    },
  },
}
