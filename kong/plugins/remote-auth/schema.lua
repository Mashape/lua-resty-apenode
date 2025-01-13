local typedefs = require "kong.db.schema.typedefs"

local PLUGIN_NAME = "remote-auth"


local schema = {
  name = PLUGIN_NAME,
  fields = {
    { consumer = typedefs.no_consumer },     -- this plugin cannot be configured on a consumer (typical for auth plugins)
    { protocols = typedefs.protocols_http }, -- http protocols only
    {
      config = {
        type = "record",
        fields = {
          {
            auth_request_url = typedefs.url {
              required = true,
            }
          },
          {
            consumer_auth_header = typedefs.header_name {
              required = true,
              default = "Authorization",
            }
          },
          {
            auth_request_method = typedefs.http_method {
              required = true,
              default = "POST",
            }
          },
          {
            auth_request_timeout = typedefs.timeout {
              required = true,
              default = 10000,
            }
          },
          {
            auth_request_keepalive = {
              type = "number",
              default = 60000,
              required = true,
              description =
              "A value in milliseconds that defines how long an idle connection will live before being closed.",
            }
          },
          {
            auth_request_token_header = typedefs.header_name {
              required = true,
              default = "Authorization",
            }
          },
          {
            auth_response_token_header = typedefs.header_name {
              required = true,
              default = "X-Token"
            }
          },
          {
            auth_request_headers = {
              description =
              "An optional table of headers included in the HTTP message to the upstream server. Values are indexed by header name, and each header name accepts a single string.",
              type = "map",
              required = false,
              keys = typedefs.header_name {
                match_none = {
                  {
                    pattern = "^[Hh][Oo][Ss][Tt]$",
                    err = "cannot contain 'Host' header",
                  },
                  {
                    pattern = "^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][nn][Gg][Tt][Hh]$",
                    err = "cannot contain 'Content-Length' header",
                  },
                  {
                    pattern = "^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Tt][Yy][Pp][Ee]$",
                    err = "cannot contain 'Content-Type' header",
                  },
                },
              },
              values = {
                type = "string",
                referenceable = true,
              },
            }
          },
          {
            service_auth_header = typedefs.header_name {
              required = true,
              default = "Authorization",
            }
          },
          {
            service_auth_header_value_prefix = {
              type = "string",
              default = "bearer ",
              required = true,
              description = "A header value prefix for the upstream service request header value.",
            }
          },
          {
            request_authentication_header = typedefs.header_name {
              required = true,
              default = "X-Token",
            }
          },
          {
            jwt_public_key = {
              type = "string",
              required = true,
              description = "The public key used to verify the siguration of issued JWT tokens",
            }
          },
          {
            jwt_max_expiration = {
              description =
              "A value between 0 and 31536000 (365 days) limiting the lifetime of the JWT to maximum_expiration seconds in the future.",
              type = "number",
              between = { 0, 31536000 },
              required = false,
              default = 0,
            }
          },

        },
        entity_checks = {},
      },
    },
  },
}

return schema
