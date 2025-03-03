local helpers  = require "spec.helpers"
local cjson    = require "cjson"


local UDP_PORT = 20000


for _, strategy in helpers.each_strategy() do
  describe("Plugin: loggly (log) [#" .. strategy .. "]", function()
    local proxy_client
    local proxy_client_grpc

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      })

      local route1 = bp.routes:insert {
        hosts = { "logging.test" },
      }

      local route2 = bp.routes:insert {
        hosts = { "logging1.test" },
      }

      local route3 = bp.routes:insert {
        hosts = { "logging2.test" },
      }

      local route4 = bp.routes:insert {
        hosts = { "logging3.test" },
      }

      local route5 = bp.routes:insert {
        hosts = { "logging4.test" },
      }

      bp.plugins:insert {
        route = { id = route1.id },
        name     = "loggly",
        config   = {
          host                = "127.0.0.1",
          port                = UDP_PORT,
          key                 = "123456789",
          log_level           = "info",
          successful_severity = "warning"
        }
      }

      bp.plugins:insert {
        route = { id = route2.id },
        name     = "loggly",
        config   = {
          host                = "127.0.0.1",
          port                = UDP_PORT,
          key                 = "123456789",
          log_level           = "debug",
          timeout             = 2000,
          successful_severity = "info",
        }
      }

      bp.plugins:insert {
        route = { id = route3.id },
        name     = "loggly",
        config   = {
          host                   = "127.0.0.1",
          port                   = UDP_PORT,
          key                    = "123456789",
          log_level              = "crit",
          successful_severity    = "crit",
          client_errors_severity = "warning",
        }
      }

      bp.plugins:insert {
        route = { id = route4.id },
        name     = "loggly",
        config   = {
          host = "127.0.0.1",
          port = UDP_PORT,
          key  = "123456789"
        }
      }

      bp.plugins:insert {
        route = { id = route5.id },
        name     = "loggly",
        config   = {
          host = "127.0.0.1",
          port = UDP_PORT,
          key  = "123456789",
          custom_fields_by_lua = {
            new_field = "return 123",
            ["nested.keys"] = "return 456",
            ["escape\\.dots"] = "return 789",
            ["nested.escape\\.dots"] = "return 135",
            route = "return nil", -- unset route field
          }
        }
      }

      -- grpc [[
      local grpc_service = bp.services:insert {
        name = "grpc-service",
        url = helpers.grpcbin_url,
      }

      local grpc_route1 = bp.routes:insert {
        service = grpc_service,
        hosts = { "grpc_logging.test" },
      }

      local grpc_route2 = bp.routes:insert {
        service = grpc_service,
        hosts = { "grpc_logging1.test" },
      }

      local grpc_route3 = bp.routes:insert {
        service = grpc_service,
        hosts = { "grpc_logging2.test" },
      }

      bp.plugins:insert {
        route = { id = grpc_route1.id },
        name     = "loggly",
        config   = {
          host                = "127.0.0.1",
          port                = UDP_PORT,
          key                 = "123456789",
          log_level           = "info",
          successful_severity = "warning"
        }
      }

      bp.plugins:insert {
        route = { id = grpc_route2.id },
        name     = "loggly",
        config   = {
          host                = "127.0.0.1",
          port                = UDP_PORT,
          key                 = "123456789",
          log_level           = "debug",
          timeout             = 2000,
          successful_severity = "info",
        }
      }

      bp.plugins:insert {
        route = { id = grpc_route3.id },
        name     = "loggly",
        config   = {
          host                   = "127.0.0.1",
          port                   = UDP_PORT,
          key                    = "123456789",
          log_level              = "crit",
          successful_severity    = "crit",
          client_errors_severity = "warning",
        }
      }

      -- grpc ]]

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))

      proxy_client_grpc = helpers.proxy_client_grpc()
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

    -- Helper; performs a single http request and catches the udp log output.
    -- @param message the message table for the http client
    -- @param status expected status code from the request, defaults to 200 if omitted
    -- @return 2 values; 'pri' field (string) and the decoded json content (table)
    local function run(message, status)
      local thread   = assert(helpers.udp_server(UDP_PORT))
      local response = assert(proxy_client:send(message))
      assert.res_status(status or 200, response)

      local ok, res = thread:join()
      assert.truthy(ok)
      assert.truthy(res)

      local pri  = assert(res:match("^<(%d-)>"))
      local json = assert(res:match("{.*}"))

      return pri, cjson.decode(json)
    end

    local function run_grpc(host)
      local thread   = assert(helpers.udp_server(UDP_PORT))

      local ok, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = host,
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      local ok, res = thread:join()
      assert.truthy(ok)
      assert.truthy(res)

      local pri  = assert(res:match("^<(%d-)>"))
      local json = assert(res:match("{.*}"))

      return pri, cjson.decode(json)
    end

    it("logs to UDP when severity is warning and log level info", function()
      local pri, message = run({
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "logging.test"
        }
      })
      assert.equal("12", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity is warning and log level info #grpc", function()
      local pri, message = run_grpc("grpc_logging.test")
      assert.equal("12", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity is info and log level debug", function()
      local pri, message = run({
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "logging1.test"
        }
      })
      assert.equal("14", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity is info and log level debug #grpc", function()
      local pri, message = run_grpc("grpc_logging1.test")
      assert.equal("14", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity is critical and log level critical", function()
      local pri, message = run({
        method  = "GET",
        path    = "/request",
        headers = {
          host  = "logging2.test"
        }
      })
      assert.equal("10", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity is critical and log level critical #grpc", function()
      local pri, message = run_grpc("grpc_logging2.test")
      assert.equal("10", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity and log level are default values", function()
      local pri, message = run({
        method  = "GET",
        path    = "/",
        headers = {
          host  = "logging3.test"
        }
      })
      assert.equal("14", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity and log level are default values and response status is 200", function()
      local pri, message = run({
        method  = "GET",
        path    = "/",
        headers = {
          host  = "logging3.test"
        }
      })
      assert.equal("14", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity and log level are default values and response status is 401", function()
      local pri, message = run({
        method  = "GET",
        path    = "/status/401",
        headers = {
          host  = "logging3.test"
        }
      }, 401)
      assert.equal("14", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    it("logs to UDP when severity and log level are default values and response status is 500", function()
      local pri, message = run({
        method  = "GET",
        path    = "/status/500",
        headers = {
          host  = "logging3.test"
        }
      }, 500)
      assert.equal("14", pri)
      assert.equal("127.0.0.1", message.client_ip)
    end)

    describe("custom log values by lua", function()
      it("logs custom values", function()
        local pri, message = run({
          method  = "GET",
          path    = "/status/500",
          headers = {
            host  = "logging4.test"
          }
        }, 500)
        assert.equal("14", pri)
        assert.equal(123, message.new_field)
        assert.same(456, message.nested.keys)
        assert.same(789, message["escape.dots"])
        assert.same(135, message.nested["escape.dots"])
      end)
      it("unsets existing log values", function()
        local pri, message = run({
          method  = "GET",
          path    = "/status/500",
          headers = {
            host  = "logging4.test"
          }
        }, 500)
        assert.equal("14", pri)
        assert.equal(nil, message.route)
      end)
    end)
  end)
end
