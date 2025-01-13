local PLUGIN_NAME = "remote-auth"


-- helper function to validate data against a schema
local validate
do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins." .. PLUGIN_NAME .. ".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()
  it("accepts minimal required configuration", function()
    local ok, err = validate({
      auth_request_url = "http://example.com/auth",
      jwt_public_key = "sample-public-key",
    })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

  it("accepts all configuration values", function()
    local ok, err = validate({
      auth_request_url = "http://example.com/auth",
      consumer_auth_header = "X-Test-Header",
      auth_request_method = "FOO",
      auth_request_timeout = 100,
      auth_request_keepalive = 20000,
      auth_request_token_header = "Authorization",
      auth_response_token_header = "X-Auth",
      auth_request_headers = {
        ["X-Who-Am-I"] = "remote-auth",
      },
      service_auth_header = "Example-Header",
      service_auth_header_value_prefix = "token ",
      jwt_public_key = "foobarbaz",
      jwt_max_expiration = 100000,
      request_authentication_header = "X-Testing",
    })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

  it("rejects empty header values", function()
    local ok, err = validate({
      auth_request_url = "http://example.com/auth",
      auth_request_headers = {
        ["X-Who-Am-I"] = "",
      },
      jwt_public_key = "testing",
    })
    assert.same({
      config = {
        auth_request_headers = "length must be at least 1",
      }
    }, err)
    assert.is_falsy(ok)
  end)

  local blacklisted_headers = { "Host", "Content-Type", "Content-Length" }
  for _, header in pairs(blacklisted_headers) do
    it("rejects blacklisted Header (" .. header .. ")", function()
      local ok, err = validate({
        auth_request_url = "http://example.com/auth",
        auth_request_headers = {
          ["X-Who-Am-I"] = "123",
          [header] = "FooBar",
        },
        jwt_public_key = "testing",
      })
      assert.same({
        config = {
          auth_request_headers = "cannot contain '" .. header .. "' header"
        }
      }, err)
      assert.is_falsy(ok)
    end)
  end
end)
