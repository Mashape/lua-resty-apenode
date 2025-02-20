local helpers = require "spec.helpers"
local cjson = require "cjson"
local stringx = require "pl.stringx"


describe("Plugin: datadog (log)", function()
  local DEFAULT_METRICS_COUNT = 6

  lazy_setup(function()
    helpers.setenv('KONG_DATADOG_AGENT_HOST', 'localhost')
    helpers.setenv('KONG_DATADOG_AGENT_HOST_TEST', 'localhost')
    helpers.setenv('KONG_DATADOG_AGENT_PORT', '9999')
  end)

  lazy_teardown(function()
    helpers.unsetenv('KONG_DATADOG_AGENT_HOST')
    helpers.unsetenv('KONG_DATADOG_AGENT_HOST_TEST')
    helpers.unsetenv('KONG_DATADOG_AGENT_PORT')
  end)

  for _, strategy in helpers.each_strategy() do
    describe("Plugin: datadog (log) [#" .. strategy .. "]", function()
      local proxy_client

      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
          "consumers",
          "keyauth_credentials",
        })

        local consumer = bp.consumers:insert {
          username  = "foo",
          custom_id = "bar"
        }

        bp.keyauth_credentials:insert({
          key      = "kong",
          consumer = { id = consumer.id },
        })

        local route1 = bp.routes:insert {
          hosts   = { "datadog1.test" },
          service = bp.services:insert { name = "dd1" }
        }

        local route2 = bp.routes:insert {
          hosts   = { "datadog2.test" },
          service = bp.services:insert { name = "dd2" }
        }

        local route3 = bp.routes:insert {
          hosts   = { "datadog3.test" },
          service = bp.services:insert { name = "dd3" }
        }

        local route4 = bp.routes:insert {
          hosts   = { "datadog4.test" },
          service = bp.services:insert { name = "dd4" }
        }

        local route5 = bp.routes:insert {
          hosts   = { "datadog5.test" },
          service = bp.services:insert { name = "dd5" }
        }

        local route_grpc = assert(bp.routes:insert {
          protocols = { "grpc" },
          paths = { "/hello.HelloService/" },
          service = assert(bp.services:insert {
            name = "grpc",
            url = helpers.grpcbin_url,
          }),
        })

        local route6 = bp.routes:insert {
          hosts   = { "datadog6.test" },
          service = bp.services:insert { name = "dd6" }
        }

        local route7 = bp.routes:insert {
          hosts   = { "datadog7.test" },
          service = bp.services:insert { name = "dd7" }
        }

        local route8 = bp.routes:insert {
          hosts   = { "datadog8.test" },
          paths = { "/test_schema" },
          service = bp.services:insert {
            name = "dd8",
            protocol = "http",
            url = helpers.mock_upstream_url,
          }
        }

        local route9 = bp.routes:insert {
          paths = { "/serviceless" },
          no_service = true,
        }
        
        local route10 = bp.routes:insert {
          name    = "kong-sample_route",
          hosts   = { "datadog10.test" },
          service = bp.services:insert { name = "dd10" }
        }
        
        local route11 = bp.routes:insert {
          name    = "kong-sample_route.11",
          hosts   = { "datadog11.test" },
          service = bp.services:insert { name = "dd11" }
        }

        bp.plugins:insert {
          name     = "key-auth",
          route = { id = route1.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route1.id },
          config   = {
            host   = "127.0.0.1",
            port   = 9999,
          },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route2.id },
          config   = {
            host    = "127.0.0.1",
            port    = 9999,
            metrics = {
              {
                name        = "request_count",
                stat_type   = "counter",
                sample_rate = 1,
              },
            },
          },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route3.id },
          config   = {
            host    = "127.0.0.1",
            port    = 9999,
            metrics = {
              {
                name        = "request_count",
                stat_type   = "counter",
                sample_rate = 1,
                tags        = {"T2:V2", "T3:V3", "T4"},
              },
              {
                name        = "latency",
                stat_type   = "gauge",
                sample_rate = 1,
                tags        = {"T2:V2:V3", "T4"},
              },
              {
                name        = "request_size",
                stat_type   = "distribution",
                sample_rate = 1,
                tags        = {},
              },
            },
          },
        }

        bp.plugins:insert {
          name       = "key-auth",
          route = { id = route4.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route4.id },
          config   = {
            host   = "127.0.0.1",
            port   = 9999,
            prefix = "prefix",
          },
        }

        bp.plugins:insert {
          name     = "key-auth",
          route = { id = route5.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route5.id },
          config   = {
            host = ngx.null, -- plugin takes above env var value, if set to null
            port = ngx.null, -- plugin takes above env var value, if set to null
          },
        }

        bp.plugins:insert {
          name       = "key-auth",
          route = { id = route_grpc.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route_grpc.id },
          config   = {
            host   = "127.0.0.1",
            port   = 9999,
          },
        }

        bp.plugins:insert {
          name     = "key-auth",
          route = { id = route6.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route6.id },
          config   = {
            host             = "127.0.0.1",
            port             = 9999,
            service_name_tag = "upstream",
            status_tag       = "http_status",
            consumer_tag     = "user",
          },
        }

        bp.plugins:insert {
          name     = "key-auth",
          route = { id = route7.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route7.id },
          config   = {
            host             = "127.0.0.1",
            port             = 9999,
            queue_size       = 2,
          },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route8.id },
          config   = {
            host             = "{vault://env/kong-datadog-agent-host-test}",
            port             = 9999,
            queue_size       = 2,
          },
        }

        bp.plugins:insert {
          name     = "datadog",
          route    = { id = route9.id },
          config   = {
            host             = "127.0.0.1",
            port             = 9999,
            queue_size       = 2,
          },
        }

        bp.plugins:insert {
          name     = "request-termination",
          route    = { id = route9.id },
          config   = {
            status_code = 200,
            message     = "OK",
          }
        }

        bp.plugins:insert {
          name     = "key-auth",
          route = { id = route10.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route10.id },
          config   = {
            host   = "127.0.0.1",
            port   = 9999,
          },
        }

        bp.plugins:insert {
          name     = "key-auth",
          route = { id = route11.id },
        }

        bp.plugins:insert {
          name     = "datadog",
          route = { id = route11.id },
          config           = {
            host           = "127.0.0.1",
            port           = 9999,
            route_name_tag = "kong_route_name_tag",
          },
        }

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          vaults = "env",
        }))

        proxy_client = helpers.proxy_client()
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("logs metrics over UDP", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog1.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#name:dd1,status:200,consumer:bar,app:kong" , gauges)
        assert.contains("kong.latency:%d+|ms|#name:dd1,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d+|ms|#name:dd1,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d+|ms|#name:dd1,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d+|ms|#name:dd1,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#name:dd1,status:200,consumer:bar,app:kong", gauges, true)
      end)

      it("logs metrics over UDP #grpc", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local grpc_cleint = assert(helpers.proxy_client_grpc())

        local ok, res = grpc_cleint{
          service = "hello.HelloService.SayHello",
          opts = {
            ["-H"] = "'apikey: kong'",
          },
        }
        assert.truthy(ok, res)
        assert.same({ reply = "hello noname" }, cjson.decode(res))

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#name:grpc,status:200,consumer:bar,app:kong" , gauges)
        assert.contains("kong.latency:%d+|ms|#name:grpc,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d+|ms|#name:grpc,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d+|ms|#name:grpc,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d+|ms|#name:grpc,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#name:grpc,status:200,consumer:bar,app:kong", gauges, true)
      end)

      it("logs metrics over UDP with custom prefix", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog4.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("prefix.request.count:1|c|#name:dd4,status:200,consumer:bar,app:kong",gauges)
        assert.contains("prefix.latency:%d+|ms|#name:dd4,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("prefix.request.size:%d+|ms|#name:dd4,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("prefix.response.size:%d+|ms|#name:dd4,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("prefix.upstream_latency:%d+|ms|#name:dd4,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("prefix.kong_latency:%d*|ms|#name:dd4,status:200,consumer:bar,app:kong", gauges, true)
      end)

      it("logs metrics over UDP with custom tag names", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog6.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#upstream:dd6,http_status:200,user:bar,app:kong",gauges)
        assert.contains("kong.latency:%d+|ms|#upstream:dd6,http_status:200,user:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d+|ms|#upstream:dd6,http_status:200,user:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d+|ms|#upstream:dd6,http_status:200,user:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d+|ms|#upstream:dd6,http_status:200,user:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#upstream:dd6,http_status:200,user:bar,app:kong", gauges, true)
      end)

      it("logs only given metrics", function()
        local thread = helpers.udp_server(9999, 1)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200",
          headers = {
            ["Host"] = "datadog2.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        gauges = { gauges } -- as thread:join() returns a string in case of 1
        assert.equal(1, #gauges)
        assert.contains("kong.request.count:1|c|#name:dd2,status:200", gauges)
      end)

      it("logs metrics with tags", function()
        local thread = helpers.udp_server(9999, 3)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200",
          headers = {
            ["Host"] = "datadog3.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.contains("kong.request.count:1|c|#name:dd3,status:200,T2:V2,T3:V3,T4", gauges)
        assert.contains("kong.latency:%d+|g|#name:dd3,status:200,T2:V2:V3,T4", gauges, true)
        assert.contains("kong.request.size:%d+|d|#name:dd3,status:200", gauges, true)
      end)

      it("logs metrics to host/port defined via environment variables", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog5.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#name:dd5,status:200,consumer:bar,app:kong" , gauges)
        assert.contains("kong.latency:%d+|ms|#name:dd5,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d+|ms|#name:dd5,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d+|ms|#name:dd5,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d+|ms|#name:dd5,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#name:dd5,status:200,consumer:bar,app:kong", gauges, true)
      end)

      it("logs metrics in several batches", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog7.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#name:dd7,status:200,consumer:bar,app:kong" , gauges)
        assert.contains("kong.latency:%d+|ms|#name:dd7,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d+|ms|#name:dd7,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d+|ms|#name:dd7,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d+|ms|#name:dd7,status:200,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#name:dd7,status:200,consumer:bar,app:kong", gauges, true)
      end)

      -- the purpose of this test case is to test the batch queue 
      -- finish processing messages in one time(no retries)
      it("no more messages than expected", function()
        local thread = helpers.udp_server(9999, 10, 10)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog7.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
      end)

      it("should not return a runtime error (regression)", function()
        local thread = helpers.udp_server(9999, 1, 1)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/NonMatch",
          headers = {
            ["Host"] = "fakedns.test"
          }
        })

        assert.res_status(404, res)
        assert.logfile().has.no.line("attempt to index field 'api' (a nil value)", true)

        -- make a valid request to make thread end
        assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200",
          headers = {
            ["Host"] = "datadog3.test"
          }
        })

        thread:join()
      end)

      it("referenceable fields works", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT, 6)
        local another_proxy_client = helpers.proxy_client()

        local res = assert(another_proxy_client:send {
          method  = "GET",
          path    = "/test_schema",
          headers = {
            ["Host"] = "datadog8.test"
          }
        })

        assert.res_status(200, res)

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
      end)

      it("logs metrics with route name over UDP", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog10.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()

        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#name:dd10,status:200,route:kong-sample_route,consumer:bar,app:kong" , gauges)
        assert.contains("kong.latency:%d*|ms|#name:dd10,status:200,route:kong-sample_route,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d*|ms|#name:dd10,status:200,route:kong-sample_route,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d*|ms|#name:dd10,status:200,route:kong-sample_route,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d*|ms|#name:dd10,status:200,route:kong-sample_route,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#name:dd10,status:200,route:kong-sample_route,consumer:bar,app:kong", gauges, true)
      end)

      it("logs metrics with different route name tag over UDP", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)

        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/status/200?apikey=kong",
          headers = {
            ["Host"] = "datadog11.test"
          }
        })
        assert.res_status(200, res)

        local ok, gauges = thread:join()

        assert.True(ok)
        assert.equal(DEFAULT_METRICS_COUNT, #gauges)
        assert.contains("kong.request.count:1|c|#name:dd11,status:200,kong_route_name_tag:kong-sample_route_11,consumer:bar,app:kong" , gauges)
        assert.contains("kong.latency:%d+|ms|#name:dd11,status:200,kong_route_name_tag:kong-sample_route_11,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.request.size:%d+|ms|#name:dd11,status:200,kong_route_name_tag:kong-sample_route_11,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.response.size:%d+|ms|#name:dd11,status:200,kong_route_name_tag:kong-sample_route_11,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.upstream_latency:%d+|ms|#name:dd11,status:200,kong_route_name_tag:kong-sample_route_11,consumer:bar,app:kong", gauges, true)
        assert.contains("kong.kong_latency:%d*|ms|#name:dd11,status:200,kong_route_name_tag:kong-sample_route_11,consumer:bar,app:kong", gauges, true)
      end)

      it("datadog plugin is triggered for serviceless routes", function()
        local thread = helpers.udp_server(9999, DEFAULT_METRICS_COUNT)
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/serviceless",
        })

        local body = assert.res_status(200, res)
        assert.equals(body, '{"message":"OK"}')

        local ok, gauges = thread:join()
        assert.True(ok)
        assert.equals(DEFAULT_METRICS_COUNT, #gauges)

        for _, g in ipairs(gauges) do
          -- tags start with `#`
          local tmp = stringx.split(g, '#')
          local tag_idx = #tmp
          assert(tag_idx == 2, "Error: missing tags")
          local tags = tmp[tag_idx]
          assert(tags, "Error: missing tags")
          assert(string.match(tags, "name:,"), "Error: the value of `name` must be an empty string for serviceless routes")
        end
      end)
    end)
  end

end)
