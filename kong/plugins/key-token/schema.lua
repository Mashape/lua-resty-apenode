local typedefs = require "kong.db.schema.typedefs"


local PLUGIN_NAME = "key-token"


local schema = {
  name = PLUGIN_NAME,
  fields = {
    -- the 'fields' array is the top-level entry with fields defined by Kong
    { consumer = typedefs.no_consumer },  -- this plugin cannot be configured on a consumer (typical for auth plugins)
    { protocols = typedefs.protocols_http },
    { config = {
        -- The 'config' record is the custom part of the plugin schema
        type = "record",
        fields = {
          -- a standard defined field (typedef), with some customizations
          { request_key_name = typedefs.header_name {
              description = "The header name that is used to send to backend authentication service.",
              type = "string",
              required = true,
              default = "auth_key" }, },
          { auth_server = typedefs.url {
              description = "The authenticaiton/authorization service URL. please note that 'localhost' is reserved for integration test.",
              required = true,
              default = "http://auth_server.com" }, },
          { ttl = {
              description = "TTL for cached token from auth server.",
              type = "integer",
              default = 600,
              required = true,
              gt = 0, }, },
        },
        entity_checks = { },
      },
    },
  },
}

return schema
