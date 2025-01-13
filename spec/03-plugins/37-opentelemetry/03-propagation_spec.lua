local helpers = require "spec.helpers"
local cjson = require "cjson"
local pretty = require "pl.pretty"
local to_hex = require "resty.string".to_hex
local get_rand_bytes = require("kong.tools.rand").get_rand_bytes

local fmt = string.format

local TCP_PORT = 35001

local http_route_host             = "http-route"
local http_route_ignore_host      = "http-route-ignore"
local http_route_w3c_host         = "http-route-w3c"
local http_route_dd_host          = "http-route-dd"
local http_route_b3_single_host   = "http-route-b3-single"
local http_route_ins_host         = "http-route-ins"
local http_route_clear_host       = "http-clear-route"
local http_route_no_preserve_host = "http-no-preserve-route"

local function gen_trace_id()
  return to_hex(get_rand_bytes(16))
end


local function gen_span_id()
  return to_hex(get_rand_bytes(8))
end

local function get_span(name, spans)
  for _, span in ipairs(spans) do
    if span.name == name then
      return span
    end
  end
end

local function assert_has_span(name, spans)
  local span = get_span(name, spans)
  assert.is_truthy(span, fmt("\nExpected to find %q span in:\n%s\n",
                             name, pretty.write(spans)))
  return span
end

local function get_span_by_id(spans, id)
  for _, span in ipairs(spans) do
    if span.span_id == id then
      return span
    end
  end
end

local function assert_correct_trace_hierarchy(spans, incoming_span_id)
  for _, span in ipairs(spans) do
    if span.name == "kong" then
      -- if there is an incoming span id, it should be the parent of the root span
      if incoming_span_id then
        assert.equals(incoming_span_id, span.parent_id)
      end

    else
      -- all other spans in this trace should have a local span as parent
      assert.not_equals(incoming_span_id, span.parent_id)
      assert.is_truthy(get_span_by_id(spans, span.parent_id))
    end
  end
end

local function setup_otel_old_propagation(bp, service)
  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_host },
    }).id},
    config = {
      -- fake endpoint, request to backend will sliently fail
      traces_endpoint = "http://localhost:8080/v1/traces",
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ignore_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      header_type = "ignore",
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_w3c_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      header_type = "w3c",
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_dd_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      header_type = "datadog",
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_b3_single_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      header_type = "b3-single",
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ins_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      header_type = "instana",
    }
  })
end

-- same configurations as "setup_otel_old_propagation", using the new
-- propagation configuration fields
local function setup_otel_new_propagation(bp, service)
  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve" },
        default_format = "w3c",
      }
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ignore_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      propagation = {
        extract = { },
        inject = { "preserve" },
        default_format = "w3c",
      }
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_w3c_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve", "w3c" },
        default_format = "w3c",
      }
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_dd_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve", "datadog" },
        default_format = "datadog",
      }
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_b3_single_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve", "b3-single" },
        default_format = "w3c",
      }
    }
  })

  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_ins_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      propagation = {
        extract = { "b3", "w3c", "jaeger", "ot", "datadog", "aws", "gcp", "instana" },
        inject = { "preserve", "instana" },
        default_format = "instana",
      }
    }
  })
  -- available with new configuration only:
  -- no preserve
  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_no_preserve_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
      -- old configuration ignored when new propagation configuration is provided
      header_type = "preserve",
      propagation = {
        extract = { "b3" },
        inject = { "w3c" },
        default_format = "w3c",
      }
    }
  })

  -- clear
  bp.plugins:insert({
    name = "opentelemetry",
    route = {id = bp.routes:insert({
      service = service,
      hosts = { http_route_clear_host },
    }).id},
    config = {
      traces_endpoint = "http://localhost:8080/v1/traces",
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
for _, instrumentations in ipairs({"all", "off"}) do
for _, sampling_rate in ipairs({1, 0}) do
for _, propagation_config in ipairs({"old", "new"}) do
describe("propagation tests #"    .. strategy         ..
         " instrumentations: #"   .. instrumentations ..
         " sampling_rate: "       .. sampling_rate    ..
         " propagation config: #" .. propagation_config, function()
  local service
  local proxy_client

  local sampled_flag_w3c
  local sampled_flag_b3
  if instrumentations == "all" and sampling_rate == 1 then
    sampled_flag_w3c = "01"
    sampled_flag_b3 = "1"
  else
    sampled_flag_w3c = "00"
    sampled_flag_b3 = "0"
  end

  lazy_setup(function()
    local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

    service = bp.services:insert()

    if propagation_config == "old" then
      setup_otel_old_propagation(bp, service)
    else
      setup_otel_new_propagation(bp, service)
    end

    helpers.start_kong({
      database = strategy,
      plugins = "bundled",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      tracing_instrumentations = instrumentations,
      tracing_sampling_rate = sampling_rate,
    })

    proxy_client = helpers.proxy_client()
  end)

  teardown(function()
    helpers.stop_kong()
  end)

  it("default propagation headers (w3c)", function()
    local r = proxy_client:get("/", {
      headers = {
        host = http_route_host,
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.matches("00%-%x+-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
  end)

  it("propagates tracing headers (b3 request)", function()
    local trace_id = gen_trace_id()
    local r = proxy_client:get("/", {
      headers = {
        ["x-b3-sampled"] = "1",
        ["x-b3-traceid"] = trace_id,
        host  = http_route_host,
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.equals(trace_id, json.headers["x-b3-traceid"])
  end)

  describe("propagates tracing headers (b3-single request)", function()
    it("with parent_id", function()
      local trace_id = gen_trace_id()
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
      assert.matches(trace_id .. "%-%x+%-" .. sampled_flag_b3 .. "%-%x+", json.headers.b3)
    end)

    it("without parent_id", function()
      local trace_id = gen_trace_id()
      local span_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s-1", trace_id, span_id),
          host = http_route_host,
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.matches(trace_id .. "%-%x+%-" .. sampled_flag_b3, json.headers.b3)
    end)

    it("reflects the disabled sampled flag of the incoming tracing header", function()
      local trace_id = gen_trace_id()
      local span_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s-0", trace_id, span_id),
          host = http_route_host,
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      -- incoming header has sampled=0: always disabled by
      -- parent-based sampler
      assert.matches(trace_id .. "%-%x+%-0", json.headers.b3)
    end)
  end)

  it("propagates w3c tracing headers", function()
    local trace_id = gen_trace_id() -- w3c only admits 16-byte trace_ids
    local parent_id = gen_span_id()

    local r = proxy_client:get("/", {
      headers = {
        traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
        host = http_route_host
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
  end)

  it("defaults to w3c without propagating when header_type set to ignore and w3c headers sent", function()
    local trace_id = gen_trace_id()
    local parent_id = gen_span_id()

    local r = proxy_client:get("/", {
      headers = {
        traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
        host = http_route_ignore_host
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.is_not_nil(json.headers.traceparent)
    -- incoming trace id is ignored
    assert.not_matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
  end)

  it("defaults to w3c without propagating when header_type set to ignore and b3 headers sent", function()
    local trace_id = gen_trace_id()
    local r = proxy_client:get("/", {
      headers = {
        ["x-b3-sampled"] = "1",
        ["x-b3-traceid"] = trace_id,
        host  = http_route_ignore_host,
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.is_not_nil(json.headers.traceparent)
    -- incoming trace id is ignored
    assert.not_matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
  end)

  it("propagates w3c tracing headers when header_type set to w3c", function()
    local trace_id = gen_trace_id()
    local parent_id = gen_span_id()

    local r = proxy_client:get("/", {
      headers = {
        traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
        host = http_route_w3c_host
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
  end)

  it("propagates w3c tracing headers + incoming format (preserve + w3c)", function()
    local trace_id = gen_trace_id()
    local span_id = gen_span_id()
    local parent_id = gen_span_id()

    local r = proxy_client:get("/", {
      headers = {
        b3 = fmt("%s-%s-%s-%s", trace_id, span_id, sampled_flag_b3, parent_id),
        host = http_route_w3c_host
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
    assert.not_equals(fmt("%s-%s-%s-%s", trace_id, span_id, sampled_flag_b3, parent_id), json.headers.b3)
    assert.matches(trace_id .. "%-%x+%-" .. sampled_flag_b3 .. "%-%x+", json.headers.b3)
    -- if no instrumentation is enabled no new spans are created so the
    -- incoming span is the parent of the outgoing span
    if instrumentations == "off" then
      assert.matches(trace_id .. "%-%x+%-" .. sampled_flag_b3 .. "%-" .. span_id, json.headers.b3)
    end
  end)

  it("propagates b3-single tracing headers when header_type set to b3-single", function()
    local trace_id = gen_trace_id()
    local span_id = gen_span_id()
    local parent_id = gen_span_id()

    local r = proxy_client:get("/", {
      headers = {
        b3 = fmt("%s-%s-%s-%s", trace_id, span_id, sampled_flag_b3, parent_id),
        host = http_route_b3_single_host
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)
    assert.not_equals(fmt("%s-%s-%s-%s", trace_id, span_id, sampled_flag_b3, parent_id), json.headers.b3)
    assert.matches(trace_id .. "%-%x+%-" .. sampled_flag_b3 .. "%-%x+", json.headers.b3)
  end)

  it("propagates jaeger tracing headers", function()
    local trace_id = gen_trace_id()
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
    -- Trace ID is left padded with 0 for assert
    assert.matches( ('0'):rep(32-#trace_id) .. trace_id .. ":%x+:%x+:" .. sampled_flag_w3c, json.headers["uber-trace-id"])
  end)

  it("propagates ot headers", function()
    local trace_id = gen_trace_id()
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

    assert.equals(trace_id, json.headers["ot-tracer-traceid"])
  end)

  it("propagates instana headers", function()
    local trace_id = gen_trace_id()
    local span_id = gen_span_id()
    local r = proxy_client:get("/", {
      headers = {
        ["x-instana-t"] = trace_id,
        ["x-instana-s"] = span_id,
        host = http_route_ins_host,
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)

    assert.equals(trace_id, json.headers["x-instana-t"])
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


  it("propagate spwaned span with ot headers", function()
    local r = proxy_client:get("/", {
      headers = {
        host = http_route_host,
      },
    })
    local body = assert.response(r).has.status(200)
    local json = cjson.decode(body)

    local traceparent = json.headers["traceparent"]

    local m = assert(ngx.re.match(traceparent, [[00\-([0-9a-f]+)\-([0-9a-f]+)\-([0-9a-f]+)]]))

    assert.same(32, #m[1])
    assert.same(16, #m[2])
    assert.same(sampled_flag_w3c, m[3])
  end)

  if propagation_config == "new" then
    it("clears non-propagated headers when configured to do so", function()
      local trace_id = gen_trace_id()
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
      assert.matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
      assert.is_nil(json.headers["ot-tracer-traceid"])
      assert.is_nil(json.headers["ot-tracer-spanid"])
      assert.is_nil(json.headers["ot-tracer-sampled"])
    end)

    it("does not preserve incoming header type if preserve is not specified", function()
      local trace_id = gen_trace_id()
      local span_id = gen_span_id()
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          b3 = fmt("%s-%s-%s-%s", trace_id, span_id, sampled_flag_b3, parent_id),
          host = http_route_no_preserve_host
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      -- b3 was not injected, only preserved as incoming
      assert.equals(fmt("%s-%s-%s-%s", trace_id, span_id, sampled_flag_b3, parent_id), json.headers.b3)
      -- w3c was injected
      assert.matches("00%-" .. trace_id .. "%-%x+-" .. sampled_flag_w3c, json.headers.traceparent)
    end)
  end
end)
end

for _, sampling_rate in ipairs({1, 0, 0.5}) do
  describe("propagation tests #" .. strategy .. " instrumentations: " .. instrumentations .. " dynamic sampling_rate: " .. sampling_rate, function()
    local service
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" })

      service = bp.services:insert()

      bp.plugins:insert({
        name = "opentelemetry",
        route = {id = bp.routes:insert({
          service = service,
          hosts = { "http-route" },
        }).id},
        config = {
          -- fake endpoint, request to backend will sliently fail
          traces_endpoint = "http://localhost:8080/v1/traces",
          sampling_rate = sampling_rate,
        }
      })

      helpers.start_kong({
        database = strategy,
        plugins = "bundled",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        tracing_instrumentations = instrumentations,
      })

      proxy_client = helpers.proxy_client()
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    it("propagates tracing headers (b3 request)", function()
      local trace_id = gen_trace_id()
      local r = proxy_client:get("/", {
        headers = {
          ["x-b3-sampled"] = "1",
          ["x-b3-traceid"] = trace_id,
          host  = "http-route",
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.equals(trace_id, json.headers["x-b3-traceid"])
    end)

    describe("propagates tracing headers (b3-single request)", function()
      it("with parent_id", function()
        local trace_id = gen_trace_id()
        local span_id = gen_span_id()
        local parent_id = gen_span_id()

        local r = proxy_client:get("/", {
          headers = {
            b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "1", parent_id),
            host = "http-route",
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)
        assert.matches(trace_id .. "%-%x+%-%x+%-%x+", json.headers.b3)
      end)
    end)

    it("propagates w3c tracing headers", function()
      local trace_id = gen_trace_id() -- w3c only admits 16-byte trace_ids
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          traceparent = fmt("00-%s-%s-01", trace_id, parent_id),
          host = "http-route"
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      assert.matches("00%-" .. trace_id .. "%-%x+%-%x+", json.headers.traceparent)
    end)

    it("propagates jaeger tracing headers", function()
      local trace_id = gen_trace_id()
      local span_id = gen_span_id()
      local parent_id = gen_span_id()

      local r = proxy_client:get("/", {
        headers = {
          ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "1"),
          host = "http-route"
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)
      -- Trace ID is left padded with 0 for assert
      assert.matches( ('0'):rep(32-#trace_id) .. trace_id .. ":%x+:%x+:%x+", json.headers["uber-trace-id"])
    end)

    it("propagates ot headers", function()
      local trace_id = gen_trace_id()
      local span_id = gen_span_id()
      local r = proxy_client:get("/", {
        headers = {
          ["ot-tracer-traceid"] = trace_id,
          ["ot-tracer-spanid"] = span_id,
          ["ot-tracer-sampled"] = "1",
          host = "http-route",
        },
      })
      local body = assert.response(r).has.status(200)
      local json = cjson.decode(body)

      assert.equals(trace_id, json.headers["ot-tracer-traceid"])
    end)

    describe("propagates datadog tracing headers", function()
      it("with datadog headers in client request", function()
        local trace_id  = "7532726115487256575"
        local r = proxy_client:get("/", {
          headers = {
            ["x-datadog-trace-id"] = trace_id,
            host = "http-route",
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)

        assert.equals(trace_id, json.headers["x-datadog-trace-id"])
        assert.is_not_nil(tonumber(json.headers["x-datadog-parent-id"]))
      end)

      it("with a shorter-than-64b trace_id", function()
        local trace_id  = "1234567890"
        local r = proxy_client:get("/", {
          headers = {
            ["x-datadog-trace-id"] = trace_id,
            host = "http-route",
          },
        })
        local body = assert.response(r).has.status(200)
        local json = cjson.decode(body)

        assert.equals(trace_id, json.headers["x-datadog-trace-id"])
        assert.is_not_nil(tonumber(json.headers["x-datadog-parent-id"]))
      end)
    end)
  end)
  end
end
end

for _, instrumentation in ipairs({ "request", "request,balancer", "all" }) do
describe("propagation tests with enabled " .. instrumentation .. " instrumentation #" .. strategy, function()
  local service, route
  local proxy_client

  lazy_setup(function()
    local bp = helpers.get_db_utils(strategy, { "services", "routes", "plugins" }, { "tcp-trace-exporter" })

    service = bp.services:insert()

    route = bp.routes:insert({
      service = service,
      hosts = { "http-route" },
    })

    bp.plugins:insert({
      name = "opentelemetry",
      route = {id = route.id},
      config = {
        traces_endpoint = "http://localhost:8080/v1/traces",
      }
    })

    bp.plugins:insert({
      name = "tcp-trace-exporter",
      config = {
        host = "127.0.0.1",
        port = TCP_PORT,
        custom_spans = false,
      }
    })

    helpers.start_kong({
      database = strategy,
      plugins = "bundled,tcp-trace-exporter",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      tracing_instrumentations = instrumentation,
      tracing_sampling_rate = 1,
    })

    proxy_client = helpers.proxy_client()
  end)

  teardown(function()
    helpers.stop_kong()
  end)

  it("sets the outgoint parent span's ID correctly (issue #11294)", function()
    local trace_id = gen_trace_id()
    local incoming_span_id = gen_span_id()
    local thread = helpers.tcp_server(TCP_PORT)

    local r = proxy_client:get("/", {
      headers = {
        traceparent = fmt("00-%s-%s-01", trace_id, incoming_span_id),
        host = "http-route"
      },
    })
    local body = assert.response(r).has.status(200)

    local _, res = thread:join()
    assert.is_string(res)
    local spans = cjson.decode(res)

    local parent_span
    if instrumentation == "request" then
      -- balancer instrumentation is not enabled,
      -- the outgoing parent span is the root span
      parent_span = assert_has_span("kong", spans)
    else
      -- balancer instrumentation is enabled,
      -- the outgoing parent span is the balancer span
      parent_span = assert_has_span("kong.balancer", spans)
    end

    local json = cjson.decode(body)
    assert.matches("00%-" .. trace_id .. "%-" .. parent_span.span_id .. "%-01", json.headers.traceparent)

    assert_correct_trace_hierarchy(spans, incoming_span_id)
  end)

  it("disables sampling when incoming header has sampled disabled", function()
    local trace_id = gen_trace_id()
    local incoming_span_id = gen_span_id()
    local thread = helpers.tcp_server(TCP_PORT)

    local r = proxy_client:get("/", {
      headers = {
        traceparent = fmt("00-%s-%s-00", trace_id, incoming_span_id),
        host = "http-route"
      },
    })
    assert.response(r).has.status(200)

    local _, res = thread:join()
    assert.is_string(res)
    local spans = cjson.decode(res)
    assert.equals(0, #spans, res)
  end)

end)
end
end
