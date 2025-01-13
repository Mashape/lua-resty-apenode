local access = require "kong.plugins.remote-auth.access"

local plugin = {
  PRIORITY = 1100,
  VERSION = "0.1.0",
}

function plugin:access(plugin_conf)
  access.authenticate(plugin_conf)
end

return plugin
