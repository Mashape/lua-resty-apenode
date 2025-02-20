local helpers = require "spec.helpers"
local cjson = require "cjson"
local utils = require "kong.tools.rand"
local to_hex = require "resty.string".to_hex

local fmt = string.format

local ZIPKIN_HOST = helpers.zipkin_host
local ZIPKIN_PORT = helpers.zipkin_port

local http_route_host             = "http-route"
local http_route_ignore_host      = "http-route-ignore"
local http_route_w3c_host         = "http-route-w3c"
local http_route_dd_host          = "http-route-dd"
local http_route_ins_host         = "http-route-ins"
local http_route_clear_host       = "http-clear-route"
local http_route_no_preserve_host = "http-no-preserve-route"

-- Transform zipkin annotations into a hash of timestamps. It assumes no repeated values
-- input: { { value = x, timestamp = y }, { value = x2, timestamp = y2 } }
-- output: { x = y, x2 = y2 }
local function annotations_to_hash(annotations)
  local hash = {}
  for _, a in ipairs(annotations) do
    assert(not hash[a.value], "duplicated annotation: " .. a.value)
    hash[a.value] = a.timestamp
  end
  return hash
end


local function to_id_len(id, len)
  if #id < len then
    return string.rep('0', len - #id) .. id
  elseif #id > len then
    return string.sub(id, -len)
  end

  return id
end


local function assert_is_integer(number)
  assert.equals("number", type(number))
  assert.equals(number, math.floor(number))
end


local function gen_trace_id(traceid_byte_count)
  return to_hex(utils.get_rand_bytes(traceid_byte_count))
end


local function gen_span_id()
  return to_hex(utils.get_rand_bytes(8))
end

-- assumption: tests take less than this (usually they run in ~2 seconds)
local MAX_TIMESTAMP_AGE = 5 * 60 -- 5 minutes
local function assert_valid_timestamp(timestamp_mu, start_s)
  assert_is_integer(timestamp_mu)
  local age_s = timestamp_mu / 1000000 - start_s

  if age_s < 0 or age_s > MAX_TIMESTAMP_AGE then
    error("out of bounds timestamp: " .. timestamp_mu .. "mu (age: " .. age_s .. "s)")
  end
end

local function wait_for_spans(zipkin_client, number_of_spans, remoteServiceName, trace_id)
  local spans = {}
  helpers.wait_until(function()
    if trace_id then
      local res, err = zipkin_client:get("/api/v2/trace/" .. trace_id)
      if err then
        return false, err
      end

      local body = res:read_body()
      if res.status ~= 200 then
        return false
      end

      spans = cjson.decode(body)
      return #spans == number_of_spans
    end

    local res = zipkin_client:get("/api/v2/traces", {
      query = {
        limit = 10,
        remoteServiceName = remoteServiceName,
      }
    })

    local body = res:read_body()
    if res.status ~= 200 then
      return false
    end

    local all_spans = cjson.decode(body)
    if #all_spans > 0 then
      spans = all_spans[1]
      return #spans == number_of_spans
    end
  end)

  return spans
end


-- the following assertions should be true on any span list, even in error mode
local function assert_span_invariants(request_span, proxy_span, traceid_len, start_s, service_name, phase_duration_flavor)
  -- request_span
  assert.same("table", type(request_span))
  assert.same("string", type(request_span.id))
  assert.same(request_span.id, proxy_span.parentId)

  assert.same("SERVER", request_span.kind)

  assert.same("string", type(request_span.traceId))
  assert.equals(traceid_len, #request_span.traceId, request_span.traceId)
  assert_valid_timestamp(request_span.timestamp, start_s)

  if request_span.duration and proxy_span.duration then
    assert.truthy(request_span.duration >= proxy_span.duration)
  end

  assert.same({ serviceName = service_name }, request_span.localEndpoint)

  -- proxy_span
  assert.same("table", type(proxy_span))
  assert.same("string", type(proxy_span.id))
  assert.same(request_span.name .. " (proxy)", proxy_span.name)
  assert.same(request_span.id, proxy_span.parentId)

  assert.same("CLIENT", proxy_span.kind)

  assert.same("string", type(proxy_span.traceId))
  assert.equals(request_span.traceId, proxy_span.traceId)
  assert_valid_timestamp(proxy_span.timestamp, start_s)

  if request_span.duration and proxy_span.duration then
    assert.truthy(proxy_span.duration >= 0)
  end

  phase_duration_flavor = phase_duration_flavor or "annotations"
  if phase_duration_flavor == "annotations" then
    if #request_span.annotations == 1 then
      error(require("inspect")(request_span))
    end
    assert.equals(2, #request_span.annotations)

    local rann = annotations_to_hash(request_span.annotations)
    assert_valid_timestamp(rann["krs"], start_s)
    assert_valid_timestamp(rann["krf"], start_s)
    assert.truthy(rann["krs"] <= rann["krf"])

    assert.equals(6, #proxy_span.annotations)
    local pann = annotations_to_hash(proxy_span.annotations)

    assert_valid_timestamp(pann["kas"], start_s)
    assert_valid_timestamp(pann["kaf"], start_s)
    assert_valid_timestamp(pann["khs"], start_s)
    assert_valid_timestamp(pann["khf"], start_s)
    assert_valid_timestamp(pann["kbs"], start_s)
    assert_valid_timestamp(pann["kbf"], start_s)

    assert.truthy(pann["kas"] <= pann["kaf"])
    assert.truthy(pann["khs"] <= pann["khf"])
    assert.truthy(pann["kbs"] <= pann["kbf"])
    assert.truthy(pann["khs"] <= pann["kbs"])

  elseif phase_duration_flavor == "tags" then
    local rtags = request_span.tags
    assert.truthy(tonumber(rtags["kong.rewrite.duration_ms"]) >= 0)

    local ptags = proxy_span.tags
    assert.truthy(tonumber(ptags["kong.access.duration_ms"]) >= 0)
    assert.truthy(tonumber(ptags["kong.header_filter.duration_ms"]) >= 0)
    assert.truthy(tonumber(ptags["kong.body_filter.duration_ms"]) >= 0)
  end
end

local function get_span(name, spans)
  for _, span in ipairs(spans) do
    if span.name == name then
      return span
    end
  end
  return nil
end


for _, strategy in helpers.each_strategy() do
  describe("plugin configuration", function()
    local proxy_client, zipkin_client, service

    setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
      }

      -- kong (http) mock upstream
      bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "http-route" },
        preserve_host = true,
      })

      -- enable zipkin plugin globally, with sample_ratio = 0
      bp.plugins:insert({
        name = "zipkin",
        config = {
          sample_ratio = 0,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          default_header_type = "b3-single",
        }
      })

      -- enable zipkin on the route, with sample_ratio = 1
      -- this should generate traces, even if there is another plugin with sample_ratio = 0
      bp.plugins:insert({
        name = "zipkin",
        route = {id = bp.routes:insert({
          service = service,
          hosts = { http_route_host },
        }).id},
        config = {
          sample_ratio = 1,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          default_header_type = "b3-single",
        }
      })

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000",
      })

      proxy_client = helpers.proxy_client()
      zipkin_client = helpers.http_client(ZIPKIN_HOST, ZIPKIN_PORT)
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("#generates traces when several plugins exist and one of them has sample_ratio = 0 but not the other", function()
      local start_s = ngx.now()

      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          host  = "http-route",
          ["zipkin-tags"] = "foo=bar; baz=qux"
        },
      })
      assert.response(r).has.status(200)

      local spans = wait_for_spans(zipkin_client, 3, service.name)
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      -- common assertions for request_span and proxy_span
      assert_span_invariants(request_span, proxy_span, 16 * 2, start_s, "kong")
    end)
  end)
end


for _, strategy in helpers.each_strategy() do
  describe("serviceName configuration", function()
    local proxy_client, zipkin_client, service

    setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
      }

      -- kong (http) mock upstream
      bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "http-route" },
        preserve_host = true,
      })

      -- enable zipkin plugin globally, with sample_ratio = 1
      bp.plugins:insert({
        name = "zipkin",
        config = {
          sample_ratio = 1,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          default_header_type = "b3-single",
          local_service_name = "custom-service-name",
        }
      })

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000",
      })

      proxy_client = helpers.proxy_client()
      zipkin_client = helpers.http_client(ZIPKIN_HOST, ZIPKIN_PORT)
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("#generates traces with configured serviceName if set", function()
      local start_s = ngx.now()

      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          host  = "http-route",
          ["zipkin-tags"] = "foo=bar; baz=qux"
        },
      })
      assert.response(r).has.status(200)

      local spans = wait_for_spans(zipkin_client, 3, service.name)
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      -- common assertions for request_span and proxy_span
      assert_span_invariants(request_span, proxy_span, 16 * 2, start_s, "custom-service-name")
    end)
  end)
end

for _, strategy in helpers.each_strategy() do
  describe("upstream zipkin failures", function()
    local proxy_client, service

    before_each(function()
      helpers.clean_logfile() -- prevent log assertions from poisoning each other.
  end)

    setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      -- kong (http) mock upstream
      local route1 = bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "zipkin-upstream-slow" },
        preserve_host = true,
      })

      -- plugin will respond slower than the send/recv timeout
      bp.plugins:insert {
        route = { id = route1.id },
        name = "zipkin",
        config = {
          sample_ratio = 1,
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                     .. ":"
                                     .. helpers.mock_upstream_port
                                     .. "/delay/1",
          default_header_type = "b3-single",
          connect_timeout = 0,
          send_timeout = 10,
          read_timeout = 10,
        }
      }

      local route2 = bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "zipkin-upstream-connect-timeout" },
        preserve_host = true,
      })

      -- plugin will timeout (assumes port 1337 will have firewall)
      bp.plugins:insert {
        route = { id = route2.id },
        name = "zipkin",
        config = {
          sample_ratio = 1,
          http_endpoint = "http://konghq.com:1337/status/200",
          default_header_type = "b3-single",
          connect_timeout = 10,
          send_timeout = 0,
          read_timeout = 0,
        }
      }

      local route3 = bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "zipkin-upstream-refused" },
        preserve_host = true,
      })

      -- plugin will get connection refused (service not listening on port)
      bp.plugins:insert {
        route = { id = route3.id },
        name = "zipkin",
        config = {
          sample_ratio = 1,
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                     .. ":22222"
                                     .. "/status/200",
          default_header_type = "b3-single",
        }
      }

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      })

      proxy_client = helpers.proxy_client()
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("times out if connection times out to upstream zipkin server", function()
      local res = assert(proxy_client:send({
        method  = "GET",
        path    = "/status/200",
        headers = {
          ["Host"] = "zipkin-upstream-connect-timeout"
        }
      }))
      assert.res_status(200, res)

      -- wait for zero-delay timer
      helpers.wait_timer("zipkin", true, "any-finish")

      assert.logfile().has.line("zipkin request failed: timeout", true, 10)
    end)

    it("times out if upstream zipkin server takes too long to respond", function()
      local res = assert(proxy_client:send({
        method  = "GET",
        path    = "/status/200",
        headers = {
          ["Host"] = "zipkin-upstream-slow"
        }
      }))
      assert.res_status(200, res)

      -- wait for zero-delay timer
      helpers.wait_timer("zipkin", true, "any-finish")

      assert.logfile().has.line("zipkin request failed: timeout", true, 10)
    end)

    it("connection refused if upstream zipkin server is not listening", function()
      local res = assert(proxy_client:send({
        method  = "GET",
        path    = "/status/200",
        headers = {
          ["Host"] = "zipkin-upstream-refused"
        }
      }))
      assert.res_status(200, res)

      -- wait for zero-delay timer
      helpers.wait_timer("zipkin", true, "any-finish")

      assert.logfile().has.line("zipkin request failed: connection refused", true, 10)
    end)
  end)
end

for _, strategy in helpers.each_strategy() do
  describe("http_response_header_for_traceid configuration", function()
    local proxy_client, service

    setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
      }

      -- kong (http) mock upstream
      bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "http-route" },
        preserve_host = true,
      })

      -- enable zipkin plugin globally, with sample_ratio = 1
      bp.plugins:insert({
        name = "zipkin",
        config = {
          sample_ratio = 1,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          default_header_type = "b3-single",
          http_span_name = "method_path",
          http_response_header_for_traceid = "X-B3-TraceId",
        }
      })

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000",
      })

      proxy_client = helpers.proxy_client()
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("custom traceid header included in response headers", function()
      local r = proxy_client:get("/", {
        headers = {
          host  = "http-route",
        },
      })

      assert.response(r).has.status(200)
      assert.response(r).has.header("X-B3-TraceId")
      local trace_id = r.headers["X-B3-TraceId"]
      local trace_id_regex = [[^[a-f0-9]{32}$]]
      local m = ngx.re.match(trace_id, trace_id_regex, "jo")
      assert.True(m ~= nil, "trace_id does not match regex: " .. trace_id_regex)
    end)
  end)
end

for _, strategy in helpers.each_strategy() do
  describe("http_span_name configuration", function()
    local proxy_client, zipkin_client, service

    setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
      }

      -- kong (http) mock upstream
      bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "http-route" },
        preserve_host = true,
      })

      -- enable zipkin plugin globally, with sample_ratio = 1
      bp.plugins:insert({
        name = "zipkin",
        config = {
          sample_ratio = 1,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          default_header_type = "b3-single",
          http_span_name = "method_path",
        }
      })

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000",
      })

      proxy_client = helpers.proxy_client()
      zipkin_client = helpers.http_client(ZIPKIN_HOST, ZIPKIN_PORT)
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("http_span_name = 'method_path' includes path to span name", function()
      local start_s = ngx.now()

      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          host  = "http-route",
          ["zipkin-tags"] = "foo=bar; baz=qux"
        },
      })

      assert.response(r).has.status(200)

      local spans = wait_for_spans(zipkin_client, 3, service.name)
      local request_span = assert(get_span("get /", spans), "request span missing")
      local proxy_span = assert(get_span("get / (proxy)", spans), "proxy span missing")

      -- common assertions for request_span and proxy_span
      assert_span_invariants(request_span, proxy_span, 16 * 2, start_s, "kong")
    end)
  end)
end

local function setup_zipkin_old_propagation(bp, service, traceid_byte_count)
  -- enable zipkin plugin globally pointing to mock server
  bp.plugins:insert({
    name = "zipkin",
    -- enable on TCP as well (by default it is only enabled on http, https, grpc, grpcs)
    protocols = { "http", "https", "tcp", "tls", "grpc", "grpcs" },
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      traceid_byte_count = traceid_byte_count,
      static_tags = {
        { name = "static", value = "ok" },
      },
      default_header_type = "b3-single",
    }
  })

  -- header_type = "ignore", def w3c
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ignore_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      header_type = "ignore",
      default_header_type = "w3c",
    }
  })

  -- header_type = "w3c"
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_w3c_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      header_type = "w3c",
      default_header_type = "b3-single",
    }
  })

  -- header_type = "datadog"
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_dd_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      header_type = "datadog",
      default_header_type = "datadog",
    }
  })

  -- header_type = "instana"
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ins_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      header_type = "instana",
      default_header_type = "instana",
    }
  })
end

local function setup_zipkin_new_propagation(bp, service, traceid_byte_count)
  -- enable zipkin plugin globally pointing to mock server
  bp.plugins:insert({
    name = "zipkin",
    -- enable on TCP as well (by default it is only enabled on http, https, grpc, grpcs)
    protocols = { "http", "https", "tcp", "tls", "grpc", "grpcs" },
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      traceid_byte_count = traceid_byte_count,
      static_tags = {
        { name = "static", value = "ok" },
      },
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve" },
        default_format = "b3-single",
      },
    }
  })

  -- header_type = "ignore", def w3c
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ignore_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      propagation = {
        extract = {  },
        inject = { "preserve" },
        default_format = "w3c",
      },
    }
  })

  -- header_type = "w3c"
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_w3c_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve", "w3c" },
        default_format = "b3-single",
      },
    }
  })

  -- header_type = "datadog"
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_dd_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "aws", "datadog", "gcp", "instana" },
        inject = { "preserve", "datadog" },
        default_format = "datadog",
      },
    }
  })

  -- header_type = "instana"
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ins_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "aws", "datadog", "gcp", "instana" },
        inject = { "preserve", "instana" },
        default_format = "instana",
      },
    }
  })

  -- available with new configuration only:
  -- no preserve
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_no_preserve_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      propagation = {
        extract = { "b3" },
        inject = { "w3c" },
        default_format = "w3c",
      }
    }
  })

  --clear
  bp.plugins:insert({
    name = "zipkin",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_clear_host },
    }).id},
    config = {
      sample_ratio = 1,
      http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
      propagation = {
        extract = { "w3c", "ot" },
        inject = { "preserve" },
        clear = {
          "ot-tracer-traceid",
          "ot-tracer-spanid",
          "ot-tracer-sampled",
        },
        default_format = "b3",
      }
    }
  })
end

for _, strategy in helpers.each_strategy() do
for _, traceid_byte_count in ipairs({ 8, 16 }) do
for _, propagation_config in ipairs({"old", "new"}) do
describe("http integration tests with zipkin server [#"
         .. strategy .. "] traceid_byte_count: "
         .. traceid_byte_count, function()

  local proxy_client_grpc
  local service, grpc_service, tcp_service
  local route, grpc_route, tcp_route
  local zipkin_client
  local proxy_client

  lazy_setup(function()
    local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

    service = bp.services:insert {
      name = string.lower("http-" .. utils.random_string()),
    }

    if propagation_config == "old" then
      setup_zipkin_old_propagation(bp, service, traceid_byte_count)
    else
      setup_zipkin_new_propagation(bp, service, traceid_byte_count)
    end

    -- kong (http) mock upstream
    route = bp.routes:insert({
      name = string.lower("route-" .. utils.random_string()),
      service = service,
      hosts = { http_route_host },
      preserve_host = true,
    })

    -- grpc upstream
    grpc_service = bp.services:insert {
      name = string.lower("grpc-" .. utils.random_string()),
      url = helpers.grpcbin_url,
    }

    grpc_route = bp.routes:insert {
      name = string.lower("grpc-route-" .. utils.random_string()),
      service = grpc_service,
      protocols = { "grpc" },
      hosts = { "grpc-route" },
    }

    -- tcp upstream
    tcp_service = bp.services:insert({
      name = string.lower("tcp-" .. utils.random_string()),
      protocol = "tcp",
      host = helpers.mock_upstream_host,
      port = helpers.mock_upstream_stream_port,
    })

    tcp_route = bp.routes:insert {
      name = string.lower("tcp-route-" .. utils.random_string()),
      destinations = { { port = 19000 } },
      protocols = { "tcp" },
      service = tcp_service,
    }

    helpers.start_kong({
      database = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      stream_listen = helpers.get_proxy_ip(false) .. ":19000",
    })

    proxy_client = helpers.proxy_client()
    proxy_client_grpc = helpers.proxy_client_grpc()
    zipkin_client = helpers.http_client(ZIPKIN_HOST, ZIPKIN_PORT)
  end)


  teardown(function()
    helpers.stop_kong()
  end)

  it("generates spans, tags and annotations for regular requests", function()
    local start_s = ngx.now()

    local r = proxy_client:get("/", {
      headers = {
        ["x-b3-sampled"] = "1",
        host  = http_route_host,
        ["zipkin-tags"] = "foo=bar; baz=qux"
      },
    })
    assert.response(r).has.status(200)

    local spans = wait_for_spans(zipkin_client, 3, service.name)
    local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
    local request_span = assert(get_span("get", spans), "request span missing")
    local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

    -- common assertions for request_span and proxy_span
    assert_span_invariants(request_span, proxy_span, traceid_byte_count * 2, start_s, "kong")

    -- specific assertions for request_span
    local request_tags = request_span.tags
    assert.truthy(request_tags["kong.node.id"]:match("^[%x-]+$"))
    request_tags["kong.node.id"] = nil
    assert.same({
      ["http.method"] = "GET",
      ["http.path"] = "/",
      ["http.status_code"] = "200", -- found (matches server status)
      ["http.protocol"] = "HTTP/1.1",
      ["http.host"] = http_route_host,
      lc = "kong",
      static = "ok",
      foo = "bar",
      baz = "qux"
    }, request_tags)
    local consumer_port = request_span.remoteEndpoint.port
    assert_is_integer(consumer_port)
    assert.same({
      ipv4 = "127.0.0.1",
      port = consumer_port,
    }, request_span.remoteEndpoint)

    -- specific assertions for proxy_span
    assert.same(proxy_span.tags["kong.route"], route.id)
    assert.same(proxy_span.tags["kong.route_name"], route.name)
    assert.same(proxy_span.tags["peer.hostname"], "127.0.0.1")

    assert.same({
      ipv4 = helpers.mock_upstream_host,
      port = helpers.mock_upstream_port,
      serviceName = service.name,
    },
    proxy_span.remoteEndpoint)

    -- specific assertions for balancer_span
    assert.equals(balancer_span.parentId, request_span.id)
    assert.equals(request_span.name .. " (balancer try 1)", balancer_span.name)
    assert.equals("number", type(balancer_span.timestamp))

    if balancer_span.duration then
      assert.equals("number", type(balancer_span.duration))
    end

    assert.same({
      ipv4 = helpers.mock_upstream_host,
      port = helpers.mock_upstream_port,
      serviceName = service.name,
    },
    balancer_span.remoteEndpoint)
    assert.same({ serviceName = "kong" }, balancer_span.localEndpoint)
    assert.same({
      ["kong.balancer.try"] = "1",
      ["kong.route"] = route.id,
      ["kong.route_name"] = route.name,
      ["kong.service"] = service.id,
      ["kong.service_name"] = service.name,
    }, balancer_span.tags)
  end)

  it("generates spans, tags and annotations for regular requests (#grpc)", function()
    local start_s = ngx.now()

    local ok, resp = proxy_client_grpc({
      service = "hello.HelloService.SayHello",
      body = {
        greeting = "world!"
      },
      opts = {
        ["-H"] = "'x-b3-sampled: 1'",
        ["-authority"] = "grpc-route",
      }
    })
    assert(ok, resp)
    assert.truthy(resp)

    local spans = wait_for_spans(zipkin_client, 3, grpc_service.name)
    local balancer_span = assert(get_span("post (balancer try 1)", spans), "balancer span missing")
    local request_span = assert(get_span("post", spans), "request span missing")
    local proxy_span = assert(get_span("post (proxy)", spans), "proxy span missing")

    -- common assertions for request_span and proxy_span
    assert_span_invariants(request_span, proxy_span, traceid_byte_count * 2, start_s, "kong")

    -- specific assertions for request_span
    local request_tags = request_span.tags
    assert.truthy(request_tags["kong.node.id"]:match("^[%x-]+$"))
    request_tags["kong.node.id"] = nil

    assert.same({
      ["http.method"] = "POST",
      ["http.path"] = "/hello.HelloService/SayHello",
      ["http.status_code"] = "200", -- found (matches server status)
      ["http.protocol"] = "HTTP/2",
      ["http.host"] = "grpc-route",
      lc = "kong",
      static = "ok",
    }, request_tags)
    local consumer_port = request_span.remoteEndpoint.port
    assert_is_integer(consumer_port)
    assert.same({
      ipv4 = '127.0.0.1',
      port = consumer_port,
    }, request_span.remoteEndpoint)

    -- specific assertions for proxy_span
    assert.same(proxy_span.tags["kong.route"], grpc_route.id)
    assert.same(proxy_span.tags["kong.route_name"], grpc_route.name)
    assert.same(proxy_span.tags["peer.hostname"], helpers.grpcbin_host)

    -- random ip assigned by Docker to the grpcbin container
    local grpcbin_ip = proxy_span.remoteEndpoint.ipv4
    assert.same({
      ipv4 = grpcbin_ip,
      port = helpers.grpcbin_port,
      serviceName = grpc_service.name,
    },
    proxy_span.remoteEndpoint)

    -- specific assertions for balancer_span
    assert.equals(balancer_span.parentId, request_span.id)
    assert.equals(request_span.name .. " (balancer try 1)", balancer_span.name)
    assert_valid_timestamp(balancer_span.timestamp, start_s)

    if balancer_span.duration then
      assert_is_integer(balancer_span.duration)
    end

    assert.same({
      ipv4 = grpcbin_ip,
      port = helpers.grpcbin_port,
      serviceName = grpc_service.name,
    },
    balancer_span.remoteEndpoint)
    assert.same({ serviceName = "kong" }, balancer_span.localEndpoint)
    assert.same({
      ["kong.balancer.try"] = "1",
      ["kong.service"] = grpc_route.service.id,
      ["kong.service_name"] = grpc_service.name,
      ["kong.route"] = grpc_route.id,
      ["kong.route_name"] = grpc_route.name,
    }, balancer_span.tags)
  end)

  it("generates spans, tags and annotations for regular #stream requests", function()
    local start_s = ngx.now()
    local tcp = ngx.socket.tcp()
    assert(tcp:connect(helpers.get_proxy_ip(false), 19000))

    assert(tcp:send("hello\n"))

    local body = assert(tcp:receive("*a"))
    assert.equal("hello\n", body)

    assert(tcp:close())

    local spans = wait_for_spans(zipkin_client, 3, tcp_service.name)
    local balancer_span = assert(get_span("stream (balancer try 1)", spans), "balancer span missing")
    local request_span = assert(get_span("stream", spans), "request span missing")
    local proxy_span = assert(get_span("stream (proxy)", spans), "proxy span missing")

    -- request span
    assert.same("table", type(request_span))
    assert.same("string", type(request_span.id))
    assert.same("stream", request_span.name)
    assert.same(request_span.id, proxy_span.parentId)

    assert.same("SERVER", request_span.kind)

    assert.same("string", type(request_span.traceId))
    assert_valid_timestamp(request_span.timestamp, start_s)

    if request_span.duration and proxy_span.duration then
      assert.truthy(request_span.duration >= proxy_span.duration)
    end

    assert.is_nil(request_span.annotations)
    assert.same({ serviceName = "kong" }, request_span.localEndpoint)

    local request_tags = request_span.tags
    assert.truthy(request_tags["kong.node.id"]:match("^[%x-]+$"))
    request_tags["kong.node.id"] = nil
    assert.same({
      lc = "kong",
      static = "ok",
    }, request_tags)
    local consumer_port = request_span.remoteEndpoint.port
    assert_is_integer(consumer_port)
    assert.same({
      ipv4 = "127.0.0.1",
      port = consumer_port,
    }, request_span.remoteEndpoint)

    -- proxy span
    assert.same("table", type(proxy_span))
    assert.same("string", type(proxy_span.id))
    assert.same(request_span.name .. " (proxy)", proxy_span.name)
    assert.same(request_span.id, proxy_span.parentId)

    assert.same("CLIENT", proxy_span.kind)

    assert.same("string", type(proxy_span.traceId))
    assert_valid_timestamp(proxy_span.timestamp, start_s)

    if proxy_span.duration then
      assert.truthy(proxy_span.duration >= 0)
    end

    assert.equals(2, #proxy_span.annotations)
    local pann = annotations_to_hash(proxy_span.annotations)

    assert_valid_timestamp(pann["kps"], start_s)
    assert_valid_timestamp(pann["kpf"], start_s)

    assert.truthy(pann["kps"] <= pann["kpf"])
    assert.same({
      ["kong.route"] = tcp_route.id,
      ["kong.route_name"] = tcp_route.name,
      ["kong.service"] = tcp_service.id,
      ["kong.service_name"] = tcp_service.name,
      ["peer.hostname"] = "127.0.0.1",
    }, proxy_span.tags)

    assert.same({
      ipv4 = helpers.mock_upstream_host,
      port = helpers.mock_upstream_stream_port,
      serviceName = tcp_service.name,
    }, proxy_span.remoteEndpoint)

    -- specific assertions for balancer_span
    assert.equals(balancer_span.parentId, request_span.id)
    assert.equals(request_span.name .. " (balancer try 1)", balancer_span.name)
    assert.equals("number", type(balancer_span.timestamp))
    if balancer_span.duration then
      assert.equals("number", type(balancer_span.duration))
    end

    assert.same({
      ipv4 = helpers.mock_upstream_host,
      port = helpers.mock_upstream_stream_port,
      serviceName = tcp_service.name,
    }, balancer_span.remoteEndpoint)
    assert.same({ serviceName = "kong" }, balancer_span.localEndpoint)
    assert.same({
      ["kong.balancer.try"] = "1",
      ["kong.route"] = tcp_route.id,
      ["kong.route_name"] = tcp_route.name,
      ["kong.service"] = tcp_service.id,
      ["kong.service_name"] = tcp_service.name,
    }, balancer_span.tags)
  end)

  it("generates spans, tags and annotations for non-matched requests", function()
    local trace_id = gen_trace_id(traceid_byte_count)
    local start_s = ngx.now()

    local r = assert(proxy_client:send {
      method  = "GET",
      path    = "/foobar",
      headers = {
        ["x-b3-traceid"] = trace_id,
        ["x-b3-sampled"] = "1",
        ["zipkin-tags"] = "error = true"
      },
    })
    assert.response(r).has.status(404)

    local spans = wait_for_spans(zipkin_client, 2, nil, trace_id)
    assert.is_nil(get_span("get (balancer try 1)", spans), "balancer span found")
    local request_span = assert(get_span("get", spans), "request span missing")
    local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

    -- common assertions for request_span and proxy_span
    assert_span_invariants(request_span, proxy_span, #trace_id, start_s, "kong")

    -- specific assertions for request_span
    local request_tags = request_span.tags
    assert.truthy(request_tags["kong.node.id"]:match("^[%x-]+$"))
    request_tags["kong.node.id"] = nil
    assert.same({
      ["http.method"] = "GET",
      ["http.path"] = "/foobar",
      ["http.status_code"] = "404", -- note that this was "not found"
      ["http.protocol"] = 'HTTP/1.1',
      ["http.host"] = '0.0.0.0',
      lc = "kong",
      static = "ok",
      error = "true",
    }, request_tags)
    local consumer_port = request_span.remoteEndpoint.port
    assert_is_integer(consumer_port)
    assert.same({ ipv4 = "127.0.0.1", port = consumer_port }, request_span.remoteEndpoint)

    -- specific assertions for proxy_span
    assert.is_nil(proxy_span.tags)
    assert.is_nil(proxy_span.remoteEndpoint)
    assert.same({ serviceName = "kong" }, proxy_span.localEndpoint)
  end)

  it("propagates b3 headers for non-matched requests", function()
    local trace_id = gen_trace_id(traceid_byte_count)

    local r = assert(proxy_client:send {
      method  = "GET",
      path    = "/foobar",
      headers = {
        ["x-b3-traceid"] = trace_id,
        ["x-b3-sampled"] = "1",
      },
    })
    assert.response(r).has.status(404)

    local spans = wait_for_spans(zipkin_client, 2, nil, trace_id)
    assert.is_nil(get_span("get (balancer try 1)", spans), "balancer span found")
    local request_span = assert(get_span("get", spans), "request span missing")
    local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

    assert.equals(trace_id, proxy_span.traceId)
    assert.equals(trace_id, request_span.traceId)
  end)


  describe("b3 single header propagation", function()
    it("works on regular calls", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "1", parent_id),
          host = http_route_host,
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.matches(trace_id .. "%-%x+%-1%-%x+", json.headers.b3)

      local spans = wait_for_spans(zipkin_client, 3, nil, trace_id)
      local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(span_id, request_span.id)
      assert.equals(parent_id, request_span.parentId)

      assert.equals(trace_id, proxy_span.traceId)
      assert.not_equals(span_id, proxy_span.id)
      assert.equals(span_id, proxy_span.parentId)

      assert.equals(trace_id, balancer_span.traceId)
      assert.not_equals(span_id, balancer_span.id)
      assert.equals(span_id, balancer_span.parentId)
    end)

    it("works without parent_id", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s-1", trace_id, span_id),
          host = http_route_host,
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.matches(trace_id .. "%-%x+%-1%-%x+", json.headers.b3)

      local spans = wait_for_spans(zipkin_client, 3, nil, trace_id)
      local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(span_id, request_span.id)

      assert.equals(trace_id, proxy_span.traceId)
      assert.not_equals(span_id, proxy_span.id)
      assert.equals(span_id, proxy_span.parentId)

      assert.equals(trace_id, balancer_span.traceId)
      assert.not_equals(span_id, balancer_span.id)
      assert.equals(span_id, balancer_span.parentId)

    end)

    it("works with only trace_id and span_id", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s", trace_id, span_id),
          ["x-b3-sampled"] = "1",
          host = http_route_host,
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.matches(trace_id .. "%-%x+%-1%-%x+", json.headers.b3)

      local spans = wait_for_spans(zipkin_client, 3, nil, trace_id)
      local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(span_id, request_span.id)

      assert.equals(trace_id, proxy_span.traceId)
      assert.not_equals(span_id, proxy_span.id)
      assert.equals(span_id, proxy_span.parentId)

      assert.equals(trace_id, balancer_span.traceId)
      assert.not_equals(span_id, balancer_span.id)
      assert.equals(span_id, balancer_span.parentId)
    end)

    it("works on non-matched requests", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()

      local r = proxy_client:get("/foobar", {
        headers = {
          b3 = fmt("%s-%s-1", trace_id, span_id)
        },
      })
      assert.response(r).has.status(404)

      local spans = wait_for_spans(zipkin_client, 2, nil, trace_id)
      assert.is_nil(get_span("get (balancer try 1)", spans), "balancer span found")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(span_id, request_span.id)

      assert.equals(trace_id, proxy_span.traceId)
      assert.not_equals(span_id, proxy_span.id)
      assert.equals(span_id, proxy_span.parentId)
    end)
  end)


  describe("w3c traceparent header propagation", function()
    it("works on regular calls", function()
      local trace_id = gen_trace_id(16) -- w3c only admits 16-byte trace_ids
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
          host = http_route_host
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.matches("00%-" .. trace_id .. "%-%x+-01", json.headers.traceparent)

      local spans = wait_for_spans(zipkin_client, 3, nil, trace_id)
      local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(parent_id, request_span.parentId)

      assert.equals(trace_id, proxy_span.traceId)
      assert.equals(trace_id, balancer_span.traceId)
    end)

    it("works on non-matched requests", function()
      local trace_id = gen_trace_id(16) -- w3c only admits 16-bit trace_ids
      local parent_id = gen_span_id()

      local r = proxy_client:get("/foobar", {
        headers = {
          traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
        },
      })
      assert.response(r).has.status(404)

      local spans = wait_for_spans(zipkin_client, 2, nil, trace_id)
      assert.is_nil(get_span("get (balancer try 1)", spans), "balancer span found")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(parent_id, request_span.parentId)

      assert.equals(trace_id, proxy_span.traceId)
    end)
  end)

  describe("jaeger uber-trace-id header propagation", function()
    it("works on regular calls", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "1"),
          host = http_route_host
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      local expected_len = traceid_byte_count * 2
      assert.matches(('0'):rep(expected_len-#trace_id) .. trace_id .. ":%x+:" .. span_id .. ":01", json.headers["uber-trace-id"])

      local spans = wait_for_spans(zipkin_client, 3, nil, trace_id)
      local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(span_id, request_span.id)
      assert.equals(parent_id, request_span.parentId)

      assert.equals(trace_id, proxy_span.traceId)
      assert.not_equals(span_id, proxy_span.id)
      assert.equals(span_id, proxy_span.parentId)

      assert.equals(trace_id, balancer_span.traceId)
      assert.not_equals(span_id, balancer_span.id)
      assert.equals(span_id, balancer_span.parentId)
    end)

    it("works on non-matched requests", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()
      local parent_id = gen_span_id()

      local r = proxy_client:get("/foobar", {
        headers = {
          ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "1"),
        },
      })
      assert.response(r).has.status(404)

      local spans = wait_for_spans(zipkin_client, 2, nil, trace_id)
      assert.is_nil(get_span("get (balancer try 1)", spans), "balancer span found")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(span_id, request_span.id)
      assert.equals(parent_id, request_span.parentId)

      assert.equals(trace_id, proxy_span.traceId)
      assert.not_equals(span_id, proxy_span.id)
      assert.equals(span_id, proxy_span.parentId)
    end)
  end)

  describe("ot header propagation", function()
    it("works on regular calls", function()
      local trace_id = gen_trace_id(traceid_byte_count)
      local span_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          ["ot-tracer-traceid"] = trace_id,
          ["ot-tracer-spanid"] = span_id,
          ["ot-tracer-sampled"] = "1",
          host = http_route_host,
        },
      })

      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      local expected_len = traceid_byte_count * 2
      assert.equals(to_id_len(trace_id, expected_len), json.headers["ot-tracer-traceid"])

      local spans = wait_for_spans(zipkin_client, 3, nil, trace_id)
      local balancer_span = assert(get_span("get (balancer try 1)", spans), "balancer span missing")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)

      assert.equals(trace_id, proxy_span.traceId)
      assert.equals(trace_id, balancer_span.traceId)
    end)

    it("works on non-matched requests", function()
      local trace_id = gen_trace_id(8)
      local span_id = gen_span_id()

      local r = proxy_client:get("/foobar", {
        headers = {
          ["ot-tracer-traceid"] = trace_id,
          ["ot-tracer-spanid"] = span_id,
          ["ot-tracer-sampled"] = "1",
        },
      })
      assert.response(r).has.status(404)

      local spans = wait_for_spans(zipkin_client, 2, nil, trace_id)
      assert.is_nil(get_span("get (balancer try 1)", spans), "balancer span found")
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      assert.equals(trace_id, request_span.traceId)
      assert.equals(trace_id, proxy_span.traceId)
    end)
  end)

  describe("header type with 'preserve' config and no inbound headers", function()
    it("uses whatever is set in the plugin's config.default_header_type property", function()
      local r = proxy_client:get("/", {
        headers = {
          -- no tracing header
          host = http_route_host
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.not_nil(json.headers.b3)
    end)
  end)

  describe("propagation configuration", function()
    it("ignores incoming headers and uses default type", function()
      local trace_id = gen_trace_id(16)
      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          ["x-b3-traceid"] = trace_id,
          host  = http_route_ignore_host,
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      -- uses default type
      assert.is_not_nil(json.headers.traceparent)
      -- incoming trace id is ignored
      assert.not_matches("00%-" .. trace_id .. "%-%x+-01", json.headers.traceparent)
    end)

    it("propagates w3c tracing headers + incoming format (preserve + w3c)", function()
      local trace_id = gen_trace_id(16)
      local span_id = gen_span_id()
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s-1-%s", trace_id, span_id, parent_id),
          host = http_route_w3c_host
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)

      assert.matches("00%-" .. trace_id .. "%-%x+-01", json.headers.traceparent)
      -- incoming b3 is modified
      assert.not_equals(fmt("%s-%s-1-%s", trace_id, span_id, parent_id), json.headers.b3)
      assert.matches(trace_id .. "%-%x+%-1%-%x+", json.headers.b3)
    end)

    describe("propagates datadog tracing headers", function()
      it("with datadog headers in client request", function()
        local trace_id  = "1234567890"
        local r = proxy_client:get("/", {
          headers = {
            ["x-datadog-trace-id"] = trace_id,
            host = http_route_host,
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)

        assert.equals(trace_id, json.headers["x-datadog-trace-id"])
        assert.is_not_nil(tonumber(json.headers["x-datadog-parent-id"]))
      end)

      it("without datadog headers in client request", function()
        local r = proxy_client:get("/", {
          headers = { host = http_route_dd_host },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)

        assert.is_not_nil(tonumber(json.headers["x-datadog-trace-id"]))
        assert.is_not_nil(tonumber(json.headers["x-datadog-parent-id"]))
      end)
    end)

    describe("propagates instana tracing headers", function()
      it("with instana headers in client request", function()
        local trace_id = gen_trace_id(16)
        local span_id = gen_span_id()
        local r = proxy_client:get("/", {
          headers = {
            ["x-instana-t"] = trace_id,
            ["x-instana-s"] = span_id,
            host = http_route_host,
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)

        assert.equals(trace_id, json.headers["x-instana-t"])
      end)

      it("without instana headers in client request", function()
        local r = proxy_client:get("/", {
          headers = { host = http_route_ins_host },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)

        assert.is_not_nil(json.headers["x-instana-t"])
        assert.is_not_nil(json.headers["x-instana-s"])
      end)
    end)

    if propagation_config == "new" then
      it("clears non-propagated headers when configured to do so", function()
        local trace_id = gen_trace_id(16)
        local parent_id = gen_span_id()

        local r = proxy_client:get("/", {
          headers = {
            traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
            ["ot-tracer-traceid"] = trace_id,
            ["ot-tracer-spanid"] = parent_id,
            ["ot-tracer-sampled"] = "1",
            host = http_route_clear_host
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)
        assert.matches("00%-" .. trace_id .. "%-%x+-01", json.headers.traceparent)
        assert.is_nil(json.headers["ot-tracer-traceid"])
        assert.is_nil(json.headers["ot-tracer-spanid"])
        assert.is_nil(json.headers["ot-tracer-sampled"])
      end)

      it("does not preserve incoming header type if preserve is not specified", function()
        local trace_id = gen_trace_id(16)
        local span_id = gen_span_id()
        local parent_id = gen_span_id()

        local r = proxy_client:get("/", {
          headers = {
            b3 = fmt("%s-%s-1-%s", trace_id, span_id, parent_id),
            host = http_route_no_preserve_host
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)
        -- b3 was not injected, only preserved as incoming
        assert.equals(fmt("%s-%s-1-%s", trace_id, span_id, parent_id), json.headers.b3)
        -- w3c was injected
        assert.matches("00%-" .. trace_id .. "%-%x+-01", json.headers.traceparent)
      end)
    end
  end)
end)
end
end


for _, strategy in helpers.each_strategy() do
  describe("phase_duration_flavor = 'tags' configuration", function()
    local traceid_byte_count = 16
    local proxy_client_grpc
    local service, grpc_service, tcp_service
    local zipkin_client
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      -- enable zipkin plugin globally pointing to mock server
      bp.plugins:insert({
        name = "zipkin",
        -- enable on TCP as well (by default it is only enabled on http, https, grpc, grpcs)
        protocols = { "http", "https", "tcp", "tls", "grpc", "grpcs" },
        config = {
          sample_ratio = 1,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          static_tags = {
            { name = "static", value = "ok" },
          },
          default_header_type = "b3-single",
          phase_duration_flavor = "tags",
        }
      })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
      }

      -- kong (http) mock upstream
      bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "http-route" },
        preserve_host = true,
      })

      -- grpc upstream
      grpc_service = bp.services:insert {
        name = string.lower("grpc-" .. utils.random_string()),
        url = helpers.grpcbin_url,
      }

      bp.routes:insert {
        name = string.lower("grpc-route-" .. utils.random_string()),
        service = grpc_service,
        protocols = { "grpc" },
        hosts = { "grpc-route" },
      }

      -- tcp upstream
      tcp_service = bp.services:insert({
        name = string.lower("tcp-" .. utils.random_string()),
        protocol = "tcp",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_stream_port,
      })

      bp.routes:insert {
        name = string.lower("tcp-route-" .. utils.random_string()),
        destinations = { { port = 19000 } },
        protocols = { "tcp" },
        service = tcp_service,
      }

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000",
      })

      proxy_client = helpers.proxy_client()
      proxy_client_grpc = helpers.proxy_client_grpc()
      zipkin_client = helpers.http_client(ZIPKIN_HOST, ZIPKIN_PORT)
    end)


    teardown(function()
      helpers.stop_kong()
    end)

    it("generates spans, tags and annotations for regular requests", function()
      local start_s = ngx.now()

      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          host = "http-route",
          ["zipkin-tags"] = "foo=bar; baz=qux"
        },
      })
      assert.response(r).has.status(200)

      local spans = wait_for_spans(zipkin_client, 3, service.name)
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      -- common assertions for request_span and proxy_span
      assert_span_invariants(request_span, proxy_span, traceid_byte_count * 2, start_s, "kong", "tags")
    end)

    it("generates spans, tags and annotations for regular requests (#grpc)", function()
      local start_s = ngx.now()

      local ok, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-H"] = "'x-b3-sampled: 1'",
          ["-authority"] = "grpc-route",
        }
      })
      assert(ok, resp)
      assert.truthy(resp)

      local spans = wait_for_spans(zipkin_client, 3, grpc_service.name)
      local request_span = assert(get_span("post", spans), "request span missing")
      local proxy_span = assert(get_span("post (proxy)", spans), "proxy span missing")

      -- common assertions for request_span and proxy_span
      assert_span_invariants(request_span, proxy_span, traceid_byte_count * 2, start_s, "kong", "tags")
    end)

    it("generates spans, tags and annotations for regular #stream requests", function()
      local tcp = ngx.socket.tcp()
      assert(tcp:connect(helpers.get_proxy_ip(false), 19000))

      assert(tcp:send("hello\n"))

      local body = assert(tcp:receive("*a"))
      assert.equal("hello\n", body)

      assert(tcp:close())

      local spans = wait_for_spans(zipkin_client, 3, tcp_service.name)
      local request_span = assert(get_span("stream", spans), "request span missing")
      local proxy_span = assert(get_span("stream (proxy)", spans), "proxy span missing")

      -- request span
      assert.same("table", type(request_span))
      assert.same("string", type(request_span.id))
      assert.same("stream", request_span.name)
      assert.same(request_span.id, proxy_span.parentId)

      -- tags
      assert.truthy(tonumber(proxy_span.tags["kong.preread.duration_ms"]) >= 0)
    end)

  end)
end

for _, strategy in helpers.each_strategy() do
  describe("Integration tests with instrumentations enabled", function()
    local proxy_client, zipkin_client, service

    setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert {
        name = string.lower("http-" .. utils.random_string()),
      }

      -- kong (http) mock upstream
      bp.routes:insert({
        name = string.lower("route-" .. utils.random_string()),
        service = service,
        hosts = { "http-route" },
        preserve_host = true,
      })

      -- enable zipkin plugin globally, with sample_ratio = 0
      bp.plugins:insert({
        name = "zipkin",
        config = {
          sample_ratio = 0,
          http_endpoint = fmt("http://%s:%d/api/v2/spans", ZIPKIN_HOST, ZIPKIN_PORT),
          default_header_type = "b3-single",
        }
      })

      helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        tracing_instrumentations = "all",
        tracing_sampling_rate = 1,
      })

      proxy_client = helpers.proxy_client()
      zipkin_client = helpers.http_client(ZIPKIN_HOST, ZIPKIN_PORT)
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("generates spans for regular requests", function()
      local start_s = ngx.now()

      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          host  = "http-route",
          ["zipkin-tags"] = "foo=bar; baz=qux"
        },
      })
      assert.response(r).has.status(200)

      local spans = wait_for_spans(zipkin_client, 3, service.name)
      local request_span = assert(get_span("get", spans), "request span missing")
      local proxy_span = assert(get_span("get (proxy)", spans), "proxy span missing")

      -- common assertions for request_span and proxy_span
      assert_span_invariants(request_span, proxy_span, 16 * 2, start_s, "kong")
    end)
  end)
end
end
