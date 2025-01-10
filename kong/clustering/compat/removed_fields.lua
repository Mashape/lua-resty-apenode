return {
  -- Any dataplane older than 3.1.0
  [3001000000] = {
    -- OSS
    acme = {
      "enable_ipv4_common_name",
      "storage_config.redis.ssl",
      "storage_config.redis.ssl_verify",
      "storage_config.redis.ssl_server_name",
    },
    rate_limiting = {
      "error_code",
      "error_message",
    },
    response_ratelimiting = {
      "redis_ssl",
      "redis_ssl_verify",
      "redis_server_name",
    },
    datadog = {
      "retry_count",
      "queue_size",
      "flush_timeout",
    },
    statsd = {
      "retry_count",
      "queue_size",
      "flush_timeout",
    },
    session = {
      "cookie_persistent",
    },
    zipkin = {
      "http_response_header_for_traceid",
    },
  },
  -- Any dataplane older than 3.2.0
  [3002000000] = {
    statsd = {
      "tag_style",
    },
    session = {
      "audience",
      "absolute_timeout",
      "remember_cookie_name",
      "remember_rolling_timeout",
      "remember_absolute_timeout",
      "response_headers",
      "request_headers",
    },
    aws_lambda = {
      "aws_imds_protocol_version",
    },
    zipkin = {
      "phase_duration_flavor",
    }
  },

  -- Any dataplane older than 3.3.0
  [3003000000] = {
    acme = {
      "account_key",
      "storage_config.redis.namespace",
    },
    aws_lambda = {
      "disable_https",
    },
    proxy_cache = {
      "ignore_uri_case",
    },
    opentelemetry = {
      "http_response_header_for_traceid",
      "queue",
      "header_type",
    },
    http_log = {
      "queue",
    },
    statsd = {
      "queue",
    },
    datadog = {
      "queue",
    },
    zipkin = {
      "queue",
    },
  },

  -- Any dataplane older than 3.4.0
  [3004000000] = {
    rate_limiting = {
      "sync_rate",
    },
    proxy_cache = {
      "response_headers",
    },
  },

  -- Any dataplane older than 3.5.0
  [3005000000] = {
    acme = {
      "storage_config.redis.scan_count",
    },
    cors = {
      "private_network",
    },
    session = {
      "read_body_for_logout",
    },
  },

  -- Any dataplane older than 3.6.0
  [3006000000] = {
    opentelemetry = {
      "sampling_rate",
    },
    basic_auth = {
      "realm"
    }
  },

  -- Any dataplane older than 3.7.0
  [3007000000] = {
    opentelemetry = {
      "propagation",
    },
    zipkin = {
      "propagation",
    },
    ai_proxy = {
      "response_streaming",
      "model.options.upstream_path",
    },
    ai_request_transformer = {
      "llm.model.options.upstream_path",
    },
    ai_response_transformer = {
      "llm.model.options.upstream_path",
    },
    key_auth = {
      "realm"
    },
  },

  -- Any dataplane older than 3.8.0
  [3008000000] = {
    response_transformer = {
      "rename.json",
    },
    aws_lambda = {
      "empty_arrays_mode",
    },
    ldap_auth = {
      "realm",
    },
    hmac_auth = {
      "realm",
    },
    jwt = {
      "realm",
    },
    oauth2 = {
      "realm",
    },
    opentelemetry = {
      "traces_endpoint",
      "logs_endpoint",
      "queue.concurrency_limit",
    },
    ai_proxy = {
      "max_request_body_size",
      "model.options.gemini",
      "auth.gcp_use_service_account",
      "auth.gcp_service_account_json",
      "model.options.bedrock",
      "auth.aws_access_key_id",
      "auth.aws_secret_access_key",
      "auth.allow_override",
      "model_name_header",
    },
    ai_prompt_decorator = {
      "max_request_body_size",
    },
    ai_prompt_guard = {
      "match_all_roles",
      "max_request_body_size",
    },
    ai_prompt_template = {
      "max_request_body_size",
    },
    ai_request_transformer = {
      "max_request_body_size",
      "llm.model.options.gemini",
      "llm.auth.gcp_use_service_account",
      "llm.auth.gcp_service_account_json",
      "llm.model.options.bedrock",
      "llm.auth.aws_access_key_id",
      "llm.auth.aws_secret_access_key",
      "llm.auth.allow_override",
    },
    ai_response_transformer = {
      "max_request_body_size",
      "llm.model.options.gemini",
      "llm.auth.gcp_use_service_account",
      "llm.auth.gcp_service_account_json",
      "llm.model.options.bedrock",
      "llm.auth.aws_access_key_id",
      "llm.auth.aws_secret_access_key",
      "llm.auth.allow_override",
    },
    prometheus = {
      "ai_metrics",
    },
    acl = {
      "always_use_authenticated_groups",
    },
    http_log = {
      "queue.concurrency_limit",
    },
    statsd = {
      "queue.concurrency_limit",
    },
    datadog = {
      "queue.concurrency_limit",
    },
    zipkin = {
      "queue.concurrency_limit",
    },
  },

  -- Any dataplane older than 3.9.0
  [3009000000] = {
    prometheus = {
      "wasm_metrics",
    },
  },
}
