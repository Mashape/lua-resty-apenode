local typedefs = require "kong.db.schema.typedefs"

return {
  name = "azure-functions",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- connection basics
          {
            timeout = {
              description = "Timeout in milliseconds before closing a connection to the Azure Functions server.",
              type = "number",
              default = 600000,
            },
          },
          {
            keepalive = {
              description =
              "Time in milliseconds during which an idle connection to the Azure Functions server lives before being closed.",
              type = "number",
              default = 60000
            },
          },
          {
            https = {
              type = "boolean",
              default = true,
              description = "Use of HTTPS to connect with the Azure Functions server."
            },
          },
          {
            https_verify = {
              description = "Set to `true` to authenticate the Azure Functions server.",
              type = "boolean",
              default = false,
            },
          },
          -- authorization
          {
            apikey = {
              description =
              "The apikey to access the Azure resources. If provided, it is injected as the `x-functions-key` header.",
              type = "string",
              encrypted = true,
              referenceable = true
            },
          }, -- encrypted = true is a Kong Enterprise Exclusive feature. It does nothing in Kong CE
          {
            clientid = {
              description =
              "The `clientid` to access the Azure resources. If provided, it is injected as the `x-functions-clientid` header.",
              type = "string",
              encrypted = true,
              referenceable = true,
            },
          }, -- encrypted = true is a Kong Enterprise Exclusive feature. It does nothing in Kong CE
          -- target/location
          {
            appname = {
              description = "The Azure app name.",
              type = "string",
              required = true
            },
          },
          {
            hostdomain = {
              description = "The domain where the function resides.",
              type = "string",
              required = true,
              default = "azurewebsites.net",
            },
          },
          {
            routeprefix = {
              description = "Route prefix to use.",
              type = "string",
              default = "api",
            },
          },
          {
            functionname = {
              description = "Name of the Azure function to invoke.",
              type = "string",
              required = true,
            },
          },
        },
      },
    },
  }
}
