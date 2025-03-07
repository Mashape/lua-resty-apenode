local typedefs = require "kong.db.schema.typedefs"

return {
  name = "grpc-web",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        {
          proto = { description = "If present, describes the gRPC types and methods. Required to support payload transcoding. When absent, the web client must use application/grpw-web+proto content.", type = "string",
            required = false,
            default = nil,
          },
        },
        {
          pass_stripped_path = { description = "If set to `true` causes the plugin to pass the stripped request path to the upstream gRPC service.", type = "boolean",
            required = false,
          },
        },
        {
          allow_origin_header = { description = "The value of the `Access-Control-Allow-Origin` header in the response to the gRPC-Web client.", type = "string",
            required = false,
            default = "*",
          },
        },
      },
    }, },
  },
}
