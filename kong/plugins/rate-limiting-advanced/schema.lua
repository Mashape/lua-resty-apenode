-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local redis  = require "kong.enterprise_edition.tools.redis.v2"
local redis_config_utils = require "kong.enterprise_edition.tools.redis.v2.config_utils"
local typedefs = require "kong.db.schema.typedefs"
local tablex = require "pl.tablex"


local ngx = ngx
local ngx_null = ngx.null
local concat = table.concat
local tbx_deepcopy = tablex.deepcopy
local tbl_insert = table.insert

local redis_schema = redis.config_schema
local redis_proxy_types = redis_config_utils.redis_proxy_types

local rla_redis_schema = tbx_deepcopy(redis_schema)
tbl_insert(rla_redis_schema.fields,
  { redis_proxy_type = {
      description = "If the `connection_is_proxied` is enabled, this field indicates the proxy type and version you are using. For example, you can enable this optioin when you want authentication between Kong and Envoy proxy.",
      type = "string",
      one_of = redis_proxy_types,
      required = false,
      default = nil,
    }
  }
)


local function is_present(value)
  return value ~= nil and value ~= ngx_null
end


local function check_shdict(name)
  if not ngx.shared[name] then
    return false, "missing shared dict '" .. name .. "'"
  end

  return true
end


local identifier_items = { "ip", "credential", "consumer", "service", "header", "path", "consumer-group" }

return {
  name = "rate-limiting-advanced",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { identifier = { description = "The type of identifier used to generate the rate limit key. Defines the scope used to increment the rate limiting counters. Can be `ip`, `credential`, `consumer`, `service`, `header`, `path` or `consumer-group`.", type = "string",
            one_of = identifier_items,
            default = "consumer",
            required = true,
          }},
          { compound_identifier = { description = "Similar to `identifer`, but supports combining multiple items. The priority of `compound_identifier` is higher than `identifier`, which means if `compound_identifer` is set, it will be used, otherwise `identifier` will be used.", type = "array",
            elements = {
              type = "string",
              one_of = identifier_items,
            },
          }},
          { window_size = { description = "One or more window sizes to apply a limit to (defined in seconds). There must be a matching number of window limits and sizes specified.", type = "array",
            elements = {
              type = "number",
            },
            required = true,
          }},
          { window_type = { description = "Sets the time window type to either `sliding` (default) or `fixed`. Sliding windows apply the rate limiting logic while taking into account previous hit rates (from the window that immediately precedes the current) using a dynamic weight. Fixed windows consist of buckets that are statically assigned to a definitive time range, each request is mapped to only one fixed window based on its timestamp and will affect only that window's counters.", type = "string",
            one_of = { "fixed", "sliding" },
            default = "sliding",
          }},
          { limit = { description = "One or more requests-per-window limits to apply. There must be a matching number of window limits and sizes specified.", type = "array",
            elements = {
              type = "number",
            },
            required = true,
          }},
          { sync_rate = { description = "How often to sync counter data to the central data store. A value of 0 results in synchronous behavior; a value of -1 ignores sync behavior entirely and only stores counters in node memory. A value greater than 0 will sync the counters in the specified number of seconds. The minimum allowed interval is 0.02 seconds (20ms).", type = "number",
          }},
          { namespace = { description = "The rate limiting library namespace to use for this plugin instance. Counter data and sync configuration is isolated in each namespace. NOTE: For the plugin instances sharing the same namespace, all the configurations that are required for synchronizing counters, e.g. `strategy`, `redis`, `sync_rate`, `dictionary_name`, need to be the same.", type = "string",
            auto = true,
            required = true,
          }},
          { strategy = { description = "The rate-limiting strategy to use for retrieving and incrementing the limits. Available values are: `local` and `cluster`.", type = "string",
            one_of = { "cluster", "redis", "local" },
            default = "local",
            required = true,
          }},
          { dictionary_name = { description = "The shared dictionary where counters are stored. When the plugin is configured to synchronize counter data externally (that is `config.strategy` is `cluster` or `redis` and `config.sync_rate` isn't `-1`), this dictionary serves as a buffer to populate counters in the data store on each synchronization cycle.", type = "string",
            default = "kong_rate_limiting_counters",
            required = true,
          }},
          {
            lock_dictionary_name = { description = "The shared dictionary where concurrency control locks are stored. The default shared dictionary is `kong_locks`. The shared dictionary should be declare in nginx-kong.conf.", type = "string",
            default = "kong_locks",
            required = true,
          }},
          { hide_client_headers = { description = "Optionally hide informative response headers that would otherwise provide information about the current status of limits and counters.", type = "boolean",
            default = false,
          }},
          { retry_after_jitter_max = { description = "The upper bound of a jitter (random delay) in seconds to be added to the `Retry-After` header of denied requests (status = `429`) in order to prevent all the clients from coming back at the same time. The lower bound of the jitter is `0`; in this case, the `Retry-After` header is equal to the `RateLimit-Reset` header.", -- in seconds
            type = "number",
            default = 0,
          }},
          { header_name = typedefs.header_name, },
          { path = typedefs.path },
          { redis = rla_redis_schema },
          { enforce_consumer_groups = { description = "Determines if consumer groups are allowed to override the rate limiting settings for the given Route or Service. Flipping `enforce_consumer_groups` from `true` to `false` disables the group override, but does not clear the list of consumer groups. You can then flip `enforce_consumer_groups` to `true` to re-enforce the groups.", type = "boolean",
            default = false,
          }},
          { consumer_groups = { description = "List of consumer groups allowed to override the rate limiting settings for the given Route or Service. Required if `enforce_consumer_groups` is set to `true`.", type = "array",
            elements = {
              type = "string",
            },
          }},
          { disable_penalty = { description = "If set to `true`, this doesn't count denied requests (status = `429`). If set to `false`, all requests, including denied ones, are counted. This parameter only affects the `sliding` window_type.", type = "boolean",
            default = false,
          }},
          { error_code = { description = "Set a custom error code to return when the rate limit is exceeded.", type = "number", default = 429, gt = 0, }, },
          { error_message = { description = "Set a custom error message to return when the rate limit is exceeded.", type = "string", default = "API rate limit exceeded", }, },
        },
      },
    }
  },

  entity_checks = {
    { custom_entity_check = {
      field_sources = { "config" },
      fn = function(entity)
        local config = entity.config

        if not config.limit or not config.window_size then
          return true
        end

        if #config.window_size ~= #config.limit then
          return nil, "You must provide the same number of windows and limits"
        end

        -- sort the window_size and limit arrays by limit
        -- first we create a temp table, each element of which is a pair of
        -- limit/window_size values. we then sort based on the limit element
        -- of this array of pairs. finally, we re-assign the configuration
        -- elements directly based off the sorted temp table
        local t = {}
        for i, v in ipairs(config.limit) do
          t[i] = { config.limit[i], config.window_size[i] }
        end

        table.sort(t, function(a, b) return tonumber(a[1]) < tonumber(b[1]) end)

        for i = 1, #t do
          config.limit[i] = tonumber(t[i][1])
          config.window_size[i] = tonumber(t[i][2])
        end

        if config.strategy == "cluster" and config.sync_rate ~= -1 then
          if kong.configuration.role ~= "traditional" or kong.configuration.database == "off" then
            return nil, concat{ "[rate-limiting-advanced] ",
                                "strategy 'cluster' is not supported with Hybrid deployments or DB-less mode. ",
                                "If you did not specify the strategy, please use 'redis' strategy, 'local' strategy ",
                                "or set 'sync_rate' to -1.", }
          end
        end

        if config.strategy == "redis" then
          if config.redis.host == ngx_null and
             config.redis.sentinel_nodes == ngx_null and
             config.redis.cluster_nodes == ngx_null then
            return nil, "No redis config provided"
          end
        end

        if is_present(config.redis.redis_proxy_type) then
          if config.strategy ~= "redis" then
            return nil, "'redis_proxy_type' makes sense only when 'strategy' is 'redis'."
          end

          if config.redis.connection_is_proxied ~= true then
            return nil, "'redis_proxy_type' makes sense only when 'connection_is_proxied' is 'true'."
          end
        end

        if config.strategy == "local" then
          if config.sync_rate ~= ngx_null and config.sync_rate > -1 then
            return nil, "sync_rate cannot be configured when using a local strategy"
          end
          config.sync_rate = -1
        else
          if config.sync_rate == ngx_null then
            return nil, "sync_rate is required if not using a local strategy"
          end
        end

        if config.dictionary_name ~= nil then
          local ok, err = check_shdict(config.dictionary_name)
          if not ok then
            return nil, err
          end
        end

        if kong.configuration.role ~= "control_plane" and config.lock_dictionary_name ~= nil then
          local ok, err = check_shdict(config.lock_dictionary_name)
          if not ok then
            return nil, err
          end
        end

        if config.identifier == "header" then
          if config.header_name == ngx_null then
            return nil, "No header name provided"
          end
        end

        -- Ensure that no items are duplicated
        if type(config.compound_identifier) == "table" then
          local seen = {}
          for _, item in ipairs(config.compound_identifier) do
            if seen[item] then
              return nil, "Duplicated items found in 'compound_identifier': '" .. item .. "'"
            end

            seen[item] = true
          end
        end

        if config.identifier == "path" then
          if config.path == ngx_null then
            return nil, "No path provided"
          end
        end

        if config.retry_after_jitter_max < 0 then
          return nil, "Non-negative retry_after_jitter_max value is expected"
        end

        -- a decimal between 0 and 1 messes with internal time calculations
        if config.sync_rate > 0 and config.sync_rate < 0.02 then
          return nil, "Config option 'sync_rate' must not be a decimal between 0 and 0.02"
        end

        if config.enforce_consumer_groups then
          if config.consumer_groups == ngx_null then
            return nil, "No consumer groups provided"
          end
        end
        return true
      end
    }},
  },
}
