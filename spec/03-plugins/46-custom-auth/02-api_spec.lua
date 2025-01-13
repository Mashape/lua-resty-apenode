local helpers = require "spec.helpers"
local cjson = require "cjson"

local PLUGIN_NAME = "custom-auth"

for _, strategy in helpers.each_strategy() do

  describe(PLUGIN_NAME .. ": [#" .. strategy .. "]", function()

    local consumer
    local auth_header_name = "Authorization"
    local admin_client
    local bp
    local db
    local route1

    lazy_setup(function()
      bp = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

      route1 = bp.routes:insert {
        paths = { "/route1" },
      }

      assert(helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled," .. PLUGIN_NAME,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      admin_client = helpers.admin_client()
    end)

    after_each(function()
      if admin_client then admin_client:close() end
    end)

    describe("plugins api", function()

      it("missing mandatary fields", function()
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name  = "custom-auth",
            route = { id = route1.id },
            config     = {
              auth_server_url = "http://127.0.0.1",
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        assert.response(res).has.status(400)

        res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name  = "custom-auth",
            route = { id = route1.id },
            config     = {
              request_header_name = auth_header_name,
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        assert.response(res).has.status(400)

      end)

      it("create and update success", function()
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name  = "custom-auth",
            route = { id = route1.id },
            config     = {
              request_header_name = auth_header_name,
              auth_server_url = "http://127.0.0.1",
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        local body = assert.res_status(201, res)
        local json = cjson.decode(body)

        res = assert(admin_client:send {
          method  = "PATCH",
          path    = "/plugins/" .. json.id,
          body    = {
            name  = "custom-auth",
            route = { id = route1.id },
            config     = {
              request_header_name = auth_header_name,
              auth_server_url = "http://127.0.0.1",
              forward_key = "X-My-Header",
              ttl = 10,
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        assert.response(res).has.status(200)
      end)

    end)

  end)

end
