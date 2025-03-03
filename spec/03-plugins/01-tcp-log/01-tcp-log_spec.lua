local cjson    = require "cjson"
local helpers  = require "spec.helpers"


local TCP_PORT = 35001
local MESSAGE = "echo, ping, pong. echo, ping, pong. echo, ping, pong.\n"


for _, strategy in helpers.each_strategy() do
  describe("Plugin: tcp-log (log) [#" .. strategy .. "]", function()
    local proxy_client, proxy_ssl_client
    local proxy_client_grpc, proxy_client_grpcs

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      })

      local route = bp.routes:insert {
        hosts = { "tcp_logging.test" },
      }

      bp.plugins:insert {
        route = { id = route.id },
        name     = "tcp-log",
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
        },
      }

      bp.plugins:insert {
        name    = "post-function",
        route   = { id = route.id },
        config  = { access = { [[
          local header = kong.request.get_header("x-ssl-client-verify")
          if header then
            kong.client.tls.set_client_verify("SUCCESS")
          end
        ]]
        }, },
      }


      local route2 = bp.routes:insert {
        hosts = { "tcp_logging_tls.test" },
      }

      bp.plugins:insert {
        route = { id = route2.id },
        name     = "tcp-log",
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
          tls    = true,
        },
      }

      local grpc_service = assert(bp.services:insert {
        name = "grpc-service",
        url = helpers.grpcbin_url,
      })

      local route3 = assert(bp.routes:insert {
        service = grpc_service,
        protocols = { "grpc" },
        hosts = { "tcp_logging_grpc.test" },
      })

      bp.plugins:insert {
        route = { id = route3.id },
        name     = "tcp-log",
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
        },
      }

      local grpcs_service = assert(bp.services:insert {
        name = "grpcs-service",
        url = helpers.grpcbin_ssl_url,
      })

      local route4 = assert(bp.routes:insert {
        service = grpcs_service,
        protocols = { "grpcs" },
        hosts = { "tcp_logging_grpcs.test" },
      })

      bp.plugins:insert {
        route = { id = route4.id },
        name     = "tcp-log",
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
        },
      }

      local route5 = bp.routes:insert {
        hosts = { "early_termination.example.test" },
      }

      bp.plugins:insert {
        route = { id = route5.id },
        name     = "tcp-log",
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
        },
      }

      bp.plugins:insert {
        name   = "request-termination",
        route  = { id = route5.id },
        config = {
          status_code  = 200,
          content_type = "text/plain",
          body         = "hello!",
        },
      }

      local tcp_srv = bp.services:insert({
        name = "tcp",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_stream_port,
        protocol = "tcp"
      })

      local tcp_route = bp.routes:insert {
        destinations = {
          { port = 19000, },
        },
        protocols = {
          "tcp",
        },
        service = tcp_srv,
      }

      bp.plugins:insert {
        route = { id = tcp_route.id },
        name     = "tcp-log",
        protocols = { "tcp", "tls", },
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
        },
      }

      local tls_srv = bp.services:insert({
        name = "tls",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_stream_ssl_port,
        protocol = "tls"
      })

      local tls_route = bp.routes:insert {
        destinations = {
          { port = 19443, },
        },
        protocols = { "tls", },
        service = tls_srv,
      }

      bp.plugins:insert {
        route = { id = tls_route.id },
        name     = "tcp-log",
        protocols = { "tcp", "tls", },
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
        },
      }

      local route6 = bp.routes:insert {
        hosts = { "custom_tcp_logging.test" },
      }

      bp.plugins:insert {
        route = { id = route6.id },
        name     = "tcp-log",
        config   = {
          host   = "127.0.0.1",
          port   = TCP_PORT,
          custom_fields_by_lua = {
            new_field = "return 123",
            ["nested.keys"] = "return 456",
            ["escape\\.dots"] = "return 789",
            ["nested.escape\\.dots"] = "return 135",
            route = "return nil", -- unset route field
          }
        },
      }

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000," ..
                        helpers.get_proxy_ip(false) .. ":19443 ssl"
      }))

      proxy_client = helpers.proxy_client()
      proxy_ssl_client = helpers.proxy_ssl_client()
      proxy_client_grpc = helpers.proxy_client_grpc()
      proxy_client_grpcs = helpers.proxy_client_grpcs()
    end)

    lazy_teardown(function()
      if proxy_client then
        proxy_client:close()
      end

      helpers.stop_kong()
    end)

    it("logs to TCP", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local r = assert(proxy_client:send {
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "tcp_logging.test",
        },
      })
      assert.response(r).has.status(200)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)
      assert.equal("127.0.0.1", log_message.client_ip)

      -- Since it's over HTTP, let's make sure there are no TLS information
      assert.is_nil(log_message.request.tls)
    end)

    describe("custom log values by lua", function()
      it("logs custom values", function()
        local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

        -- Making the request
        local r = assert(proxy_client:send {
          method  = "GET",
          path    = "/request",
          headers = {
            host  = "custom_tcp_logging.test",
          },
        })
        assert.response(r).has.status(200)

        -- Getting back the TCP server input
        local ok, res = thread:join()
        assert.True(ok)
        assert.is_string(res)

        -- Making sure it's alright
        local log_message = cjson.decode(res)
        assert.equal("127.0.0.1", log_message.client_ip)

        -- Since it's over HTTP, let's make sure there are no TLS information
        assert.same(123, log_message.new_field)
        assert.same(456, log_message.nested.keys)
        assert.same(789, log_message["escape.dots"])
        assert.same(135, log_message.nested["escape.dots"])
      end)

      it("unsets existing log values", function()
        local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

        -- Making the request
        local r = assert(proxy_client:send {
          method  = "GET",
          path    = "/request",
          headers = {
            host  = "custom_tcp_logging.test",
          },
        })
        assert.response(r).has.status(200)

        -- Getting back the TCP server input
        local ok, res = thread:join()
        assert.True(ok)
        assert.is_string(res)

        -- Making sure it's alright
        local log_message = cjson.decode(res)
        assert.equal("127.0.0.1", log_message.client_ip)

        -- Since it's over HTTP, let's make sure there are no TLS information
        assert.same(nil, log_message.route)
      end)
    end)

    it("logs to TCP (#grpc)", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local ok, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "tcp_logging_grpc.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)
      assert.equal("127.0.0.1", log_message.client_ip)
      assert.equal("grpc-service", log_message.service.name)

      -- Since it's over HTTP, let's make sure there are no TLS information
      assert.is_nil(log_message.request.tls)
    end)

    it("logs proper latencies", function()
      local tcp_thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local r = assert(proxy_client:send {
        method  = "GET",
        path    = "/delay/1",
        headers = {
          host  = "tcp_logging.test",
        },
      })

      assert.response(r).has.status(200)
      -- Getting back the TCP server input
      local ok, res = tcp_thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)

      assert.True(log_message.latencies.proxy < 3000)

      -- Sometimes there's a split milisecond that makes numbers not
      -- add up by 1. Adding an artificial 1 to make the test
      -- resilient to those.
      local is_latencies_sum_adding_up =
        1+log_message.latencies.request >= log_message.latencies.kong +
        log_message.latencies.proxy

      assert.True(is_latencies_sum_adding_up)
    end)

    it("logs proper latencies (#grpc)", function()
      local tcp_thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local ok, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "tcp_logging_grpc.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      -- Getting back the TCP server input
      local ok, res = tcp_thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)

      assert.equal("grpc", log_message.service.protocol)
      assert.True(log_message.latencies.proxy < 3000)

      -- Sometimes there's a split milisecond that makes numbers not
      -- add up by 1. Adding an artificial 1 to make the test
      -- resilient to those.
      local is_latencies_sum_adding_up =
        1 + log_message.latencies.request >= log_message.latencies.kong +
        log_message.latencies.proxy

      assert.True(is_latencies_sum_adding_up)
    end)

    it("logs proper latencies (#grpcs)", function()
      local tcp_thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local ok, resp = proxy_client_grpcs({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "tcp_logging_grpcs.test",
          ["-H"] = "'Content-Type: text/plain'",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      -- Getting back the TCP server input
      local ok, res = tcp_thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)

      assert.equal("grpcs", log_message.service.protocol)
      assert.True(log_message.latencies.proxy < 3000)

      -- Sometimes there's a split milisecond that makes numbers not
      -- add up by 1. Adding an artificial 1 to make the test
      -- resilient to those.
      local is_latencies_sum_adding_up =
        1 + log_message.latencies.request >= log_message.latencies.kong +
        log_message.latencies.proxy

      assert.True(is_latencies_sum_adding_up)
    end)

    it("performs a TLS handshake on the remote TCP server", function()
      local thread = helpers.tcp_server(TCP_PORT, { tls = true })

      -- Making the request
      local r = assert(proxy_client:send {
        method  = "GET",
        path    = "/request",
        headers = {
          host = "tcp_logging_tls.test",
        },
      })
      assert.response(r).has.status(200)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)
      assert.equal("127.0.0.1", log_message.client_ip)
    end)

    it("logs TLS info", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local r = assert(proxy_ssl_client:send {
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "tcp_logging.test",
        },
      })

      assert.response(r).has.status(200)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)
      assert.equal("TLSv1.3", log_message.request.tls.version)
      assert.is_string(log_message.request.tls.cipher)
      assert.equal("NONE", log_message.request.tls.client_verify)
    end)

    it("TLS client_verify can be overwritten", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local r = assert(proxy_ssl_client:send {
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "tcp_logging.test",
          ["x-ssl-client-verify"] = "SUCCESS",
        },
      })

      assert.response(r).has.status(200)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)
      assert.equal("TLSv1.3", log_message.request.tls.version)
      assert.is_string(log_message.request.tls.cipher)
      assert.equal("SUCCESS", log_message.request.tls.client_verify)
    end)

    it("logs TLS info (#grpcs)", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local ok, resp = proxy_client_grpcs({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "tcp_logging_grpcs.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)

      assert.equal("grpcs", log_message.service.protocol)
      assert.match("TLSv1.[23]", log_message.request.tls.version)
      assert.is_string(log_message.request.tls.cipher)
      assert.equal("NONE", log_message.request.tls.client_verify)
    end)

    it("tries field encoded as JSON array instead of object #6390", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      -- Making the request
      local r = assert(proxy_client:send {
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "early_termination.example.test",
        },
      })
      assert.response(r).has.status(200)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      assert.matches('"tries":[]', res, nil, true)
    end)

    it("#stream reports tcp streams", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      local tcp = ngx.socket.tcp()
      assert(tcp:connect(helpers.get_proxy_ip(false), 19000))

      assert(tcp:send(MESSAGE))

      local body = assert(tcp:receive("*a"))
      assert.equal(MESSAGE, body)

      tcp:close()

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)

      assert.equal("127.0.0.1", log_message.client_ip)
      assert.is_table(log_message.latencies)

      assert.equal(200, log_message.session.status)
      assert.equal(#MESSAGE, log_message.session.sent)
      assert.equal(#MESSAGE, log_message.session.received)

      assert.is_number(log_message.started_at)

      assert.is_table(log_message.route)
      assert.is_table(log_message.service)
      assert.is_table(log_message.tries)
      assert.is_table(log_message.upstream)
    end)

    it("#stream reports tls streams", function()
      local thread = helpers.tcp_server(TCP_PORT) -- Starting the mock TCP server

      local tcp = ngx.socket.tcp()

      assert(tcp:connect(helpers.get_proxy_ip(true), 19443))

      assert(tcp:sslhandshake(nil, "this-is-needed.test", false))

      assert(tcp:send(MESSAGE))

      local body = assert(tcp:receive("*a"))
      assert.equal(MESSAGE, body)

      tcp:close()

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local log_message = cjson.decode(res)

      assert.is_string(log_message.session.tls.cipher)
      assert.equal("NONE", log_message.session.tls.client_verify)
      assert.is_string(log_message.session.tls.version)
    end)
  end)

end
