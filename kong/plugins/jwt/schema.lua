local typedefs = require "kong.db.schema.typedefs"


return {
  name = "jwt",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { uri_param_names = {
              description = "A list of querystring parameters that Kong will inspect to retrieve JWTs.",
              type = "set",
              elements = { type = "string" },
              default = { "jwt" },
          }, },
          { cookie_names = {
              description = "A list of cookie names that Kong will inspect to retrieve JWTs.",
              type = "set",
              elements = { type = "string" },
              default = {}
          }, },
          { key_claim_name = { description = "The name of the claim in which the key identifying the secret must be passed. The plugin will attempt to read this claim from the JWT payload and the header, in that order.", type = "string", default = "iss" }, },
          { secret_is_base64 = { description = "If true, the plugin assumes the credential’s secret to be base64 encoded. You will need to create a base64-encoded secret for your Consumer, and sign your JWT with the original secret.", type = "boolean", required = true, default = false }, },
          { claims_to_verify = {
              description = "A list of registered claims (according to RFC 7519) that Kong can verify as well. Accepted values: one of exp or nbf.",
              type = "set",
              elements = {
                type = "string",
                one_of = { "exp", "nbf" },
          }, }, },
          { headers_to_set = {
            type = "set",
            elements = {
              type = "string"
          }, }, },
          { anonymous = { description = "An optional string (consumer UUID or username) value to use as an “anonymous” consumer if authentication fails.", type = "string" }, },
          { run_on_preflight = { description = "A boolean value that indicates whether the plugin should run (and try to authenticate) on OPTIONS preflight requests. If set to false, then OPTIONS requests will always be allowed.", type = "boolean", required = true, default = true }, },
          { maximum_expiration = {
            description = "A value between 0 and 31536000 (365 days) limiting the lifetime of the JWT to maximum_expiration seconds in the future.",
            type = "number",
            default = 0,
            between = { 0, 31536000 },
          }, },
          { header_names = {
            description = "A list of HTTP header names that Kong will inspect to retrieve JWTs.",
            type = "set",
            elements = { type = "string" },
            default = { "authorization" },
          }, },
          { realm = { description = "When authentication fails the plugin sends `WWW-Authenticate` header with `realm` attribute value.", type = "string", required = false }, },
        },
      },
    },
  },
  entity_checks = {
    { conditional = {
        if_field = "config.maximum_expiration",
        if_match = { gt = 0 },
        then_field = "config.claims_to_verify",
        then_match = { contains = "exp" },
    }, },
  },
}
