local kong_meta = require "kong.meta"
local constants = require "kong.constants"


local type = type
local lower = string.lower


local HEADERS = constants.HEADERS
local BUNDLED_VAULTS = constants.BUNDLED_VAULTS
local BUNDLED_PLUGINS = constants.BUNDLED_PLUGINS
local SOCKETS = constants.SOCKETS


-- Version 5.7: https://wiki.mozilla.org/Security/Server_Side_TLS
local CIPHER_SUITES = {
                   modern = {
                protocols = "TLSv1.3",
                  ciphers = nil,   -- all TLSv1.3 ciphers are considered safe
    prefer_server_ciphers = "off", -- as all are safe, let client choose
  },
             intermediate = {
                protocols = "TLSv1.2 TLSv1.3",
                  ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:"
                         .. "ECDHE-RSA-AES128-GCM-SHA256:"
                         .. "ECDHE-ECDSA-AES256-GCM-SHA384:"
                         .. "ECDHE-RSA-AES256-GCM-SHA384:"
                         .. "ECDHE-ECDSA-CHACHA20-POLY1305:"
                         .. "ECDHE-RSA-CHACHA20-POLY1305:"
                         .. "DHE-RSA-AES128-GCM-SHA256:"
                         .. "DHE-RSA-AES256-GCM-SHA384:"
                         .. "DHE-RSA-CHACHA20-POLY1305",
                 dhparams = "ffdhe2048",
    prefer_server_ciphers = "off",
  },
                      old = {
                protocols = "TLSv1 TLSv1.1 TLSv1.2 TLSv1.3",
                  ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:"
                         .. "ECDHE-RSA-AES128-GCM-SHA256:"
                         .. "ECDHE-ECDSA-AES256-GCM-SHA384:"
                         .. "ECDHE-RSA-AES256-GCM-SHA384:"
                         .. "ECDHE-ECDSA-CHACHA20-POLY1305:"
                         .. "ECDHE-RSA-CHACHA20-POLY1305:"
                         .. "DHE-RSA-AES128-GCM-SHA256:"
                         .. "DHE-RSA-AES256-GCM-SHA384:"
                         .. "DHE-RSA-CHACHA20-POLY1305:"
                         .. "ECDHE-ECDSA-AES128-SHA256:"
                         .. "ECDHE-RSA-AES128-SHA256:"
                         .. "ECDHE-ECDSA-AES128-SHA:"
                         .. "ECDHE-RSA-AES128-SHA:"
                         .. "ECDHE-ECDSA-AES256-SHA384:"
                         .. "ECDHE-RSA-AES256-SHA384:"
                         .. "ECDHE-ECDSA-AES256-SHA:"
                         .. "ECDHE-RSA-AES256-SHA:"
                         .. "DHE-RSA-AES128-SHA256:"
                         .. "DHE-RSA-AES256-SHA256:"
                         .. "AES128-GCM-SHA256:"
                         .. "AES256-GCM-SHA384:"
                         .. "AES128-SHA256:"
                         .. "AES256-SHA256:"
                         .. "AES128-SHA:"
                         .. "AES256-SHA:"
                         .. "DES-CBC3-SHA",
    prefer_server_ciphers = "on",
  },
                     fips = { -- https://wiki.openssl.org/index.php/FIPS_mode_and_TLS
                          -- TLSv1.0 and TLSv1.1 is not completely not FIPS compliant,
                          -- but must be used under certain conditions like key sizes,
                          -- signatures in the full chain that Kong can't control.
                          -- In that case, we disables TLSv1.0 and TLSv1.1 and user
                          -- can optionally turn them on if they are aware of the caveats.
                          -- No FIPS compliant predefined DH group available prior to
                          -- OpenSSL 3.0.
                protocols = "TLSv1.2",
                  ciphers = "TLSv1.2+FIPS:kRSA+FIPS:!eNULL:!aNULL",
    prefer_server_ciphers = "on",
  }
}


local DEFAULT_PATHS = {
  "/etc/kong/kong.conf",
  "/etc/kong.conf",
}


local DEFAULT_PLUGINSERVER_PATH = "/usr/local/bin"


local HEADER_KEY_TO_NAME = {
  ["server_tokens"] = "server_tokens",
  ["latency_tokens"] = "latency_tokens",
  [lower(HEADERS.VIA)] = HEADERS.VIA,
  [lower(HEADERS.SERVER)] = HEADERS.SERVER,
  [lower(HEADERS.PROXY_LATENCY)] = HEADERS.PROXY_LATENCY,
  [lower(HEADERS.RESPONSE_LATENCY)] = HEADERS.RESPONSE_LATENCY,
  [lower(HEADERS.ADMIN_LATENCY)] = HEADERS.ADMIN_LATENCY,
  [lower(HEADERS.UPSTREAM_LATENCY)] = HEADERS.UPSTREAM_LATENCY,
  [lower(HEADERS.UPSTREAM_STATUS)] = HEADERS.UPSTREAM_STATUS,
  [lower(HEADERS.REQUEST_ID)] = HEADERS.REQUEST_ID,
}


local UPSTREAM_HEADER_KEY_TO_NAME = {
  [lower(HEADERS.REQUEST_ID)] = HEADERS.REQUEST_ID,
}


local EMPTY = require("kong.tools.table").EMPTY


-- NOTE! Prefixes should always follow `nginx_[a-z]+_`.
local DYNAMIC_KEY_NAMESPACES = {
  {
    injected_conf_name = "nginx_main_directives",
    prefix = "nginx_main_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_events_directives",
    prefix = "nginx_events_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_http_directives",
    prefix = "nginx_http_",
    ignore = {
      upstream_keepalive          = true,
      upstream_keepalive_timeout  = true,
      upstream_keepalive_requests = true,
      -- we already add it to nginx_kong_inject.lua explicitly
      lua_ssl_protocols           = true,
    },
  },
  {
    injected_conf_name = "nginx_upstream_directives",
    prefix = "nginx_upstream_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_proxy_directives",
    prefix = "nginx_proxy_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_location_directives",
    prefix = "nginx_location_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_status_directives",
    prefix = "nginx_status_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_admin_directives",
    prefix = "nginx_admin_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_stream_directives",
    prefix = "nginx_stream_",
    ignore = {
      -- we already add it to nginx_kong_stream_inject.lua explicitly
      lua_ssl_protocols = true,
    },
  },
  {
    injected_conf_name = "nginx_supstream_directives",
    prefix = "nginx_supstream_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_sproxy_directives",
    prefix = "nginx_sproxy_",
    ignore = EMPTY,
  },
  {
    prefix = "pluginserver_",
    ignore = EMPTY,
  },
  {
    prefix = "vault_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_wasm_wasmtime_directives",
    prefix = "nginx_wasm_wasmtime_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_wasm_v8_directives",
    prefix = "nginx_wasm_v8_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_wasm_wasmer_directives",
    prefix = "nginx_wasm_wasmer_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_wasm_main_shm_kv_directives",
    prefix = "nginx_wasm_shm_kv_",
    ignore = EMPTY,
  },
  {
    injected_conf_name = "nginx_wasm_main_directives",
    prefix = "nginx_wasm_",
    ignore = EMPTY,
  },
}


local DEPRECATED_DYNAMIC_KEY_NAMESPACES = {}


local PREFIX_PATHS = {
  nginx_pid = {"pids", "nginx.pid"},
  nginx_err_logs = {"logs", "error.log"},
  nginx_acc_logs = {"logs", "access.log"},
  admin_acc_logs = {"logs", "admin_access.log"},
  nginx_conf = {"nginx.conf"},
  nginx_kong_gui_include_conf = {"nginx-kong-gui-include.conf"},
  nginx_kong_conf = {"nginx-kong.conf"},
  nginx_kong_stream_conf = {"nginx-kong-stream.conf"},
  nginx_inject_conf = {"nginx-inject.conf"},
  nginx_kong_inject_conf = {"nginx-kong-inject.conf"},
  nginx_kong_stream_inject_conf = {"nginx-kong-stream-inject.conf"},

  kong_env = {".kong_env"},
  kong_process_secrets = {".kong_process_secrets"},

  ssl_cert_csr_default = {"ssl", "kong-default.csr"},
  ssl_cert_default = {"ssl", "kong-default.crt"},
  ssl_cert_key_default = {"ssl", "kong-default.key"},
  ssl_cert_default_ecdsa = {"ssl", "kong-default-ecdsa.crt"},
  ssl_cert_key_default_ecdsa = {"ssl", "kong-default-ecdsa.key"},

  client_ssl_cert_default = {"ssl", "kong-default.crt"},
  client_ssl_cert_key_default = {"ssl", "kong-default.key"},

  admin_ssl_cert_default = {"ssl", "admin-kong-default.crt"},
  admin_ssl_cert_key_default = {"ssl", "admin-kong-default.key"},
  admin_ssl_cert_default_ecdsa = {"ssl", "admin-kong-default-ecdsa.crt"},
  admin_ssl_cert_key_default_ecdsa = {"ssl", "admin-kong-default-ecdsa.key"},

  admin_gui_ssl_cert_default = {"ssl", "admin-gui-kong-default.crt"},
  admin_gui_ssl_cert_key_default = {"ssl", "admin-gui-kong-default.key"},
  admin_gui_ssl_cert_default_ecdsa = {"ssl", "admin-gui-kong-default-ecdsa.crt"},
  admin_gui_ssl_cert_key_default_ecdsa = {"ssl", "admin-gui-kong-default-ecdsa.key"},

  status_ssl_cert_default = {"ssl", "status-kong-default.crt"},
  status_ssl_cert_key_default = {"ssl", "status-kong-default.key"},
  status_ssl_cert_default_ecdsa = {"ssl", "status-kong-default-ecdsa.crt"},
  status_ssl_cert_key_default_ecdsa = {"ssl", "status-kong-default-ecdsa.key"},
}


-- By default, all properties in the configuration are considered to
-- be strings/numbers, but if we want to forcefully infer their type, specify it
-- in this table.
-- Also holds "enums" which are lists of valid configuration values for some
-- settings.
-- See `typ_checks` for the validation function of each type.
--
-- Types:
-- `boolean`: can be "on"/"off"/"true"/"false", will be inferred to a boolean
-- `ngx_boolean`: can be "on"/"off", will be inferred to a string
-- `array`: a comma-separated list
local CONF_PARSERS = {
  -- forced string inferences (or else are retrieved as numbers)
  port_maps = { typ = "array" },
  proxy_listen = { typ = "array" },
  admin_listen = { typ = "array" },
  admin_gui_listen = {typ = "array"},
  status_listen = { typ = "array" },
  stream_listen = { typ = "array" },
  cluster_listen = { typ = "array" },
  ssl_cert = { typ = "array" },
  ssl_cert_key = { typ = "array" },
  admin_ssl_cert = { typ = "array" },
  admin_ssl_cert_key = { typ = "array" },
  admin_gui_ssl_cert = { typ = "array" },
  admin_gui_ssl_cert_key = { typ = "array" },
  status_ssl_cert = { typ = "array" },
  status_ssl_cert_key = { typ = "array" },
  db_update_frequency = {  typ = "number"  },
  db_update_propagation = {  typ = "number"  },
  db_cache_ttl = {  typ = "number"  },
  db_cache_neg_ttl = {  typ = "number"  },
  db_resurrect_ttl = {  typ = "number"  },
  db_cache_warmup_entities = { typ = "array" },
  nginx_user = {
    typ = "string",
    alias = {
      replacement = "nginx_main_user",
    }
  },
  nginx_daemon = {
    typ = "ngx_boolean",
    alias = {
      replacement = "nginx_main_daemon",
    }
  },
  nginx_worker_processes = {
    typ = "string",
    alias = {
      replacement = "nginx_main_worker_processes",
    },
  },

  nginx_wasm_main_shm_kv = { typ = "string" },

  worker_events_max_payload = { typ = "number" },

  upstream_keepalive_pool_size = { typ = "number" },
  upstream_keepalive_max_requests = { typ = "number" },
  upstream_keepalive_idle_timeout = { typ = "number" },
  allow_debug_header = { typ = "boolean" },

  headers = { typ = "array" },
  headers_upstream = { typ = "array" },
  trusted_ips = { typ = "array" },
  real_ip_header = {
    typ = "string",
    alias = {
      replacement = "nginx_proxy_real_ip_header",
    }
  },
  real_ip_recursive = {
    typ = "ngx_boolean",
    alias = {
      replacement = "nginx_proxy_real_ip_recursive",
    }
  },
  error_default_type = { enum = {
                           "application/json",
                           "application/xml",
                           "text/html",
                           "text/plain",
                         }
                       },

  database = { enum = { "postgres", "cassandra", "off" }  },
  pg_port = { typ = "number" },
  pg_timeout = { typ = "number" },
  pg_password = { typ = "string" },
  pg_ssl = { typ = "boolean" },
  pg_ssl_verify = { typ = "boolean" },
  pg_max_concurrent_queries = { typ = "number" },
  pg_semaphore_timeout = { typ = "number" },
  pg_keepalive_timeout = { typ = "number" },
  pg_pool_size = { typ = "number" },
  pg_backlog = { typ = "number" },
  _debug_pg_ttl_cleanup_interval = { typ = "number" },

  pg_ro_port = { typ = "number" },
  pg_ro_timeout = { typ = "number" },
  pg_ro_password = { typ = "string" },
  pg_ro_ssl = { typ = "boolean" },
  pg_ro_ssl_verify = { typ = "boolean" },
  pg_ro_max_concurrent_queries = { typ = "number" },
  pg_ro_semaphore_timeout = { typ = "number" },
  pg_ro_keepalive_timeout = { typ = "number" },
  pg_ro_pool_size = { typ = "number" },
  pg_ro_backlog = { typ = "number" },

  dns_resolver = { typ = "array" },
  dns_hostsfile = { typ = "string" },
  dns_order = { typ = "array" },
  dns_valid_ttl = { typ = "number" },
  dns_stale_ttl = { typ = "number" },
  dns_cache_size = { typ = "number" },
  dns_not_found_ttl = { typ = "number" },
  dns_error_ttl = { typ = "number" },
  dns_no_sync = { typ = "boolean" },

  new_dns_client = { typ = "boolean" },

  resolver_address = { typ = "array" },
  resolver_hosts_file = { typ = "string" },
  resolver_family = { typ = "array" },
  resolver_valid_ttl = { typ = "number" },
  resolver_stale_ttl = { typ = "number" },
  resolver_error_ttl = { typ = "number" },
  resolver_lru_cache_size = { typ = "number" },

  privileged_worker = {
    typ = "boolean",
    deprecated = {
      replacement = "dedicated_config_processing",
      alias = function(conf)
        if conf.dedicated_config_processing == nil and
           conf.privileged_worker ~= nil then
          conf.dedicated_config_processing = conf.privileged_worker
        end
      end,
  }},
  dedicated_config_processing = { typ = "boolean" },
  worker_consistency = { enum = { "strict", "eventual" },
    -- deprecating values for enums
    deprecated = {
      value = "strict",
     }
  },
  router_consistency = {
    enum = { "strict", "eventual" },
    deprecated = {
      replacement = "worker_consistency",
      alias = function(conf)
        if conf.worker_consistency == nil and
           conf.router_consistency ~= nil then
          conf.worker_consistency = conf.router_consistency
        end
      end,
    }
  },
  router_flavor = {
    enum = { "traditional", "traditional_compatible", "expressions" },
  },
  worker_state_update_frequency = { typ = "number" },

  lua_max_req_headers = { typ = "number" },
  lua_max_resp_headers = { typ = "number" },
  lua_max_uri_args = { typ = "number" },
  lua_max_post_args = { typ = "number" },

  ssl_protocols = {
    typ = "string",
    directives = {
      "nginx_http_ssl_protocols",
      "nginx_stream_ssl_protocols",
    },
  },
  ssl_prefer_server_ciphers = {
    typ = "ngx_boolean",
    directives = {
      "nginx_http_ssl_prefer_server_ciphers",
      "nginx_stream_ssl_prefer_server_ciphers",
    },
  },
  ssl_dhparam = {
    typ = "string",
    directives = {
      "nginx_http_ssl_dhparam",
      "nginx_stream_ssl_dhparam",
    },
  },
  ssl_session_tickets = {
    typ = "ngx_boolean",
    directives = {
      "nginx_http_ssl_session_tickets",
      "nginx_stream_ssl_session_tickets",
    },
  },
  ssl_session_timeout = {
    typ = "string",
    directives = {
      "nginx_http_ssl_session_timeout",
      "nginx_stream_ssl_session_timeout",
    },
  },
  ssl_session_cache_size = { typ = "string" },

  client_ssl = { typ = "boolean" },

  proxy_access_log = { typ = "string" },
  proxy_error_log = { typ = "string" },
  proxy_stream_access_log = { typ = "string" },
  proxy_stream_error_log = { typ = "string" },
  admin_access_log = { typ = "string" },
  admin_error_log = { typ = "string" },
  admin_gui_access_log = {typ = "string"},
  admin_gui_error_log = {typ = "string"},
  status_access_log = { typ = "string" },
  status_error_log = { typ = "string" },
  log_level = { enum = {
                  "debug",
                  "info",
                  "notice",
                  "warn",
                  "error",
                  "crit",
                  "alert",
                  "emerg",
                }
              },
  vaults = { typ = "array" },
  plugins = { typ = "array" },
  anonymous_reports = { typ = "boolean" },

  lua_ssl_trusted_certificate = { typ = "array" },
  lua_ssl_verify_depth = { typ = "number" },
  lua_ssl_protocols = {
    typ = "string",
    directives = {
      "nginx_http_lua_ssl_protocols",
      "nginx_stream_lua_ssl_protocols",
    },
  },
  lua_socket_pool_size = { typ = "number" },

  role = { enum = { "data_plane", "control_plane", "traditional", }, },
  cluster_control_plane = { typ = "string", },
  cluster_cert = { typ = "string" },
  cluster_cert_key = { typ = "string" },
  cluster_mtls = { enum = { "shared", "pki" } },
  cluster_ca_cert = { typ = "string" },
  cluster_server_name = { typ = "string" },
  cluster_data_plane_purge_delay = { typ = "number" },
  cluster_ocsp = { enum = { "on", "off", "optional" } },
  cluster_max_payload = { typ = "number" },
  cluster_use_proxy = { typ = "boolean" },
  cluster_dp_labels = { typ = "array" },
  cluster_rpc = { typ = "boolean" },
  cluster_rpc_sync = { typ = "boolean" },
  cluster_cjson = { typ = "boolean" },

  kic = { typ = "boolean" },
  pluginserver_names = { typ = "array" },

  untrusted_lua = { enum = { "on", "off", "sandbox" } },
  untrusted_lua_sandbox_requires = { typ = "array" },
  untrusted_lua_sandbox_environment = { typ = "array" },

  lmdb_environment_path = { typ = "string" },
  lmdb_map_size = { typ = "string" },

  opentelemetry_tracing = {
    typ = "array",
    alias = {
      replacement = "tracing_instrumentations",
    },
    deprecated = {
      replacement = "tracing_instrumentations",
    },
  },

  tracing_instrumentations = {
    typ = "array",
  },

  opentelemetry_tracing_sampling_rate = {
    typ = "number",
    deprecated = {
      replacement = "tracing_sampling_rate",
    },
    alias = {
      replacement = "tracing_sampling_rate",
    },
  },

  tracing_sampling_rate = {
    typ = "number",
  },

  proxy_server = { typ = "string" },
  proxy_server_ssl_verify = { typ = "boolean" },

  wasm = { typ = "boolean" },
  wasm_filters_path = { typ = "string" },
  wasm_filters = { typ = "array" },

  error_template_html = { typ = "string" },
  error_template_json = { typ = "string" },
  error_template_xml = { typ = "string" },
  error_template_plain = { typ = "string" },

  admin_gui_url = { typ = "array" },
  admin_gui_path = { typ = "string" },
  admin_gui_api_url = { typ = "string" },
  admin_gui_csp_header = { typ = "boolean" },

  request_debug = { typ = "boolean" },
  request_debug_token = { typ = "string" },
}


-- List of settings whose values must not be printed when
-- using the CLI in debug mode (which prints all settings).
local CONF_SENSITIVE_PLACEHOLDER = "******"
local CONF_SENSITIVE = {
  pg_password = true,
  pg_ro_password = true,
  proxy_server = true, -- hide proxy server URL as it may contain credentials
  declarative_config_string = true, -- config may contain sensitive info
  -- may contain absolute or base64 value of the key
  cluster_cert_key = true,
  ssl_cert_key = true,
  client_ssl_cert_key = true,
  admin_ssl_cert_key = true,
  admin_gui_ssl_cert_key = true,
  status_ssl_cert_key = true,
  debug_ssl_cert_key = true,
  ["$refs"] = true, -- for internal use only, no need to log
}


-- List of confs necessary for compiling injected nginx conf
local CONF_BASIC = {
  prefix = true,
  vaults = true,
  database = true,
  lmdb_environment_path = true,
  lmdb_map_size = true,
  lua_ssl_trusted_certificate = true,
  lua_ssl_verify_depth = true,
  lua_ssl_protocols = true,
  nginx_http_lua_ssl_protocols = true,
  nginx_stream_lua_ssl_protocols = true,
  vault_env_prefix = true,
}


local TYP_CHECKS = {
  array = function(v) return type(v) == "table" end,
  string = function(v) return type(v) == "string" end,
  number = function(v) return type(v) == "number" end,
  boolean = function(v) return type(v) == "boolean" end,
  ngx_boolean = function(v) return v == "on" or v == "off" end,
}


-- This meta table will prevent the parsed table to be passed on in the
-- intermediate Kong config file in the prefix directory.
-- We thus avoid 'table: 0x41c3fa58' from appearing into the prefix
-- hidden configuration file.
-- This is only to be applied to values that are injected into the
-- configuration object, and not configuration properties themselves,
-- otherwise we would prevent such properties from being specifiable
-- via environment variables.
local _NOP_TOSTRING_MT = {
  __tostring = function() return "" end,
}


-- using kong version, "major.minor"
local LMDB_VALIDATION_TAG = string.format("%d.%d",
                                          kong_meta._VERSION_TABLE.major,
                                          kong_meta._VERSION_TABLE.minor)


return {
  HEADERS = HEADERS,
  BUNDLED_VAULTS = BUNDLED_VAULTS,
  BUNDLED_PLUGINS = BUNDLED_PLUGINS,
  SOCKETS = SOCKETS,

  CIPHER_SUITES = CIPHER_SUITES,
  DEFAULT_PATHS = DEFAULT_PATHS,
  DEFAULT_PLUGINSERVER_PATH = DEFAULT_PLUGINSERVER_PATH,
  HEADER_KEY_TO_NAME = HEADER_KEY_TO_NAME,
  UPSTREAM_HEADER_KEY_TO_NAME = UPSTREAM_HEADER_KEY_TO_NAME,
  DYNAMIC_KEY_NAMESPACES = DYNAMIC_KEY_NAMESPACES,
  DEPRECATED_DYNAMIC_KEY_NAMESPACES = DEPRECATED_DYNAMIC_KEY_NAMESPACES,
  PREFIX_PATHS = PREFIX_PATHS,
  CONF_PARSERS = CONF_PARSERS,
  CONF_SENSITIVE_PLACEHOLDER = CONF_SENSITIVE_PLACEHOLDER,
  CONF_SENSITIVE = CONF_SENSITIVE,
  CONF_BASIC = CONF_BASIC,
  TYP_CHECKS = TYP_CHECKS,

  _NOP_TOSTRING_MT = _NOP_TOSTRING_MT,

  LMDB_VALIDATION_TAG = LMDB_VALIDATION_TAG,

  WASM_BUNDLED_FILTERS_PATH = "/usr/local/kong/wasm",
}
