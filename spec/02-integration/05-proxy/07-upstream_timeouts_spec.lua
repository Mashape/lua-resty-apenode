local helpers = require "spec.helpers"

for _, strategy in helpers.each_strategy() do
  describe("upstream timeouts with DB: #" .. strategy, function()
    local proxy_client
    local bp

    local function insert_routes(routes)
      if type(routes) ~= "table" then
        return error("expected arg #1 to be a table", 2)
      end

      for i = 1, #routes do
        local route = routes[i]
        local service = route.service or {}

        if not service.name then
          service.name = "service-" .. i
        end

        if not service.host then
          service.host = helpers.mock_upstream_host
        end

        if not service.port then
          service.port = helpers.mock_upstream_port
        end

        if not service.protocol then
          service.protocol = helpers.mock_upstream_protocol
        end

        route.service = bp.services:insert(service)

        if route.enable_buffering then
          route.enable_buffering = nil
          bp.plugins:insert({
            name = "pre-function",
            service = { id = route.service.id },
            config = {
              access = {
                [[
                  kong.service.request.enable_buffering()
                ]],
              },
            }
          })
        end

        if not route.protocols then
          route.protocols = { "http" }
        end
        bp.routes:insert(route)
      end

      return true
    end

    lazy_setup(function()
      bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      }, { "ctx-checker-last" })

      insert_routes {
        {
          methods = { "HEAD" },
          service = {
            name            = "api-1",
            protocol        = "http",
            host            = "konghq.com",
            port            = 81,
            connect_timeout = 1, -- ms
          },
        },
        {
          methods = { "POST" },
          service = {
            name            = "api-2",
            write_timeout   = 1, -- ms
          },
        },
        {
          methods = { "GET" },
          service = {
            name           = "api-3",
            read_timeout   = 1, -- ms
          },
        },
        {
          methods = { "PUT" },
          service = {
            name            = "api-4",
            protocol        = "http",
            host            = "konghq.com",
            port            = 81,
            connect_timeout = 1, -- ms
          },
          enable_buffering = true,
        },
      }

      bp.plugins:insert {
        name = "ctx-checker-last",
        config = {
          ctx_check_field = "balancer_data",
        }
      }

      assert(helpers.start_kong({
        plugins    = "bundled, ctx-checker-last",
        database   = strategy,
        nginx_http_client_max_body_size = 0,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
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

    describe("upstream_connect_timeout", function()
      it("sets upstream connect timeout value", function()
        local res = assert(proxy_client:send {
          method  = "HEAD",
          path    = "/",
        })

        assert.res_status(504, res)
      end)
    end)

    describe("upstream_read_timeout", function()
      it("sets upstream read timeout value", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/delay/2",
        })

        assert.res_status(504, res)
      end)
      it("sets status for last try", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/delay/2",
        })

        assert.res_status(504, res)

        local balancer_data = res.headers["ctx-checker-last-balancer-data"]
        -- extract the "tries" field
        local tries = ngx.re.match(balancer_data, [[^.+tries \= \{ (\{.+\})\, .+\}\,.+\}$]], "o")
        -- split tries
        local individual_tries = ngx.re.match(tries[1], [[(\{.+\})\, (\{.+\}\,) (\{.+\})\, (\{.+\}\,)( \{.+\})]], "o")
        -- check for state and code fields
        for i = 1, #individual_tries do
          assert(string.match(individual_tries[i], [[state = "failed"]]))
          assert(string.match(individual_tries[i], [[code = 504]]))
        end

      end)
    end)

    describe("upstream_send_timeout", function()
      it("sets upstream send timeout value", function()
        local res = assert(proxy_client:send {
          method  = "POST",
          path    = "/post",
          body    = {
            huge  = string.rep("a", 2^25)
          },
          headers = { ["Content-Type"] = "application/json" },
        })

        -- do *not* use assert.res_status() here in case of
        -- failure to avoid a very large error log
        assert.equal(504, res.status)
      end)
    end)

    describe("upstream_connect_timeout with enable_buffering", function()
      it("sets upstream send timeout value", function()
        local res = assert(proxy_client:send {
          method  = "PUT",
          path    = "/put",
          body    = {
            huge  = string.rep("a", 2^25)
          },
          headers = { ["Content-Type"] = "application/json" },
        })

        assert.equal(504, res.status)
      end)
    end)


  end)
end
