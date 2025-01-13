local typedefs = require "kong.db.schema.typedefs"

return {
  {
    ttl = true,
    primary_key = { "id" },
    name = "custom_auth_table",
    endpoint_key = "key",
    cache_key = { "key" },
    workspaceable = false,
    admin_api_name = "custom-auths",
    admin_api_nested_name = "custom-auth",
    fields = {
      { id = typedefs.uuid },
      { created_at = typedefs.auto_timestamp_s },
      { expire_at = typedefs.auto_timestamp_s },
      { key = { type = "string", required = false, unique = true, auto = true }, },
      { forward_token = { type = "string", required = false }, },
    },
  },
}
