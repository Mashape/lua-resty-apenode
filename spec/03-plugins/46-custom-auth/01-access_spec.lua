local helpers = require "spec.helpers"
local cjson = require "cjson"

local PLUGIN_NAME = "custom-auth"

for _, strategy in helpers.each_strategy() do

  describe(PLUGIN_NAME .. ": [#" .. strategy .. "]", function()

    local auth_header_name = "Authorization"
    local client
    local admin_client
    local bp
    local db
    local route1
    local route2
    local mock_auth_consumer

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "basicauth_credentials",
        "custom_auth_table",
      }, { PLUGIN_NAME })

      route1 = bp.routes:insert {
        paths = { "/route1" },
      }

      route2 = bp.routes:insert {
        paths = { "/route2" },
      }

      mock_auth_consumer = bp.consumers:insert {
        username = "mock_auth_consumer",
      }

      local mock_auth_route = bp.routes:insert({
        paths = { "/mock_auth_server" },
      })

      bp.plugins:insert {
        name = "basic-auth",
        route = { id = mock_auth_route.id },
        config = {
          hide_credentials = true
        }
      }

      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          request_header_name = auth_header_name,
          auth_server_url = "http://" .. helpers.get_proxy_ip() .. ":" .. helpers.get_proxy_port() .. "/mock_auth_server",
          ttl = 3,
        },
      }

      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route2.id },
        config = {
          request_header_name = auth_header_name,
          auth_server_url = "http://" .. helpers.get_proxy_ip() .. ":" .. helpers.get_proxy_port() .. "/mock_auth_server",
          ttl = 3,
        },
      }

      assert(helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled," .. PLUGIN_NAME,
      }))

      client = helpers.proxy_client()
      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
    end)

    after_each(function()
    end)

    describe("access test", function()

      before_each(function()
        db:truncate("basicauth_credentials")
      end)

      local cred

      it("200 OK", function()
        cred = bp.basicauth_credentials:insert {
          username = "Aladdin",
          password = "OpenSesame",
          consumer = { id = mock_auth_consumer.id },
        }

        local r = client:get("/route1/anything", {
          headers = {
            [auth_header_name] = "Basic QWxhZGRpbjpPcGVuU2VzYW1l",
          },
        })

        assert.response(r).has.status(200)
      end)

      it("401 Unauthorized", function()
        local r = client:get("/route1/anything", {
          headers = {
            [auth_header_name] = "nothing",
          },
        })

        assert.response(r).has.status(401)
      end)

      it("400 Bad Request", function()
        local r = client:get("/route1/anything", {})
        assert.response(r).has.status(400)
      end)

      it("200 OK from cache", function()
        cred = bp.basicauth_credentials:insert {
          username = "Aladdin",
          password = "OpenSesame",
          consumer = { id = mock_auth_consumer.id },
        }

        local r = client:get("/route2/anything", {
          headers = {
            [auth_header_name] = "Basic QWxhZGRpbjpPcGVuU2VzYW1l",
          },
        })
        assert.response(r).has.status(200)

        local res = assert(admin_client:send {
          method  = "DELETE",
          path    = "/consumers/mock_auth_consumer/basic-auth/" .. cred.id,
        })
        assert.res_status(204, res)

        r = client:get("/route2/anything", {
          headers = {
            [auth_header_name] = "Basic QWxhZGRpbjpPcGVuU2VzYW1l",
          },
        })
        assert.response(r).has.status(200)

        -- wait for cache expire
        ngx.sleep(4)

        r = client:get("/route2/anything", {
          headers = {
            [auth_header_name] = "Basic QWxhZGRpbjpPcGVuU2VzYW1l",
          },
        })
        assert.response(r).has.status(401)

      end)

    end)

  end)

end

