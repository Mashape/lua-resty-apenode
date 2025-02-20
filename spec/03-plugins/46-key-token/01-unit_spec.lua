local PLUGIN_NAME = "key-token"


-- helper function to validate data against a schema
local validate do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins."..PLUGIN_NAME..".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()


  it("accepts request key, auth server and ttl", function()
    local ok, err = validate({
        request_key_name = "My-Request-Header",
        auth_server = "http://my-auth-service/",
        ttl = 300
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)


  it("accepts default configs", function()
    local ok, err = validate({ })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)


end)
