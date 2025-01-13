local jwt_parser = require "kong.plugins.jwt.jwt_parser"
local fixtures   = require "spec.remote-auth.fixtures"


local PLUGIN_NAME = "remote-auth"

describe(PLUGIN_NAME .. ": (unit) ", function()
  local plugin, config
  local actual_require
  local mock_auth_response_status
  local mock_calls
  local mock_request_header_value
  local mock_auth_response_headers
  local request_header_name

  local function append_call(key, item)
    mock_calls[key][#mock_calls[key] + 1] = item
  end

  setup(function()
    mock_calls = {
      response_error = {},
      response_set_headers = {},
      service_request_set_headers = {},
      auth_request = {},
      auth_set_timeout = {},
    }
    mock_auth_response_headers = {}
    actual_require = _G.require
    _G.kong = { -- mock the basic Kong function we use in our plugin
      request = {
        get_header = function(name)
          if name == request_header_name then
            return mock_request_header_value
          end
          return nil
        end,
      },
      response = {
        error = function(status, message, headers)
          append_call(
            "response_error",
            { status = status, message = message, headers = headers }
          )
        end,
        set_header = function(name, value)
          append_call(
            "response_set_headers",
            { name = name, value = value }
          )
        end,
      },
      service = {
        request = {
          set_header = function(name, value)
            append_call("service_request_set_headers", { name = name, value = value })
          end,
        }
      }
    }
    _G.require = function(modname)
      if modname == "resty.http" then
        return {
          new = function()
            local http = {}
            http.set_timeout = function(_, timeout)
              append_call("auth_set_timeout", { timeout = timeout })
            end
            http.request_uri = function(_, url, opts)
              append_call("auth_request", { url = url, opts = opts })

              if mock_auth_response_status then
                return {
                  status = mock_auth_response_status,
                  headers = mock_auth_response_headers
                }
              else
                return nil
              end
            end
            return http
          end
        }
      else
        -- For anything else, return actual.
        return actual_require(modname)
      end
    end

    -- load the plugin code
    plugin = require("kong.plugins." .. PLUGIN_NAME .. ".handler")
  end)

  teardown(function()
    _G.require = actual_require
  end)


  before_each(function()
    request_header_name = "X-Auth"
    -- clear the upvalues to prevent test results mixing between tests
    config = {
      auth_request_url = "http://127.0.0.1:2101/auth",
      consumer_auth_header = "X-Auth",
      auth_response_token_header = "X-Token",
      auth_request_token_header = "Authorization",
      auth_request_method = "POST",
      auth_request_keepalive = 10000,
      auth_request_timeout = 2000,
      service_auth_header = "X-Auth",
      jwt_public_key = fixtures.es512_public_key,
      request_authentication_header = "X-Token",
    }
  end)

  after_each(function()
    mock_calls = {
      response_error = {},
      response_set_headers = {},
      service_request_set_headers = {},
      auth_request = {},
      auth_set_timeout = {},
    }
    mock_auth_response_status = nil
    mock_request_header_value = nil
    mock_auth_response_headers = {}
  end)

  describe("Success -", function()
    local token = jwt_parser.encode({
      name = "foobar",
    }, fixtures.es512_private_key, 'ES512')

    before_each(function()
      mock_auth_response_status = 200
      mock_request_header_value = "asdf1234"
      mock_auth_response_headers = {
        ["X-Token"] = token
      }
    end)
    it("calls authentication api when token exists", function()
      plugin:access(config)
      assert.same(
        { {
          url = "http://127.0.0.1:2101/auth",
          opts = {
            method = "POST",
            headers = { Authorization = "asdf1234" },
            keepalive_timeout = 10000,
          }
        } },
        mock_calls["auth_request"]
      )
      assert.same(mock_calls["response_error"], {})
    end)

    it("sets headers on successful auth call", function()
      plugin:access(config)
      assert.same(mock_calls["service_request_set_headers"], { { name = "X-Auth", value = token } })
      assert.same({}, mock_calls["response_error"])
      assert.same(mock_calls["response_set_headers"], { { name = "X-Token", value = token } })
    end)

    it("sets timeout on auth call", function()
      plugin:access(config)
      assert.same({ { timeout = 2000 } }, mock_calls["auth_set_timeout"])
      assert.same({}, mock_calls["response_error"])
    end)
  end)
  describe("Failure:", function()
    it("rejects missing token header", function()
      plugin:access(config)
      assert.same(
        { { status = 401, message = "Missing Token, Unauthorized" } },
        mock_calls["response_error"]
      )
      assert.same({}, mock_calls["response_set_headers"])
    end)
  end)
end)
