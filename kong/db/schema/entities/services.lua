local typedefs = require "kong.db.schema.typedefs"
local Schema = require "kong.db.schema"
local url = require "socket.url"


local tostring = tostring
local tonumber = tonumber
local null = ngx.null


local nonzero_timeout = Schema.define {
  type = "integer",
  between = { 1, math.pow(2, 31) - 2 },
}


local default_protocol = "http"
local default_port = 80


return {
  name = "services",
  primary_key = { "id" },
  workspaceable = true,
  endpoint_key = "name",
  dao = "kong.db.dao.services",

  fields = {
    { id                 = typedefs.uuid, },
    { created_at         = typedefs.auto_timestamp_s },
    { updated_at         = typedefs.auto_timestamp_s },
    { name               = typedefs.utf8_name },
    { retries            = { description = "The number of retries to execute upon failure to proxy.",
    type = "integer", default = 5, between = { 0, 32767 } }, },
    -- { tags             = { type = "array", array = { type = "string" } }, },
    { protocol           = typedefs.protocol { required = true, default = default_protocol } },
    { host               = typedefs.host { required = true } },
    { port               = typedefs.port { required = true, default = default_port }, },
    { path               = typedefs.path },
    { connect_timeout    = nonzero_timeout { default = 60000 }, },
    { write_timeout      = nonzero_timeout { default = 60000 }, },
    { read_timeout       = nonzero_timeout { default = 60000 }, },
    { tags               = typedefs.tags },
    { client_certificate = { description = "Certificate to be used as client certificate while TLS handshaking to the upstream server.", type = "foreign", reference = "certificates" }, },
    { tls_verify         = { description = "Whether to enable verification of upstream server TLS certificate. If not set, the global level config `proxy_ssl_verify` will be used.", type = "boolean", }, },
    { tls_verify_depth   = { description = "Maximum depth of chain while verifying Upstream server's TLS certificate.", type = "integer", default = null, between = { 0, 64 }, }, },
    { ca_certificates    = { description = "Array of CA Certificate object UUIDs that are used to build the trust store while verifying upstream server's TLS certificate.", type = "array", elements = { type = "string", uuid = true, }, }, },
    { enabled            = { description = "Whether the Service is active. ", type = "boolean", required = true, default = true, }, },
    -- { load_balancer = { type = "foreign", reference = "load_balancers" } },
  },

  entity_checks = {
    { conditional = { if_field = "protocol",
                      if_match = { one_of = { "tcp", "tls", "udp", "grpc", "grpcs" }},
                      then_field = "path",
                      then_match = { eq = null }}},
    { conditional = { if_field = "protocol",
                      if_match = { not_one_of = {"https", "tls"} },
                      then_field = "client_certificate",
                      then_match = { eq = null }}},
    { conditional = { if_field = "protocol",
                      if_match = { not_one_of = { "https", "tls", "grpcs" } },
                      then_field = "tls_verify",
                      then_match = { eq = null }}},
    { conditional = { if_field = "protocol",
                      if_match = { not_one_of = { "https", "tls", "grpcs" } },
                      then_field = "tls_verify_depth",
                      then_match = { eq = null }}},
    { conditional = { if_field = "protocol",
                      if_match = { not_one_of = { "https", "tls", "grpcs" } },
                      then_field = "ca_certificates",
                      then_match = { eq = null }}},
  },

  shorthand_fields = {
    { url = {
      type = "string",
      func = function(sugar_url)
        local parsed_url = url.parse(tostring(sugar_url))
        if not parsed_url then
          return
        end

        local port = tonumber(parsed_url.port)

        local prot
        if port == 80 then
          prot = "http"
        elseif port == 443 then
          prot = "https"
        end

        local protocol = parsed_url.scheme or prot or default_protocol

        return {
          protocol = protocol,
          host = parsed_url.host or null,
          port = port or
                 parsed_url.port or
                 (protocol == "http"  and 80)  or
                 (protocol == "https" and 443) or
                 default_port,
          path = parsed_url.path or null,
        }
      end
    }, },
  }
}
