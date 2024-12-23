local helpers = require "spec.helpers"
local shell = require "resty.shell"

local tcp_service_port = helpers.get_available_port()
local tcp_proxy_port = helpers.get_available_port()
local tcp_status_port = helpers.get_available_port()
local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

describe("Plugin: prometheus (access via status API)", function()
  local proxy_client
  local status_client
  local proxy_client_grpc
  local proxy_client_grpcs

  local function get_metrics()
    if not status_client then
      status_client = helpers.http_client("127.0.0.1", tcp_status_port, 20000)
      status_client.reopen = true -- retry on a closed connection
    end

    local res, err = status_client:get("/metrics")

    assert.is_nil(err, "failed GET /metrics: " .. tostring(err))
    return assert.res_status(200, res)
  end

  setup(function()
    local bp = helpers.get_db_utils()

    local upstream_hc_off = bp.upstreams:insert({
      name = "mock-upstream-healthchecksoff",
    })
    bp.targets:insert {
      target = helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port,
      weight = 1000,
      upstream = { id = upstream_hc_off.id },
    }

    local upstream = bp.upstreams:insert({
      name = "mock-upstream",
    })

    upstream.healthchecks = {
      active = {
        concurrency = 10,
        healthy = {
          http_statuses = { 200, 302 },
          interval = 0.1,
          successes = 2
        },
        http_path = "/status/200",
        https_verify_certificate = true,
        timeout = 1,
        type = "http",
        unhealthy = {
          http_failures = 1,
          http_statuses = { 429, 404, 500, 501, 502, 503, 504, 505 },
          interval = 0.1,
          tcp_failures = 1,
          timeouts = 1
        }
      },
      passive = {
        healthy = {
          http_statuses = { 200, 201, 202, 203, 204, 205, 206, 207, 208, 226, 300, 301, 302, 303, 304, 305, 306, 307, 308 },
          successes = 1
        },
        type = "http",
        unhealthy = {
          http_failures = 1,
          http_statuses = { 429, 500, 503 },
          tcp_failures = 1,
          timeouts = 1
        }
      }
    }

    upstream = bp.upstreams:update({ id = upstream.id }, { healthchecks = upstream.healthchecks })

    bp.targets:insert {
      target = helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port,
      weight = 1000,
      upstream = { id = upstream.id },
    }

    bp.targets:insert {
      target = helpers.mock_upstream_host .. ':8001',
      weight = 1,
      upstream = { id = upstream.id },
    }

    bp.targets:insert {
      target = 'some-random-dns:80',
      weight = 1,
      upstream = { id = upstream.id },
    }

    local service = bp.services:insert {
      name = "mock-service",
      host = upstream.name,
      port = helpers.mock_upstream_port,
      protocol = helpers.mock_upstream_protocol,
    }

    bp.routes:insert {
      protocols = { "http" },
      name = "http-route",
      paths = { "/" },
      methods = { "GET" },
      service = service,
    }

    local grpc_service = bp.services:insert {
      name = "mock-grpc-service",
      url = helpers.grpcbin_url,
    }

    bp.routes:insert {
      protocols = { "grpc" },
      name = "grpc-route",
      hosts = { "grpc" },
      service = grpc_service,
    }

    local grpcs_service = bp.services:insert {
      name = "mock-grpcs-service",
      url = helpers.grpcbin_ssl_url,
    }

    bp.routes:insert {
      protocols = { "grpcs" },
      name = "grpcs-route",
      hosts = { "grpcs" },
      service = grpcs_service,
    }

    local tcp_service = bp.services:insert {
      name = "tcp-service",
      url = "tcp://127.0.0.1:" .. tcp_service_port,
    }

    bp.routes:insert {
      protocols = { "tcp" },
      name = "tcp-route",
      service = tcp_service,
      destinations = { { port = tcp_proxy_port } },
    }

    bp.plugins:insert {
      protocols = { "http", "https", "grpc", "grpcs", "tcp", "tls" },
      name = "prometheus",
      config = {
        status_code_metrics = true,
        latency_metrics = true,
        bandwidth_metrics = true,
        upstream_health_metrics = true,
      },
    }

    assert(helpers.start_kong {
      nginx_conf = "spec/fixtures/custom_nginx.template",
      plugins = "bundled",
      status_listen = "0.0.0.0:" .. tcp_status_port,
      stream_listen = "127.0.0.1:" .. tcp_proxy_port,
      nginx_worker_processes = 1, -- due to healthcheck state flakyness and local switch of healthcheck export or not
    })
    proxy_client_grpc = helpers.proxy_client_grpc()
    proxy_client_grpcs = helpers.proxy_client_grpcs()

    require("socket").sleep(1) -- wait 1 second until healthchecks run
  end)


  before_each(function()
    proxy_client = helpers.proxy_client()
  end)

  after_each(function()
    if status_client then
      status_client:close()
    end
    if proxy_client then
      proxy_client:close()
    end
  end)

  teardown(function()
    helpers.stop_kong()
  end)

  it("increments the count for proxied requests", function()
    local res = assert(proxy_client:send {
      method  = "GET",
      path    = "/status/200",
      headers = {
        host = helpers.mock_upstream_host,
      }
    })
    assert.res_status(200, res)

    helpers.wait_until(function()
      local body = get_metrics()
      return body:find('http_requests_total{service="mock-service",route="http-route",code="200",source="service",workspace="default",consumer=""} 1', nil, true)
    end)

    res = assert(proxy_client:send {
      method  = "GET",
      path    = "/status/400",
      headers = {
        host = helpers.mock_upstream_host,
      }
    })
    assert.res_status(400, res)
    local body = get_metrics()

    assert.matches('kong_kong_latency_ms_bucket{service="mock%-service",route="http%-route",workspace="default",le="%+Inf"} +%d', body)
    assert.matches('kong_upstream_latency_ms_bucket{service="mock%-service",route="http%-route",workspace="default",le="%+Inf"} +%d', body)
    assert.matches('kong_request_latency_ms_bucket{service="mock%-service",route="http%-route",workspace="default",le="%+Inf"} +%d', body)

    assert.matches('http_requests_total{service="mock-service",route="http-route",code="400",source="service",workspace="default",consumer=""} 1', body, nil, true)
    assert.matches('kong_bandwidth_bytes{service="mock%-service",route="http%-route",direction="ingress",workspace="default",consumer=""} %d+', body)

    assert.matches('kong_bandwidth_bytes{service="mock%-service",route="http%-route",direction="egress",workspace="default",consumer=""} %d+', body)
  end)

  it("increments the count for proxied grpc requests", function()
    local ok, resp = proxy_client_grpc({
      service = "hello.HelloService.SayHello",
      body = {
        greeting = "world!"
      },
      opts = {
        ["-authority"] = "grpc",
      }
    })
    assert(ok, resp)
    assert.truthy(resp)

    helpers.wait_until(function()
      local body = get_metrics()
      return body:find('http_requests_total{service="mock-grpc-service",route="grpc-route",code="200",source="service",workspace="default",consumer=""} 1', nil, true)
    end)

    ok, resp = proxy_client_grpcs({
      service = "hello.HelloService.SayHello",
      body = {
        greeting = "world!"
      },
      opts = {
        ["-authority"] = "grpcs",
      }
    })
    assert(ok, resp)
    assert.truthy(resp)

    helpers.wait_until(function()
      local body = get_metrics()
      return body:find('http_requests_total{service="mock-grpcs-service",route="grpcs-route",code="200",source="service",workspace="default",consumer=""} 1', nil, true)
    end)
  end)

  it("does not log error if no service was matched", function()
    -- cleanup logs
    shell.run(":> " .. helpers.test_conf.nginx_err_logs, nil, 0)

    local res = assert(proxy_client:send {
      method  = "POST",
      path    = "/no-route-match-in-kong",
    })
    assert.res_status(404, res)

    -- make sure no errors
    assert.logfile().has.no.line("[error]", true, 10)
  end)

  it("does not log error during a scrape", function()
    -- cleanup logs
    shell.run(":> " .. helpers.test_conf.nginx_err_logs, nil, 0)

    get_metrics()

    -- make sure no errors
    assert.logfile().has.no.line("[error]", true, 10)
  end)

  it("scrape response has metrics and comments only", function()
    local body = get_metrics()
    for line in body:gmatch("[^\r\n]+") do
      assert.matches("^[#|kong]", line)
    end

  end)

  it("exposes db reachability metrics", function()
    local body = get_metrics()
    assert.matches('kong_datastore_reachable 1', body, nil, true)
  end)

  it("exposes nginx timer metrics", function()
    local body = get_metrics()
    assert.matches('kong_nginx_timers{state="running"} %d+', body)
    assert.matches('kong_nginx_timers{state="pending"} %d+', body)
  end)

  it("exposes upstream's target health metrics - healthchecks-off", function()
    local body
    helpers.wait_until(function()
      body = get_metrics()
      return body:find('kong_upstream_target_health{upstream="mock-upstream-healthchecksoff",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="healthchecks_off",subsystem="http"} 1', nil, true)
    end)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream-healthchecksoff",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="healthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream-healthchecksoff",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="unhealthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream-healthchecksoff",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="dns_error",subsystem="http"} 0', body, nil, true)
  end)

  it("exposes upstream's target health metrics - healthy", function()
    local body
    helpers.wait_until(function()
      body = get_metrics()
      return body:find('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="healthy",subsystem="http"} 1', nil, true)
    end)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="healthchecks_off",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="unhealthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",address="' .. helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port .. '",state="dns_error",subsystem="http"} 0', body, nil, true)
  end)

  it("exposes upstream's target health metrics - unhealthy", function()
    local body
    helpers.wait_until(function()
      body = get_metrics()
      return body:find('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':8001",address="' .. helpers.mock_upstream_host .. ':8001",state="unhealthy",subsystem="http"} 1', nil, true)
    end)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':8001",address="' .. helpers.mock_upstream_host .. ':8001",state="healthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':8001",address="' .. helpers.mock_upstream_host .. ':8001",state="healthchecks_off",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="' .. helpers.mock_upstream_host .. ':8001",address="' .. helpers.mock_upstream_host .. ':8001",state="dns_error",subsystem="http"} 0', body, nil, true)
  end)

  it("exposes upstream's target health metrics - dns_error", function()
    local body
    helpers.wait_until(function()
      body = get_metrics()
      return body:find('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="dns_error",subsystem="http"} 1', nil, true)
    end)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="healthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="unhealthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="healthchecks_off",subsystem="http"} 0', body, nil, true)
  end)

  it("adds subsystem label to upstream's target health metrics", function()
    -- need to send at least TCP request to start exposing target health metrics
    local thread = helpers.tcp_server(tcp_service_port, { requests = 1 })

    local conn = assert(ngx.socket.connect("127.0.0.1", tcp_proxy_port))

    assert(conn:send("hi there!\n"))
    local gotback = assert(conn:receive("*a"))
    assert.equal("hi there!\n", gotback)

    conn:close()

    local body
    helpers.wait_until(function()
      body = get_metrics()
      return body:find('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="dns_error",subsystem="stream"} 1', nil, true)
    end)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="healthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="healthy",subsystem="stream"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="unhealthy",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="unhealthy",subsystem="stream"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="healthchecks_off",subsystem="http"} 0', body, nil, true)
    assert.matches('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80",address="",state="healthchecks_off",subsystem="stream"} 0', body, nil, true)

    thread:join()
  end)

  it("remove metrics from deleted upstreams", function()
    local admin_client = helpers.admin_client()
    assert(admin_client:send {
      method  = "DELETE",
      path    = "/upstreams/mock-upstream-healthchecksoff",
    })
    admin_client:close()

    local body
    helpers.wait_until(function()
      body = get_metrics()
      return not body:find('kong_upstream_target_health{upstream="mock-upstream-healthchecksoff"', nil, true)
    end, 15)
  end)

  it("remove metrics from deleted targets", function()
    local admin_client = helpers.admin_client()
    assert(admin_client:send {
      method  = "DELETE",
      path    = "/upstreams/mock-upstream/targets/some-random-dns:80",
    })
    admin_client:close()

    local body
    helpers.wait_until(function()
      body = get_metrics()
      return not body:find('kong_upstream_target_health{upstream="mock-upstream",target="some-random-dns:80"', nil, true)
    end, 15)
  end)

  it("exposes Lua worker VM stats", function()
    local body = get_metrics()
    assert.matches('kong_memory_workers_lua_vms_bytes{node_id="' .. UUID_PATTERN .. '",pid="%d+",kong_subsystem="http"}', body)
    assert.matches('kong_memory_workers_lua_vms_bytes{node_id="' .. UUID_PATTERN .. '",pid="%d+",kong_subsystem="stream"}', body)

    assert.matches('kong_nginx_metric_errors_total 0', body, nil, true)
    assert.matches('kong_node_info{node_id="' .. UUID_PATTERN .. '",version="%S+"} 1', body)
  end)

  it("exposes lua_shared_dict metrics", function()
    local body = get_metrics()
    assert.matches('kong_memory_lua_shared_dict_total_bytes' ..
                   '{node_id="' .. UUID_PATTERN .. '",shared_dict="prometheus_metrics",kong_subsystem="http"} %d+', body)
    -- TODO: uncomment below once the ngx.shared iterrator in stream is fixed
    -- assert.matches('kong_memory_lua_shared_dict_total_bytes' ..
    --                 '{shared_dict="prometheus_metrics",kong_subsystem="stream"} %d+', body)

    assert.matches('kong_nginx_metric_errors_total 0', body, nil, true)
  end)
end)

local granular_metrics_set = {
  status_code_metrics = "http_requests_total",
  latency_metrics = "kong_latency_ms",
  bandwidth_metrics = "bandwidth_bytes",
  upstream_health_metrics = "upstream_target_health",
}

for switch, expected_pattern in pairs(granular_metrics_set) do
describe("Plugin: prometheus (access) granular metrics switch", function()
  local proxy_client
  local status_client

  local success_scrape = ""

  setup(function()
    local bp = helpers.get_db_utils()

    local service = bp.services:insert {
      name = "mock-service",
      host = helpers.mock_upstream_host,
      port = helpers.mock_upstream_port,
      protocol = helpers.mock_upstream_protocol,
    }

    bp.routes:insert {
      protocols = { "http" },
      name = "http-route",
      paths = { "/" },
      methods = { "GET" },
      service = service,
    }

    local upstream_hc_off = bp.upstreams:insert({
      name = "mock-upstream-healthchecksoff",
    })
    bp.targets:insert {
      target = helpers.mock_upstream_host .. ':' .. helpers.mock_upstream_port,
      weight = 1000,
      upstream = { id = upstream_hc_off.id },
    }

    bp.plugins:insert {
      protocols = { "http", "https", "grpc", "grpcs", "tcp", "tls" },
      name = "prometheus",
      config = {
        [switch] = true,
      },
    }

    assert(helpers.start_kong {
      nginx_conf = "spec/fixtures/custom_nginx.template",
      plugins = "bundled, prometheus",
      status_listen = "0.0.0.0:" .. tcp_status_port,
      nginx_worker_processes = 1, -- due to healthcheck state flakyness and local switch of healthcheck export or not
    })
    proxy_client = helpers.proxy_client()
    status_client = helpers.http_client("127.0.0.1", tcp_status_port, 20000)
  end)

  teardown(function()
    if proxy_client then
      proxy_client:close()
    end
    if status_client then
      status_client:close()
    end

    helpers.stop_kong()
  end)

  it("expected metrics " .. expected_pattern .. " is found", function()
    local res = assert(proxy_client:send {
      method  = "GET",
      path    = "/status/200",
      headers = {
        host = helpers.mock_upstream_host,
        apikey = 'alice-key',
      }
    })
    assert.res_status(200, res)

    helpers.wait_until(function()
      local res = assert(status_client:send {
        method  = "GET",
        path    = "/metrics",
      })
      local body = assert.res_status(200, res)
      assert.matches('kong_nginx_metric_errors_total 0', body, nil, true)

      success_scrape = body

      return body:find(expected_pattern, nil, true)
    end)
  end)

  it("unexpected metrics is not found", function()
    for test_switch, test_expected_pattern in pairs(granular_metrics_set) do
      if test_switch ~= switch then
        assert.not_match(test_expected_pattern, success_scrape, nil, true)
      end
    end
  end)

end)
end

describe("CP/DP connectivity state #", function ()
  local status_client

  local function get_metrics()
    if not status_client then
      status_client = helpers.http_client("127.0.0.1", tcp_status_port, 20000)
      status_client.reopen = true -- retry on a closed connection
    end

    local res, err = status_client:get("/metrics")

    assert.is_nil(err, "failed GET /metrics: " .. tostring(err))
    return assert.res_status(200, res)
  end

  setup(function()
    local bp = helpers.get_db_utils()

    bp.plugins:insert {
      protocols = { "http", "https", "grpc", "grpcs", "tcp", "tls" },
      name = "prometheus",
    }

    assert(helpers.start_kong({
      role = "control_plane",
      prefix = "prom_cp",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      cluster_listen = "127.0.0.1:9005",
      plugins = "bundled, prometheus",
    }))

    assert(helpers.start_kong({
      role = "data_plane",
      database = "off",
      prefix = "prom_dp",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      cluster_control_plane = "127.0.0.1:9005",
      proxy_listen = "0.0.0.0:9000",
      worker_state_update_frequency = 1,
      status_listen = "0.0.0.0:" .. tcp_status_port,
      nginx_worker_processes = 1,
      dedicated_config_processing = "on",
      plugins = "bundled, prometheus",
    }))
    status_client = helpers.http_client("127.0.0.1", tcp_status_port, 20000)
  end)

  teardown(function()
    if status_client then
      status_client:close()
    end

    helpers.stop_kong("prom_dp")
  end)

  it("exposes controlplane connectivity status", function ()
    local body = get_metrics()
    assert.matches('kong_control_plane_reachable 1', body, nil, true)

    helpers.stop_kong("prom_cp")
    local body  = get_metrics()
    assert.matches('kong_control_plane_reachable 0', body, nil, true)
  end)
end)
