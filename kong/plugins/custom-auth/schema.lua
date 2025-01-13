local typedefs = require "kong.db.schema.typedefs"
local PLUGIN_NAME = "custom-auth"

local schema = {
    name = PLUGIN_NAME,
    fields = {
        {
            config = {
                type = "record",
                fields = {
                    { request_header_name = typedefs.header_name { required = true }, },
                    { auth_server_url = typedefs.url { required = true }, },
                    { forward_key = { description = "The key to fetch from auth server and forward to backend", type = "string"} },
                    { ttl = typedefs.ttl {required = false, default = 60}, },
                },
            },
        },
    },
}

return schema

