local utils = require "kong.admin_gui.utils"

local fmt = string.format
local insert = table.insert
local concat = table.concat

local prepare_variable = utils.prepare_variable

local _M = {}

function _M.generate_kconfig(kong_config)
  local configs = {
    ADMIN_GUI_PATH = prepare_variable(kong_config.admin_gui_path),
    ADMIN_API_URL = prepare_variable(kong_config.admin_gui_api_url),
    ANONYMOUS_REPORTS = prepare_variable(kong_config.anonymous_reports),
  }

  local out = {}
  for config, value in pairs(configs) do
    insert(out, fmt("  '%s': '%s'", config, value))
  end

  return "window.K_CONFIG = {\n" .. concat(out, ",\n") .. "\n}\n"
end

return _M
