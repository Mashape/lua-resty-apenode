local ipairs = ipairs
local type = type


local log_warn_message, _AI_PROVIDER_INCOMPATIBLE
do
  local ngx_log = ngx.log
  local ngx_WARN = ngx.WARN
  local fmt = string.format

  local KONG_VERSION = require("kong.meta").version

  local _log_prefix = "[clustering] "

  log_warn_message = function(hint, action, dp_version, log_suffix)
    local msg = fmt("Kong Gateway v%s %s " ..
                    "which is incompatible with dataplane version %s " ..
                    "and will %s.",
                    KONG_VERSION, hint, dp_version, action)
    ngx_log(ngx_WARN, _log_prefix, msg, log_suffix)
  end

  local _AI_PROVIDERS_ADDED = {
    [3008000000] = {
      "gemini",
      "bedrock",
    },
  }

  _AI_PROVIDER_INCOMPATIBLE = function(provider, ver)
    for _, v in ipairs(_AI_PROVIDERS_ADDED[ver]) do
      if v == provider then
        return true
      end
    end

    return false
  end
end

local compatible_checkers = {
  { 3010000000, --[[ 3.10.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local config_keys = config_table["keys"]
      if not config_keys then
        return nil
      end

      local has_update
      for _, t in ipairs(config_keys) do
        if t["x5t"] ~= nil then
          t["x5t"] = nil
          has_update = true
        end
      end

      if has_update then
        log_warn_message("contains configuration 'keys.x5t'",
                         "be removed",
                         dp_version,
                         log_suffix)
      end

      return has_update
    end
  },
  { 3008000000, --[[ 3.8.0.0 ]]
    function (config_table, dp_version, log_suffix)
      local has_update
      for _, plugin in ipairs(config_table.plugins or {}) do
        if plugin.name == 'acme' then
          local config = plugin.config
          if config.storage_config.redis.username ~= nil then
            log_warn_message('configures ' .. plugin.name .. ' plugin with redis username',
              'not work in this release',
              dp_version, log_suffix)
          end
        end

        if plugin.name == 'aws-lambda' then
          local config = plugin.config
          if config.aws_sts_endpoint_url ~= nil then
            config.aws_sts_endpoint_url = nil
            has_update = true
            log_warn_message('configures ' .. plugin.name .. ' plugin with aws_sts_endpoint_url',
              'will be removed.',
              dp_version, log_suffix)
          end
        end

        if plugin.name == 'ai-proxy' then
          local config = plugin.config
          if _AI_PROVIDER_INCOMPATIBLE(config.model.provider, 3008000000) then
            log_warn_message('configures ' .. plugin.name .. ' plugin with' ..
            ' "openai preserve mode", because ' .. config.model.provider .. ' provider ' ..
            ' is not supported in this release',
            dp_version, log_suffix)

            config.model.provider = "openai"
            config.route_type = "preserve"

            has_update = true
          end

          if config.model.provider == "mistral" and (
            not config.model.options or
            config.model.options == ngx.null or
            not config.model.options.upstream_url or
            config.model.options.upstream_url == ngx.null) then

            log_warn_message('configures ' .. plugin.name .. ' plugin with' ..
              ' mistral provider uses fallback upstream_url for managed serivice' ..
              dp_version, log_suffix)

            config.model.options = config.model.options or {}
            config.model.options.upstream_url = "https://api.mistral.ai:443"
            has_update = true
          end

        end

        if plugin.name == 'ai-request-transformer' then
          local config = plugin.config
          if _AI_PROVIDER_INCOMPATIBLE(config.llm.model.provider, 3008000000) then
            log_warn_message('configures ' .. plugin.name .. ' plugin with' ..
            ' "openai preserve mode", because ' .. config.llm.model.provider .. ' provider ' ..
            ' is not supported in this release',
            dp_version, log_suffix)

            config.llm.model.provider = "openai"

            has_update = true
          end
        end

        if plugin.name == 'ai-response-transformer' then
          local config = plugin.config
          if _AI_PROVIDER_INCOMPATIBLE(config.llm.model.provider, 3008000000) then
            log_warn_message('configures ' .. plugin.name .. ' plugin with' ..
            ' "openai preserve mode", because ' .. config.llm.model.provider .. ' provider ' ..
            ' is not supported in this release',
            dp_version, log_suffix)

            config.llm.model.provider = "openai"

            has_update = true
          end
        end
      end

      return has_update
    end
  },
  { 3007000000, --[[ 3.7.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local has_update

      for _, plugin in ipairs(config_table.plugins or {}) do
        if plugin.name == 'ai-proxy' then
          local config = plugin.config
          if config.route_type == "preserve" then
            config.route_type = "llm/v1/chat"
            log_warn_message('configures ' .. plugin.name .. ' plugin with' ..
                              ' route_type == "llm/v1/chat", because preserve' ..
                              ' mode is not supported in this release',
                              dp_version, log_suffix)
            has_update = true
          end
        end
      end

      return has_update
    end,
  },
  { 3006000000, --[[ 3.6.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local has_update
      local redis_plugins_update = {
        acme = require("kong.plugins.acme.clustering.compat.redis_translation").adapter,
        ['rate-limiting'] = require("kong.plugins.rate-limiting.clustering.compat.redis_translation").adapter,
        ['response-ratelimiting'] = require("kong.plugins.response-ratelimiting.clustering.compat.redis_translation").adapter
      }

      for _, plugin in ipairs(config_table.plugins or {}) do
        local adapt_fn = redis_plugins_update[plugin.name]
        if adapt_fn and type(adapt_fn) == "function" then
          has_update = adapt_fn(plugin.config)
          if has_update then
            log_warn_message('adapts ' .. plugin.name .. ' plugin redis configuration to older version',
            'revert to older schema',
            dp_version, log_suffix)
          end
        end
      end

      return has_update
    end,
  },

  { 3005000000, --[[ 3.5.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local has_update

      for _, plugin in ipairs(config_table.plugins or {}) do
        if plugin.name == 'opentelemetry' or plugin.name == 'zipkin' then
          local config = plugin.config
          if config.header_type == 'gcp' then
            config.header_type = 'preserve'
            log_warn_message('configures ' .. plugin.name .. ' plugin with:' ..
                             ' header_type == gcp',
                             'overwritten with default value `preserve`',
                             dp_version, log_suffix)
            has_update = true
          end
        end

        if plugin.name == 'zipkin' then
          local config = plugin.config
          if config.default_header_type == 'gcp' then
            config.default_header_type = 'b3'
            log_warn_message('configures ' .. plugin.name .. ' plugin with:' ..
                             ' default_header_type == gcp',
                             'overwritten with default value `b3`',
                             dp_version, log_suffix)
            has_update = true
          end
        end
      end

      return has_update
    end,
  },

  { 3004000000, --[[ 3.4.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local has_update

      for _, plugin in ipairs(config_table.plugins or {}) do
        if plugin.name == 'opentelemetry' or plugin.name == 'zipkin' then
          local config = plugin.config
          if config.header_type == 'aws' then
            config.header_type = 'preserve'
            log_warn_message('configures ' .. plugin.name .. ' plugin with:' ..
                             ' header_type == aws',
                             'overwritten with default value `preserve`',
                             dp_version, log_suffix)
            has_update = true
          end
        end

        if plugin.name == 'zipkin' then
          local config = plugin.config
          if config.default_header_type == 'aws' then
            config.default_header_type = 'b3'
            log_warn_message('configures ' .. plugin.name .. ' plugin with:' ..
                             ' default_header_type == aws',
                             'overwritten with default value `b3`',
                             dp_version, log_suffix)
            has_update = true
          end
        end
      end

      return has_update
    end,
  },

  { 3003000000, --[[ 3.3.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local has_update

      -- Support legacy queueing parameters for plugins that used queues prior to 3.3.  `retry_count` has been
      -- completely removed, so we always supply the default of 10 as that provides the same behavior as with a
      -- pre 3.3 CP.  The other queueing related legacy parameters can be determined from the new queue
      -- configuration table.
      for _, plugin in ipairs(config_table.plugins or {}) do
        local config = plugin.config

        if plugin.name == 'statsd' or plugin.name == 'datadog' then
          if type(config.retry_count) ~= "number" then
            config.retry_count = 10
            has_update = true
          end

          if type(config.queue_size) ~= "number" then
            if config.queue and type(config.queue.max_batch_size) == "number" then
              config.queue_size = config.queue.max_batch_size
              has_update = true

            else
              config.queue_size = 1
              has_update = true
            end
          end

          if type(config.flush_timeout) ~= "number" then
            if config.queue and type(config.queue.max_coalescing_delay) == "number" then
              config.flush_timeout = config.queue.max_coalescing_delay
              has_update = true

            else
              config.flush_timeout = 2
              has_update = true
            end
          end

        elseif plugin.name == 'opentelemetry' then

          if type(config.batch_span_count) ~= "number" then
            if config.queue and type(config.queue.max_batch_size) == "number" then
              config.batch_span_count = config.queue.max_batch_size
              has_update = true

            else
              config.batch_span_count = 200
              has_update = true
            end
          end

          if type(config.batch_flush_delay) ~= "number" then
            if config.queue and type(config.queue.max_coalescing_delay) == "number" then
              config.batch_flush_delay = config.queue.max_coalescing_delay
              has_update = true

            else
              config.batch_flush_delay = 3
              has_update = true
            end
          end
        end -- if plugin.name
      end   -- for

      return has_update
    end,
  },

  { 3003000000, --[[ 3.3.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local has_update

      for _, config_entity in ipairs(config_table.vaults or {}) do
        if config_entity.name == "env" and type(config_entity.config) == "table" then
          local config = config_entity.config
          local prefix = config.prefix

          if type(prefix) == "string" then
            local new_prefix = prefix:gsub("-", "_")
            if new_prefix ~= prefix then
              config.prefix = new_prefix
              has_update = true
            end
          end
        end
      end   -- for

      return has_update
    end,
  },

  { 3003000000, --[[ 3.3.0.0 ]]
    function(config_table, dp_version, log_suffix)
      -- remove updated_at field for core entities ca_certificates, certificates, consumers,
      -- targets, upstreams, plugins, workspaces, clustering_data_planes and snis
      local entity_names = {
        "ca_certificates", "certificates", "consumers", "targets", "upstreams",
        "plugins", "workspaces", "snis",
        }

      local has_update
      local updated_entities = {}

      for _, name in ipairs(entity_names) do
        for _, config_entity in ipairs(config_table[name] or {}) do
          if config_entity["updated_at"] then

            config_entity["updated_at"] = nil

            has_update = true

            if not updated_entities[name] then
              log_warn_message("contains configuration '" .. name .. ".updated_at'",
                               "be removed",
                               dp_version,
                               log_suffix)

              updated_entities[name] = true
            end
          end
        end
      end

      return has_update
    end
  },

  { 3002000000, --[[ 3.2.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local config_services = config_table["services"]
      if not config_services  then
        return nil
      end

      local has_update
      for _, t in ipairs(config_services) do
        if t["protocol"] == "tls" then
          if t["client_certificate"] or t["tls_verify"] or
             t["tls_verify_depth"]   or t["ca_certificates"]
          then

            t["client_certificate"] = nil
            t["tls_verify"] = nil
            t["tls_verify_depth"] = nil
            t["ca_certificates"] = nil

            has_update = true
          end
        end
      end

      if has_update then
        log_warn_message("tls protocol service contains configuration 'service.client_certificate'" ..
                         "or 'service.tls_verify' or 'service.tls_verify_depth' or 'service.ca_certificates'",
                         "be removed",
                         dp_version,
                         log_suffix)
      end

      return has_update
    end
  },

  { 3002000000, --[[ 3.2.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local config_upstreams = config_table["upstreams"]
      if not config_upstreams  then
        return nil
      end

      local has_update
      for _, t in ipairs(config_upstreams) do
        if t["algorithm"] == "latency" then
          t["algorithm"] = "round-robin"
          has_update = true
        end
      end

      if has_update then
        log_warn_message("configuration 'upstream.algorithm' contains 'latency' option",
                         "fall back to 'round-robin'",
                         dp_version,
                         log_suffix)
      end

      return has_update
    end
  },

  { 3002000000, --[[ 3.2.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local config_plugins = config_table["plugins"]
      if not config_plugins then
        return nil
      end

      local has_update
      for _, plugin in ipairs(config_plugins) do
        if plugin["instance_name"] ~= nil then
          plugin["instance_name"] = nil
          has_update = true
        end
      end

      if has_update then
        log_warn_message("contains configuration 'plugin.instance_name'",
                         "be removed",
                         dp_version,
                         log_suffix)
      end

      return has_update
    end
  },

  { 3001000000, --[[ 3.1.0.0 ]]
    function(config_table, dp_version, log_suffix)
      local config_upstreams = config_table["upstreams"]
      if not config_upstreams then
        return nil
      end

      local has_update
      for _, t in ipairs(config_upstreams) do
        if t["use_srv_name"] ~= nil then
          t["use_srv_name"] = nil
          has_update = true
        end
      end

      if has_update then
        log_warn_message("contains configuration 'upstream.use_srv_name'",
                         "be removed",
                         dp_version,
                         log_suffix)
      end

      return has_update
    end
  },
}


return compatible_checkers
