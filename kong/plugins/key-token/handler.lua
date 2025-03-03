local access = require "kong.plugins.key-token.access"


local plugin = {
  PRIORITY = 1255, -- Execute before key-auth
  VERSION = "0.1.0", -- The initial version
}


-- runs in the 'access_by_lua_block'
function plugin:access(plugin_conf)
  access:execute(plugin_conf)
end --]]


-- return our plugin object
return plugin
