local helpers = require "spec.helpers"


local PLUGIN_NAME = "key-token"


for _, strategy in helpers.all_strategies() do if strategy ~= "cassandra" then
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()

      local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

      -- Inject a test route. No need to create a service, there is a default
      -- service which will echo the request.
      local route_auth_server = bp.routes:insert({
        hosts = { "auth_server.com" },
      })

      local route_upstream = bp.routes:insert({
        hosts = { "resource1.com" },
      })
      -- add the plugin to test to the route we created
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_auth_server.id },
        config = {},
      }

      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_upstream.id },
        config = {auth_server = "http://localhost:9001"},
      }
      -- start kong
      assert(helpers.start_kong({
        -- set the strategy
        database   = strategy,
        -- use the custom test template to create a local mock server
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- make sure our plugin gets loaded
        plugins = "bundled," .. PLUGIN_NAME,
        -- write & load declarative config, only if 'strategy=off'
        declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong(nil, true)
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then client:close() end
    end)



    describe("request", function()
      it("gets a auth key header", function()
        local r = client:get("/request", {
          headers = {
            host = "resource1.com",
            auth_key = "123456"
          }
        })
        -- validate that the request succeeded, response status 200
        assert.response(r).has.status(200)
        -- now check the request (as echoed by the mock backend) to have the header
        local header_value = assert.request(r).has.header("auth_key")
        -- validate the value of that header
        assert.equal("123456", header_value)
        -- The mock server returns 123456. The ideal auth server would issue JWT token
        local auth_token = assert.request(r).has.header("Authorizaion")
        assert.equal("Bearer 123456", auth_token)
      end)
    end)


  end)

end end
