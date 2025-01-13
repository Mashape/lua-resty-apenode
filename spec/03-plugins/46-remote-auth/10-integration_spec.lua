local cjson      = require "cjson"
local jwt_parser = require "kong.plugins.jwt.jwt_parser"
local helpers    = require "spec.helpers"
local http_mock  = require "spec.helpers.http_mock"
local fixtures   = require "spec.remote-auth.fixtures"


local PLUGIN_NAME = "remote-auth"


local mock_http_server_port    = helpers.get_available_port()
local port_missing_auth_server = helpers.get_available_port()

local mock                     = http_mock.new("127.0.0.1:" .. mock_http_server_port, {
    ["/auth"] = {
      access = [[
      local jwt_parser = require "kong.plugins.jwt.jwt_parser"
      local fixtures = require "spec.remote-auth.fixtures"
      local json = require "cjson"
      local method = ngx.req.get_method()
      local uri = ngx.var.request_uri
      local headers = ngx.req.get_headers(nil, true)
      local token_header = headers["Authorization"]
      ngx.header["X-Token"] = jwt_parser.encode({
        name = "foobar",
        exp = os.time() + 1000,
      }, fixtures.es512_private_key, 'ES512')
      ngx.say(json.encode({
        uri = uri,
        method = method,
        headers = headers,
        body = body,
        status = 200,
      }))
    ]]
    },
    ["/auth-reject"] = {
      access = [[
      ngx.status = 401
      ngx.say("unauthorized")
    ]]
    },
    ["/auth-missing"] = {
      access = [[
      ngx.status = 200
      ngx.say("Ok")
    ]]
    },
    ["/auth-expired"] = {
      access = [[
      local jwt_parser  = require "kong.plugins.jwt.jwt_parser"
      local fixtures    = require "spec.remote-auth.fixtures"

      ngx.status = 200
      ngx.header["X-Token"] = jwt_parser.encode({
        name = "foobar",
        exp = os.time() - 100,
      }, fixtures.es512_private_key, 'ES512')
      ngx.say("Success")
    ]]
    },
  },
  nil,
  {
    log_opts = {
      req = true,
      req_body = true,
      req_body_large = true,
    }
  }
)


for _, strategy in helpers.all_strategies() do
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })
      -- Inject a test route. No need to create a service, there is a default
      -- service which will echo the request.
      local route1 = bp.routes:insert({
        hosts = { "test1.com" },
      })
      local route2 = bp.routes:insert({
        hosts = { "test2.com" },
      })
      local route3 = bp.routes:insert({
        hosts = { "test3.com" },
      })
      local route4 = bp.routes:insert({
        hosts = { "test4.com" },
      })
      local route5 = bp.routes:insert({
        hosts = { "test5.com" },
      })
      local route6 = bp.routes:insert({
        hosts = { "test6.com" },
      })

      -- add the plugin to test to the route we created
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route1.id },
        config = {
          auth_request_url = "http://127.0.0.1:" .. mock_http_server_port .. "/auth",
          jwt_public_key = fixtures.es512_public_key,
        },
      }
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route2.id },
        config = {
          auth_request_url = "http://127.0.0.1:" .. mock_http_server_port .. "/auth-reject",
          jwt_public_key = fixtures.es512_public_key,
        },
      }
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route3.id },
        config = {
          auth_request_url = "http://127.0.0.1:" .. port_missing_auth_server .. "/auth-reject",
          jwt_public_key = fixtures.es512_public_key,
        },
      }
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route4.id },
        config = {
          auth_request_url = "http://127.0.0.1:" .. mock_http_server_port .. "/auth-missing",
          jwt_public_key = fixtures.es512_public_key,
        },
      }
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route5.id },
        config = {
          auth_request_url = "http://127.0.0.1:" .. mock_http_server_port .. "/auth",
          jwt_public_key = fixtures.rs256_public_key,
        }
      }
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route6.id },
        config = {
          auth_request_url = "http://127.0.0.1:" .. mock_http_server_port .. "/auth-expired",
          jwt_public_key = fixtures.es512_public_key,
          jwt_max_expiration = 100,
        }
      }
      assert(helpers.start_kong({
        database           = strategy,
        nginx_conf         = "spec/fixtures/custom_nginx.template",
        declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
        plugins            = PLUGIN_NAME,
      }))
      assert(mock:start())
    end)

    lazy_teardown(function()
      helpers.stop_kong(nil, true)
      assert(mock:stop())
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      mock:clean()
      if client then client:close() end
      mock.client = nil
    end)


    describe("Authorized: ", function()
      it("Can get token and validate it", function()
        local res = client:get("/", {
          headers = {
            Host = "test1.com",
            Authorization = "test",
          }
        })

        assert.response(res).has.status(200)

        -- assert that the mock got the right header
        local logs = mock:retrieve_mocking_logs()
        local req = assert(logs[#logs].req)
        assert.same(req.headers["Authorization"], "test")

        -- assert that the response contains the jwt token
        local header_value = assert.response(res).has.header("X-Token")
        local jwt = assert(jwt_parser:new(header_value))
        assert.True(jwt:verify_signature(fixtures.es512_public_key))
      end)
    end)



    describe("Unauthorized:", function()
      it("Rejects a missing token", function()
        local r = client:get("/", {
          headers = {
            host = "test1.com",
          }
        })
        -- validate that the request succeeded, response status 200
        local body = assert.response(r).has.status(401)
        local json = cjson.decode(body)

        assert.same("Missing Token, Unauthorized", json.message)
      end)

      it("Rejects an invalid token", function()
        local r = client:get("/", {
          headers = {
            host = "test2.com",
            Authorization = "test",
          }
        })
        -- validate that the request succeeded, response status 200
        local body = assert.response(r).has.status(401)
        local json = cjson.decode(body)

        assert.same("Unauthorized: authentication failed with status: 401", json.message)
      end)

      it("Rejects when authentication server is unavailable", function()
        local r = client:get("/", {
          headers = {
            host = "test3.com",
            Authorization = "test",
          }
        })
        -- validate that the request succeeded, response status 200
        local body = assert.response(r).has.status(401)
        local json = cjson.decode(body)

        assert.same(
          "Unauthorized: failed request to 127.0.0.1:" .. port_missing_auth_server .. ": connection refused",
          json.message
        )
      end)

      it("Rejects when authentication server provides empty token", function()
        local r = client:get("/", {
          headers = {
            host = "test4.com",
            Authorization = "test",
          }
        })
        -- validate that the request succeeded, response status 200
        local body = assert.response(r).has.status(502)
        local json = cjson.decode(body)

        assert.same(
          "Upsteam Authentication server returned an empty response",
          json.message
        )
      end)

      it("Rejects with invalid public_key", function()
        local r = client:get("/", {
          headers = {
            host = "test5.com",
            Authorization = "test",
          }
        })
        -- validate that the request succeeded, response status 200
        local body = assert.response(r).has.status(502)
        local json = cjson.decode(body)
        assert.same("JWT - Invalid signature", json.message)
      end)

      it("Rejects with invalid expireation time", function()
        local r = client:get("/", {
          headers = {
            host = "test6.com",
            Authorization = "test",
          }
        })
        -- validate that the request succeeded, response status 200
        local body = assert.response(r).has.status(502)
        local json = cjson.decode(body)
        assert.same("JWT - Token Expired", json.message)
      end)
    end)
  end)
end
