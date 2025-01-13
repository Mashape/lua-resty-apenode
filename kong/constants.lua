local plugins = {
  "jwt",
  "acl",
  "correlation-id",
  "cors",
  "oauth2",
  "tcp-log",
  "udp-log",
  "file-log",
  "http-log",
  "key-auth",
  "hmac-auth",
  "basic-auth",
  "ip-restriction",
  "request-transformer",
  "response-transformer",
  "request-size-limiting",
  "rate-limiting",
  "response-ratelimiting",
  "syslog",
  "loggly",
  "datadog",
  "ldap-auth",
  "statsd",
  "bot-detection",
  "aws-lambda",
  "request-termination",
  "prometheus",
  "proxy-cache",
  "session",
  "acme",
  "grpc-gateway",
  "grpc-web",
  "pre-function",
  "post-function",
  "azure-functions",
  "zipkin",
  "opentelemetry",
  "ai-proxy",
  "ai-prompt-decorator",
  "ai-prompt-template",
  "ai-prompt-guard",
  "ai-request-transformer",
  "ai-response-transformer",
  "standard-webhooks",
  "redirect",
  "remote-auth",
}

local plugin_map = {}
for i = 1, #plugins do
  plugin_map[plugins[i]] = true
end

local deprecated_plugins = {} -- no currently deprecated plugin

local deprecated_plugin_map = {}
for _, plugin in ipairs(deprecated_plugins) do
  deprecated_plugin_map[plugin] = true
end

local vaults = {
  "env",
}

local vault_map = {}
for i = 1, #vaults do
  vault_map[vaults[i]] = true
end

local deprecated_vaults = {} -- no currently deprecated vaults

local deprecated_vault_map = {}
for _, vault in ipairs(deprecated_vaults) do
  deprecated_vault_map[vault] = true
end

local protocols_with_subsystem = {
  http = "http",
  https = "http",
  tcp = "stream",
  tls = "stream",
  udp = "stream",
  tls_passthrough = "stream",
  grpc = "http",
  grpcs = "http",
}
local protocols = {}
for p,_ in pairs(protocols_with_subsystem) do
  protocols[#protocols + 1] = p
end
table.sort(protocols)

local key_formats_map = {
  ["jwk"] = true,
  ["pem"] = true,
}
local key_formats = {}
for k in pairs(key_formats_map) do
  key_formats[#key_formats + 1] = k
end

local constants = {
  CJSON_MAX_PRECISION = 16,
  BUNDLED_PLUGINS = plugin_map,
  DEPRECATED_PLUGINS = deprecated_plugin_map,
  BUNDLED_VAULTS = vault_map,
  DEPRECATED_VAULTS = deprecated_vault_map,
  -- non-standard headers, specific to Kong
  HEADERS = {
    HOST_OVERRIDE = "X-Host-Override",
    PROXY_LATENCY = "X-Kong-Proxy-Latency",
    RESPONSE_LATENCY = "X-Kong-Response-Latency",
    ADMIN_LATENCY = "X-Kong-Admin-Latency",
    UPSTREAM_LATENCY = "X-Kong-Upstream-Latency",
    UPSTREAM_STATUS = "X-Kong-Upstream-Status",
    CONSUMER_ID = "X-Consumer-ID",
    CONSUMER_CUSTOM_ID = "X-Consumer-Custom-ID",
    CONSUMER_USERNAME = "X-Consumer-Username",
    CREDENTIAL_IDENTIFIER = "X-Credential-Identifier",
    RATELIMIT_LIMIT = "X-RateLimit-Limit",
    RATELIMIT_REMAINING = "X-RateLimit-Remaining",
    CONSUMER_GROUPS = "X-Consumer-Groups",
    AUTHENTICATED_GROUPS = "X-Authenticated-Groups",
    FORWARDED_HOST = "X-Forwarded-Host",
    FORWARDED_PATH = "X-Forwarded-Path",
    FORWARDED_PREFIX = "X-Forwarded-Prefix",
    ANONYMOUS = "X-Anonymous-Consumer",
    REQUEST_ID = "X-Kong-Request-Id",
    VIA = "Via",
    SERVER = "Server"
  },
  -- Notice that the order in which they are listed is important:
  -- schemas of dependencies need to be loaded first.
  --
  -- This table doubles as a set (e.g. CORE_ENTITIES["routes"] = true)
  -- (see below where the set entries are populated)
  CORE_ENTITIES = {
    "workspaces",
    "consumers",
    "certificates",
    "services",
    "routes",
    "snis",
    "upstreams",
    "targets",
    "plugins",
    "tags",
    "ca_certificates",
    "clustering_data_planes",
    "parameters",
    "vaults",
    "key_sets",
    "keys",
    "filter_chains",
  },
  ENTITY_CACHE_STORE = setmetatable({
    consumers = "cache",
    certificates = "core_cache",
    services = "core_cache",
    routes = "core_cache",
    snis = "core_cache",
    upstreams = "core_cache",
    targets = "core_cache",
    plugins = "core_cache",
    tags = "cache",
    ca_certificates = "core_cache",
    vaults = "core_cache",
    key_sets = "core_cache",
    keys = "core_cache",
  }, {
    __index = function()
      return "cache"
    end
  }),
  RATELIMIT = {
    PERIODS = {
      "second",
      "minute",
      "hour",
      "day",
      "month",
      "year"
    }
  },
  REPORTS = {
    ADDRESS = "kong-hf.konghq.com",
    STATS_TLS_PORT = 61833,
  },
  DICTS = {
    "kong",
    "kong_locks",
    "kong_db_cache",
    "kong_db_cache_miss",
    "kong_cluster_events",
    "kong_healthchecks",
    "kong_rate_limiting_counters",
    "kong_secrets",
  },
  DATABASE = {
    POSTGRES = {
      MIN = "9.5",
    },
    -- a bit over three years maximum to make it more safe against
    -- integer overflow (time() + ttl)
    DAO_MAX_TTL = 1e8,
  },
  PROTOCOLS = protocols,
  PROTOCOLS_WITH_SUBSYSTEM = protocols_with_subsystem,

  DECLARATIVE_DEFAULT_WORKSPACE_ID = "0dc6f45b-8f8d-40d2-a504-473544ee190b",

  DECLARATIVE_LOAD_KEY = "declarative_config:loaded",
  DECLARATIVE_HASH_KEY = "declarative_config:hash",
  DECLARATIVE_DEFAULT_WORKSPACE_KEY = "declarative_config:default_workspace",
  PLUGINS_REBUILD_COUNTER_KEY = "readiness_probe_config:plugins_rebuild_counter",
  ROUTERS_REBUILD_COUNTER_KEY = "readiness_probe_config:routers_rebuild_counter",
  DECLARATIVE_EMPTY_CONFIG_HASH = string.rep("0", 32),

  CLUSTER_ID_PARAM_KEY = "cluster_id",

  CLUSTERING_SYNC_STATUS = {
    { UNKNOWN                     = "unknown", },
    { NORMAL                      = "normal", },
    { KONG_VERSION_INCOMPATIBLE   = "kong_version_incompatible", },
    { PLUGIN_SET_INCOMPATIBLE     = "plugin_set_incompatible", },
    { PLUGIN_VERSION_INCOMPATIBLE = "plugin_version_incompatible", },
    { FILTER_SET_INCOMPATIBLE     = "filter_set_incompatible", },
  },
  CLUSTERING_TIMEOUT = 5000, -- 5 seconds
  CLUSTERING_PING_INTERVAL = 30, -- 30 seconds
  CLUSTERING_OCSP_TIMEOUT = 5000, -- 5 seconds
  CLUSTERING_DATA_PLANE_ERROR = {
    CONFIG_PARSE     = "declarative configuration parse failure",
    RELOAD           = "configuration reload failed",
    GENERIC          = "generic or unknown error",
  },
  CLUSTERING_DATA_PLANES_LATEST_VERSION_KEY = "clustering_data_planes:latest_version",

  CLEAR_HEALTH_STATUS_DELAY = 300, -- 300 seconds

  KEY_FORMATS_MAP = key_formats_map,
  KEY_FORMATS = key_formats,

  LOG_LEVELS = {
    debug = ngx.DEBUG,
    info = ngx.INFO,
    notice = ngx.NOTICE,
    warn = ngx.WARN,
    error = ngx.ERR,
    crit = ngx.CRIT,
    alert = ngx.ALERT,
    emerg = ngx.EMERG,
    [ngx.DEBUG] = "debug",
    [ngx.INFO] = "info",
    [ngx.NOTICE] = "notice",
    [ngx.WARN] = "warn",
    [ngx.ERR] = "error",
    [ngx.CRIT] = "crit",
    [ngx.ALERT] = "alert",
    [ngx.EMERG] = "emerg",
  },

  DYN_LOG_LEVEL_KEY = "kong:dyn_log_level",
  DYN_LOG_LEVEL_TIMEOUT_AT_KEY = "kong:dyn_log_level_timeout_at",
  DYN_LOG_LEVEL_DEFAULT_TIMEOUT = 60,

  ADMIN_GUI_KCONFIG_CACHE_KEY = "admin:gui:kconfig",

  REQUEST_DEBUG_TOKEN_FILE = ".request_debug_token",
  REQUEST_DEBUG_LOG_PREFIX = "[request-debug]",

  SCHEMA_NAMESPACES = {
    PROXY_WASM_FILTERS = "proxy-wasm-filters",
  },

  RESPONSE_SOURCE = {
    TYPES = {
      ERROR = "error",
      EXIT = "exit",
      SERVICE = "service",
    },
    NAMES = {
      error = "kong",
      exit = "kong",
      service = "upstream",
    }
  },

  SOCKET_DIRECTORY = "sockets",
  SOCKETS = {
    WORKER_EVENTS = "we",
    STREAM_WORKER_EVENTS = "sw",
    CLUSTER_PROXY_SSL_TERMINATOR = "cp",
    STREAM_CONFIG = "sc",
    STREAM_TLS_TERMINATE = "st",
    STREAM_TLS_PASSTHROUGH = "sp",
    STREAM_RPC = "rp",
  },
}

for _, v in ipairs(constants.CLUSTERING_SYNC_STATUS) do
  local k, v = next(v)
  constants.CLUSTERING_SYNC_STATUS[k] = v
end

-- Make the CORE_ENTITIES table usable both as an ordered array and as a set
for _, v in ipairs(constants.CORE_ENTITIES) do
  constants.CORE_ENTITIES[v] = true
end

return constants
