local balancer = require "kong.runloop.balancer"
local yield = require("kong.tools.yield").yield
local wasm = require "kong.plugins.prometheus.wasmx"


local kong = kong
local ngx = ngx
local get_phase = ngx.get_phase
local lower = string.lower
local ngx_timer_pending_count = ngx.timer.pending_count
local ngx_timer_running_count = ngx.timer.running_count
local get_all_upstreams = balancer.get_all_upstreams
if not balancer.get_all_upstreams then -- API changed since after Kong 2.5
  get_all_upstreams = require("kong.runloop.balancer.upstreams").get_all_upstreams
end

local CLUSTERING_SYNC_STATUS = require("kong.constants").CLUSTERING_SYNC_STATUS

local stream_available, stream_api = pcall(require, "kong.tools.stream_api")

local role = kong.configuration.role

local KONG_LATENCY_BUCKETS = { 1, 2, 5, 7, 10, 15, 20, 30, 50, 75, 100, 200, 500, 750, 1000, 3000, 6000 }
local UPSTREAM_LATENCY_BUCKETS = { 25, 50, 80, 100, 250, 400, 700, 1000, 2000, 5000, 10000, 30000, 60000 }
local AI_LLM_PROVIDER_LATENCY_BUCKETS = { 250, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 10000, 30000, 60000 }
local IS_PROMETHEUS_ENABLED


local metrics = {}
-- prometheus.lua instance
local prometheus
local node_id = kong.node.get_id()

-- use the same counter library shipped with Kong
package.loaded['prometheus_resty_counter'] = require("resty.counter")


local kong_subsystem = ngx.config.subsystem
local http_subsystem = kong_subsystem == "http"

local function init()
  local shm = "prometheus_metrics"
  if not ngx.shared[shm] then
    kong.log.err("prometheus: ngx shared dict 'prometheus_metrics' not found")
    return
  end

  prometheus = require("kong.plugins.prometheus.prometheus").init(shm, "kong_")

  -- global metrics
  metrics.connections = prometheus:gauge("nginx_connections_total",
    "Number of connections by subsystem",
    {"node_id", "subsystem", "state"},
    prometheus.LOCAL_STORAGE)
  metrics.nginx_requests_total = prometheus:gauge("nginx_requests_total",
      "Number of requests total", {"node_id", "subsystem"},
      prometheus.LOCAL_STORAGE)
  metrics.timers = prometheus:gauge("nginx_timers",
                                    "Number of nginx timers",
                                    {"state"},
                                    prometheus.LOCAL_STORAGE)
  metrics.db_reachable = prometheus:gauge("datastore_reachable",
                                          "Datastore reachable from Kong, " ..
                                          "0 is unreachable",
                                          nil,
                                          prometheus.LOCAL_STORAGE)
  metrics.node_info = prometheus:gauge("node_info",
                                       "Kong Node metadata information",
                                       {"node_id", "version"},
                                       prometheus.LOCAL_STORAGE)
  metrics.node_info:set(1, {node_id, kong.version})
  -- only export upstream health metrics in traditional mode and data plane
  if role ~= "control_plane" then
    metrics.upstream_target_health = prometheus:gauge("upstream_target_health",
                                            "Health status of targets of upstream. " ..
                                            "States = healthchecks_off|healthy|unhealthy|dns_error, " ..
                                            "value is 1 when state is populated.",
                                            {"upstream", "target", "address", "state", "subsystem"},
                                            prometheus.LOCAL_STORAGE)
  end

  local memory_stats = {}
  memory_stats.worker_vms = prometheus:gauge("memory_workers_lua_vms_bytes",
                                             "Allocated bytes in worker Lua VM",
                                             {"node_id", "pid", "kong_subsystem"},
                                             prometheus.LOCAL_STORAGE)
  memory_stats.shms = prometheus:gauge("memory_lua_shared_dict_bytes",
                                             "Allocated slabs in bytes in a shared_dict",
                                             {"node_id", "shared_dict", "kong_subsystem"},
                                             prometheus.LOCAL_STORAGE)
  memory_stats.shm_capacity = prometheus:gauge("memory_lua_shared_dict_total_bytes",
                                                     "Total capacity in bytes of a shared_dict",
                                                     {"node_id", "shared_dict", "kong_subsystem"},
                                                     prometheus.LOCAL_STORAGE)

  local res = kong.node.get_memory_stats()
  for shm_name, value in pairs(res.lua_shared_dicts) do
    memory_stats.shm_capacity:set(value.capacity, { node_id, shm_name, kong_subsystem })
  end

  metrics.memory_stats = memory_stats

  -- per service/route
  if http_subsystem then
    metrics.status = prometheus:counter("http_requests_total",
                                        "HTTP status codes per consumer/service/route in Kong",
                                        {"service", "route", "code", "source", "workspace", "consumer"})
  else
    metrics.status = prometheus:counter("stream_sessions_total",
                                        "Stream status codes per service/route in Kong",
                                        {"service", "route", "code", "source", "workspace"})
  end
  metrics.kong_latency = prometheus:histogram("kong_latency_ms",
                                              "Latency added by Kong and enabled plugins " ..
                                              "for each service/route in Kong",
                                              {"service", "route", "workspace"},
                                              KONG_LATENCY_BUCKETS)
  metrics.upstream_latency = prometheus:histogram("upstream_latency_ms",
                                                  "Latency added by upstream response " ..
                                                  "for each service/route in Kong",
                                                  {"service", "route", "workspace"},
                                                  UPSTREAM_LATENCY_BUCKETS)


  if http_subsystem then
    metrics.total_latency = prometheus:histogram("request_latency_ms",
                                                 "Total latency incurred during requests " ..
                                                 "for each service/route in Kong",
                                                 {"service", "route", "workspace"},
                                                 UPSTREAM_LATENCY_BUCKETS)
  else
    metrics.total_latency = prometheus:histogram("session_duration_ms",
                                                 "latency incurred in stream session " ..
                                                 "for each service/route in Kong",
                                                 {"service", "route", "workspace"},
                                                 UPSTREAM_LATENCY_BUCKETS)
  end

  if http_subsystem then
    metrics.bandwidth = prometheus:counter("bandwidth_bytes",
                                          "Total bandwidth (ingress/egress) " ..
                                          "throughput in bytes",
                                          {"service", "route", "direction", "workspace","consumer"})
  else -- stream has no consumer
    metrics.bandwidth = prometheus:counter("bandwidth_bytes",
                                          "Total bandwidth (ingress/egress) " ..
                                          "throughput in bytes",
                                          {"service", "route", "direction", "workspace"})
  end

  -- AI mode
  metrics.ai_llm_requests = prometheus:counter("ai_llm_requests_total",
                                      "AI requests total per ai_provider in Kong",
                                      {"ai_provider", "ai_model", "cache_status", "vector_db", "embeddings_provider", "embeddings_model", "workspace"})

  metrics.ai_llm_cost = prometheus:counter("ai_llm_cost_total",
                                      "AI requests cost per ai_provider/cache in Kong",
                                      {"ai_provider", "ai_model", "cache_status", "vector_db", "embeddings_provider", "embeddings_model", "workspace"})

  metrics.ai_llm_tokens = prometheus:counter("ai_llm_tokens_total",
                                      "AI requests cost per ai_provider/cache in Kong",
                                      {"ai_provider", "ai_model", "cache_status", "vector_db", "embeddings_provider", "embeddings_model", "token_type", "workspace"})

  metrics.ai_llm_provider_latency = prometheus:histogram("ai_llm_provider_latency_ms",
                                      "LLM response Latency for each AI plugins per ai_provider in Kong",
                                      {"ai_provider", "ai_model", "cache_status", "vector_db", "embeddings_provider", "embeddings_model", "workspace"},
                                      AI_LLM_PROVIDER_LATENCY_BUCKETS)

  -- Hybrid mode status
  if role == "control_plane" then
    metrics.data_plane_last_seen = prometheus:gauge("data_plane_last_seen",
                                              "Last time data plane contacted control plane",
                                              {"node_id", "hostname", "ip"},
                                              prometheus.LOCAL_STORAGE)
    metrics.data_plane_config_hash = prometheus:gauge("data_plane_config_hash",
                                              "Config hash numeric value of the data plane",
                                              {"node_id", "hostname", "ip"},
                                              prometheus.LOCAL_STORAGE)

    metrics.data_plane_version_compatible = prometheus:gauge("data_plane_version_compatible",
                                              "Version compatible status of the data plane, 0 is incompatible",
                                              {"node_id", "hostname", "ip", "kong_version"},
                                              prometheus.LOCAL_STORAGE)
  elseif role == "data_plane" then
    local data_plane_cluster_cert_expiry_timestamp = prometheus:gauge(
      "data_plane_cluster_cert_expiry_timestamp",
      "Unix timestamp of Data Plane's cluster_cert expiry time",
      nil,
      prometheus.LOCAL_STORAGE)
    -- The cluster_cert doesn't change once Kong starts.
    -- We set this metrics just once to avoid file read in each scrape.
    local f = assert(io.open(kong.configuration.cluster_cert))
    local pem = assert(f:read("*a"))
    f:close()
    local x509 = require("resty.openssl.x509")
    local cert = assert(x509.new(pem, "PEM"))
    local not_after = assert(cert:get_not_after())
    data_plane_cluster_cert_expiry_timestamp:set(not_after)
  end
end


local function init_worker()
  prometheus:init_worker()
end


local function configure(configs)
  IS_PROMETHEUS_ENABLED = false
  wasm.set_enabled(false)

  if configs ~= nil then
    IS_PROMETHEUS_ENABLED = true

    for i = 1, #configs do
      if configs[i].wasm_metrics then
        wasm.set_enabled(true)
        break
      end
    end
  end
end


-- Convert the MD5 hex string to its numeric representation
-- Note the following will be represented as a float instead of int64 since luajit
-- don't like int64. Good news is prometheus uses float instead of int64 as well
local function config_hash_to_number(hash_str)
  return tonumber("0x" .. hash_str)
end

-- Since in the prometheus library we create a new table for each diverged label
-- so putting the "more dynamic" label at the end will save us some memory
local labels_table_bandwidth = {0, 0, 0, 0, 0}
local labels_table_status = {0, 0, 0, 0, 0, 0}
local labels_table_latency = {0, 0, 0}
local upstream_target_addr_health_table = {
  { value = 0, labels = { 0, 0, 0, "healthchecks_off", ngx.config.subsystem } },
  { value = 0, labels = { 0, 0, 0, "healthy", ngx.config.subsystem } },
  { value = 0, labels = { 0, 0, 0, "unhealthy", ngx.config.subsystem } },
  { value = 0, labels = { 0, 0, 0, "dns_error", ngx.config.subsystem } },
}
-- ai
local labels_table_ai_llm_status = {0, 0, 0, 0, 0, 0, 0}
local labels_table_ai_llm_tokens = {0, 0, 0, 0, 0, 0, 0, 0}

local function set_healthiness_metrics(table, upstream, target, address, status, metrics_bucket)
  for i = 1, #table do
    table[i]['labels'][1] = upstream
    table[i]['labels'][2] = target
    table[i]['labels'][3] = address
    table[i]['value'] = (status == table[i]['labels'][4]) and 1 or 0
    metrics_bucket:set(table[i]['value'], table[i]['labels'])
  end
end


local function log(message, serialized)
  if not metrics then
    kong.log.err("prometheus: can not log metrics because of an initialization "
            .. "error, please make sure that you've declared "
            .. "'prometheus_metrics' shared dict in your nginx template")
    return
  end

  local service_name = ""
  if message and message.service then
    service_name = message.service.name or message.service.host
  end

  local route_name
  if message and message.route then
    route_name = message.route.name or message.route.id
  else
    return
  end

  local consumer = ""
  if http_subsystem then
    if message and serialized.consumer ~= nil then
      consumer = serialized.consumer
    end
  else
    consumer = nil -- no consumer in stream
  end

  local workspace = message.workspace_name or ""
  if serialized.ingress_size or serialized.egress_size then
    labels_table_bandwidth[1] = service_name
    labels_table_bandwidth[2] = route_name
    labels_table_bandwidth[4] = workspace
    labels_table_bandwidth[5] = consumer

    local ingress_size = serialized.ingress_size
    if ingress_size and ingress_size > 0 then
      labels_table_bandwidth[3] = "ingress"
      metrics.bandwidth:inc(ingress_size, labels_table_bandwidth)
    end

    local egress_size = serialized.egress_size
    if egress_size and egress_size > 0 then
      labels_table_bandwidth[3] = "egress"
      metrics.bandwidth:inc(egress_size, labels_table_bandwidth)
    end
  end

  if serialized.status_code then
    labels_table_status[1] = service_name
    labels_table_status[2] = route_name
    labels_table_status[3] = serialized.status_code

    if kong.response.get_source() == "service" then
      labels_table_status[4] = "service"
    else
      labels_table_status[4] = "kong"
    end

    labels_table_status[5] = workspace
    labels_table_status[6] = consumer

    metrics.status:inc(1, labels_table_status)
  end

  if serialized.latencies then
    labels_table_latency[1] = service_name
    labels_table_latency[2] = route_name
    labels_table_latency[3] = workspace

    if http_subsystem then
      local request_latency = serialized.latencies.request
      if request_latency and request_latency >= 0 then
        metrics.total_latency:observe(request_latency, labels_table_latency)
      end

      local upstream_latency = serialized.latencies.proxy
      if upstream_latency ~= nil and upstream_latency >= 0 then
        metrics.upstream_latency:observe(upstream_latency, labels_table_latency)
      end

    else
      local session_latency = serialized.latencies.session
      if session_latency and session_latency >= 0 then
        metrics.total_latency:observe(session_latency, labels_table_latency)
      end
    end

    local kong_proxy_latency = serialized.latencies.kong
    if kong_proxy_latency ~= nil and kong_proxy_latency >= 0 then
      metrics.kong_latency:observe(kong_proxy_latency, labels_table_latency)
    end
  end

  if serialized.ai_metrics then
    -- prtically, serialized.ai_metrics stores namespaced metrics for at most three use cases
    -- proxy: everything going through the proxy path
    -- ai-request-transformer:
    -- ai-response-transformer: uses LLM to decorade the request/response, but the proxying traffic doesn't go to LLM
    for use_case, ai_metrics in pairs(serialized.ai_metrics) do
      kong.log.debug("ingesting ai_metrics for use_case: ", use_case)

      local cache_status = ai_metrics.cache and ai_metrics.cache.cache_status or ""
      local vector_db = ai_metrics.cache and ai_metrics.cache.vector_db or ""
      local embeddings_provider = ai_metrics.cache and ai_metrics.cache.embeddings_provider or ""
      local embeddings_model = ai_metrics.cache and ai_metrics.cache.embeddings_model or ""

      labels_table_ai_llm_status[1] = ai_metrics.meta and ai_metrics.meta.provider_name or ""
      labels_table_ai_llm_status[2] = ai_metrics.meta and ai_metrics.meta.request_model or ""
      labels_table_ai_llm_status[3] = cache_status
      labels_table_ai_llm_status[4] = vector_db
      labels_table_ai_llm_status[5] = embeddings_provider
      labels_table_ai_llm_status[6] = embeddings_model
      labels_table_ai_llm_status[7] = workspace
      metrics.ai_llm_requests:inc(1, labels_table_ai_llm_status)

      if ai_metrics.usage and ai_metrics.usage.cost and ai_metrics.usage.cost > 0 then
        metrics.ai_llm_cost:inc(ai_metrics.usage.cost, labels_table_ai_llm_status)
      end

      if ai_metrics.meta and ai_metrics.meta.llm_latency and ai_metrics.meta.llm_latency > 0 then
        metrics.ai_llm_provider_latency:observe(ai_metrics.meta.llm_latency, labels_table_ai_llm_status)
      end

      if ai_metrics.cache and ai_metrics.cache.fetch_latency and ai_metrics.cache.fetch_latency > 0 then
        metrics.ai_cache_fetch_latency:observe(ai_metrics.cache.fetch_latency, labels_table_ai_llm_status)
      end

      if ai_metrics.cache and ai_metrics.cache.embeddings_latency and ai_metrics.cache.embeddings_latency > 0 then
        metrics.ai_cache_embeddings_latency:observe(ai_metrics.cache.embeddings_latency, labels_table_ai_llm_status)
      end

      labels_table_ai_llm_tokens[1] = ai_metrics.meta and ai_metrics.meta.provider_name or ""
      labels_table_ai_llm_tokens[2] = ai_metrics.meta and ai_metrics.meta.request_model or ""
      labels_table_ai_llm_tokens[3] = cache_status
      labels_table_ai_llm_tokens[4] = vector_db
      labels_table_ai_llm_tokens[5] = embeddings_provider
      labels_table_ai_llm_tokens[6] = embeddings_model
      labels_table_ai_llm_tokens[8] = workspace

      if ai_metrics.usage and ai_metrics.usage.prompt_tokens and ai_metrics.usage.prompt_tokens > 0 then
        labels_table_ai_llm_tokens[7] = "prompt_tokens"
        metrics.ai_llm_tokens:inc(ai_metrics.usage.prompt_tokens, labels_table_ai_llm_tokens)
      end

      if ai_metrics.usage and ai_metrics.usage.completion_tokens and ai_metrics.usage.completion_tokens > 0 then
        labels_table_ai_llm_tokens[7] = "completion_tokens"
        metrics.ai_llm_tokens:inc(ai_metrics.usage.completion_tokens, labels_table_ai_llm_tokens)
      end

      if ai_metrics.usage and ai_metrics.usage.total_tokens and ai_metrics.usage.total_tokens > 0 then
        labels_table_ai_llm_tokens[7] = "total_tokens"
        metrics.ai_llm_tokens:inc(ai_metrics.usage.total_tokens, labels_table_ai_llm_tokens)
      end
    end
  end
end

-- The upstream health metrics is turned on if at least one of
-- the plugin turns upstream_health_metrics on.
-- Due to the fact that during scrape time we don't want to
-- iterrate over all plugins to find out if upstream_health_metrics
-- is turned on or not, we will need a Kong reload if someone
-- turned on upstream_health_metrics on and off again, to actually
-- stop exporting upstream health metrics
local should_export_upstream_health_metrics = false


local function metric_data(write_fn)
  if not prometheus or not metrics then
    kong.log.err("prometheus: plugin is not initialized, please make sure ",
                 " 'prometheus_metrics' shared dict is present in nginx template")
    return kong.response.exit(500, { message = "An unexpected error occurred" })
  end

  local nginx_statistics = kong.nginx.get_statistics()
  metrics.connections:set(nginx_statistics['connections_accepted'], { node_id, kong_subsystem, "accepted" })
  metrics.connections:set(nginx_statistics['connections_handled'], { node_id, kong_subsystem, "handled" })
  metrics.connections:set(nginx_statistics['total_requests'], { node_id, kong_subsystem, "total" })
  metrics.connections:set(nginx_statistics['connections_active'], { node_id, kong_subsystem, "active" })
  metrics.connections:set(nginx_statistics['connections_reading'], { node_id, kong_subsystem, "reading" })
  metrics.connections:set(nginx_statistics['connections_writing'], { node_id, kong_subsystem, "writing" })
  metrics.connections:set(nginx_statistics['connections_waiting'], { node_id, kong_subsystem,"waiting" })

  metrics.nginx_requests_total:set(nginx_statistics['total_requests'], { node_id, kong_subsystem })

  if http_subsystem then -- only export those metrics once in http as they are shared
    metrics.timers:set(ngx_timer_running_count(), {"running"})
    metrics.timers:set(ngx_timer_pending_count(), {"pending"})

    -- db reachable?
    local ok, err = kong.db.connector:connect()
    if ok then
      metrics.db_reachable:set(1)

    else
      metrics.db_reachable:set(0)
      kong.log.err("prometheus: failed to reach database while processing",
                  "/metrics endpoint: ", err)
    end
  end

  local phase = get_phase()

  -- only export upstream health metrics in traditional mode and data plane
  if role ~= "control_plane" and should_export_upstream_health_metrics then
    -- erase all target/upstream metrics, prevent exposing old metrics
    metrics.upstream_target_health:reset()

    -- upstream targets accessible?
    local upstreams_dict = get_all_upstreams()
    for key, upstream_id in pairs(upstreams_dict) do
      -- long loop maybe spike proxy request latency, so we
      -- need yield to avoid blocking other requests
      -- kong.tools.yield.yield(true)
      yield(true, phase)
      local _, upstream_name = key:match("^([^:]*):(.-)$")
      upstream_name = upstream_name and upstream_name or key
      -- based on logic from kong.db.dao.targets
      local health_info, err = balancer.get_upstream_health(upstream_id)
      if err then
        kong.log.err("failed getting upstream health: ", err)
      end

      if health_info then
        for target_name, target_info in pairs(health_info) do
          if target_info ~= nil and target_info.addresses ~= nil and
            #target_info.addresses > 0 then
            -- healthchecks_off|healthy|unhealthy
            for i = 1, #target_info.addresses do
              local address = target_info.addresses[i]
              local address_label = address.ip .. ":" .. address.port
              local status = lower(address.health)
              set_healthiness_metrics(upstream_target_addr_health_table, upstream_name, target_name, address_label, status, metrics.upstream_target_health)
            end
          else
            -- dns_error
            set_healthiness_metrics(upstream_target_addr_health_table, upstream_name, target_name, '', 'dns_error', metrics.upstream_target_health)
          end
        end
      end
    end
  end

  -- memory stats
  local res = kong.node.get_memory_stats()
  for shm_name, value in pairs(res.lua_shared_dicts) do
    metrics.memory_stats.shms:set(value.allocated_slabs, { node_id, shm_name, kong_subsystem })
  end
  for i = 1, #res.workers_lua_vms do
    metrics.memory_stats.worker_vms:set(res.workers_lua_vms[i].http_allocated_gc,
                                        { node_id, res.workers_lua_vms[i].pid, kong_subsystem })
  end

  -- Hybrid mode status
  if role == "control_plane" then
    -- Cleanup old metrics
    metrics.data_plane_last_seen:reset()
    metrics.data_plane_config_hash:reset()
    metrics.data_plane_version_compatible:reset()

    for data_plane, err in kong.db.clustering_data_planes:each() do
      if err then
        kong.log.err("failed to list data planes: ", err)
        goto next_data_plane
      end

      local labels = { data_plane.id, data_plane.hostname, data_plane.ip }

      metrics.data_plane_last_seen:set(data_plane.last_seen, labels)
      metrics.data_plane_config_hash:set(config_hash_to_number(data_plane.config_hash), labels)

      labels[4] = data_plane.version
      local compatible = 1

      if data_plane.sync_status == CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE
        or data_plane.sync_status == CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE
        or data_plane.sync_status == CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE then

        compatible = 0
      end
      metrics.data_plane_version_compatible:set(compatible, labels)

::next_data_plane::
    end
  end

  -- notify the function if prometheus plugin is enabled,
  -- so that it can avoid exporting unnecessary metrics if not
  prometheus:metric_data(write_fn, not IS_PROMETHEUS_ENABLED)
  wasm.metrics_data()
end

local function collect()
  ngx.header["Content-Type"] = "text/plain; charset=UTF-8"

  metric_data()

  -- only gather stream metrics if stream_api module is available
  -- and user has configured at least one stream listeners
  if stream_available and #kong.configuration.stream_listeners > 0 then
    local res, err = stream_api.request("prometheus", "")
    if err then
      kong.log.err("failed to collect stream metrics: ", err)
    else
      ngx.print(res)
    end
  end
end

local function get_prometheus()
  if not prometheus then
    kong.log.err("prometheus: plugin is not initialized, please make sure ",
                     " 'prometheus_metrics' shared dict is present in nginx template")
  end
  return prometheus
end

local function set_export_upstream_health_metrics(set_or_not)
  should_export_upstream_health_metrics = set_or_not
end


return {
  init        = init,
  init_worker = init_worker,
  configure   = configure,
  log         = log,
  metric_data = metric_data,
  collect     = collect,
  get_prometheus = get_prometheus,
  set_export_upstream_health_metrics = set_export_upstream_health_metrics,
}
