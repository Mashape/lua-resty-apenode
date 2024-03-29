-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local type    = type
local xpcall  = xpcall
local require = require
local error   = error
local find    = string.find


local _M = {}


--- Try to load a module.
-- Will not throw an error if the module was not found, but will throw an error if the
-- loading failed for another reason (eg: syntax error).
-- @param module_name Path of the module to load (ex: kong.plugins.keyauth.api).
-- @return success A boolean indicating whether the module was found.
-- @return module The retrieved module, or the error in case of a failure
function _M.load_module_if_exists(module_name)
  local status, res = xpcall(require, debug.traceback, module_name)

  if status then
    return true, res
  end

  -- Here we match any character because if a module has a dash '-' in its name, we would need to escape it.
  if type(res) == "string" and find(res, "module '" .. module_name .. "' not found", nil, true) then
    return false, res
  end

  error("error loading module '" .. module_name .. "':\n" .. res)
end


return _M
