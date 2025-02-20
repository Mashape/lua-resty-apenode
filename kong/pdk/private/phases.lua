local bit = require "bit"


local band = bit.band
local fmt = string.format
local ngx_get_phase = ngx.get_phase


local PHASES = {
  --init            = 0x00000001,
  init_worker       = 0x00000001,
  certificate       = 0x00000002,
  client_hello      = 0x00000008,
  --set             = 0x00000004,
  rewrite           = 0x00000010,
  access            = 0x00000020,
  balancer          = 0x00000040,
  response          = 0x00000080,
  --content         = 0x00000100,
  header_filter     = 0x00000200,
  body_filter       = 0x00000400,
  --timer           = 0x00001000,
  log               = 0x00002000,
  preread           = 0x00004000,
  error             = 0x01000000,
  admin_api         = 0x10000000,
  cluster_listener  = 0x00000100,
}


do
  local t = {}
  for k, v in pairs(PHASES) do
    t[k] = v
  end

  for k, v in pairs(t) do
    PHASES[v] = k
  end

  -- max lshift limit, 2^30 = 0x40000000
  PHASES.n = 30
end


local function new_phase(...)
  return bit.bor(...)
end


local function get_phases_names(phases)
  local names = {}
  local n = 1

  for _ = 1, PHASES.n do
    if band(phases, n) ~= 0 and PHASES[n] then
      table.insert(names, PHASES[n])
    end

    n = bit.lshift(n, 1)
  end

  return names
end


local function check_phase(accepted_phases)
  if not kong or not kong.ctx then
    -- no _G.kong, we are likely in tests
    return
  end

  local current_phase = ngx.ctx.KONG_PHASE
  if not current_phase then
    if ngx_get_phase() == "content" then
      -- treat custom content blocks as the Admin API
      current_phase = PHASES.admin_api
    else
      error(fmt("no phase in ngx.ctx.KONG_PHASE, (need one of %s)",
                table.concat(get_phases_names(accepted_phases), ", ")), 3)
    end
  end

  if band(current_phase, accepted_phases) ~= 0 then
    return
  end

  local current_phase_name = PHASES[current_phase] or "'unknown phase'"
  local accepted_phases_names = get_phases_names(accepted_phases)

  error(fmt("function cannot be called in %s phase (only in: %s)",
            current_phase_name,
            table.concat(accepted_phases_names, ", ")), 3)
end


local function check_not_phase(rejected_phases)
  if not kong or not kong.ctx then
    -- no _G.kong, we are likely in tests
    return
  end

  local current_phase = ngx.ctx.KONG_PHASE
  if not current_phase then
    error("no phase in ngx.ctx.KONG_PHASE", 3)
  end

  if band(current_phase, rejected_phases) == 0 then
    return
  end

  local current_phase_name = PHASES[current_phase] or "'unknown phase'"
  local rejected_phases_names = get_phases_names(rejected_phases)

  error(fmt("function cannot be called in %s phase (can be called in any " ..
            "phases except: %s)",
            current_phase_name,
            table.concat(rejected_phases_names, ", ")), 3)
end


-- Exact phases + convenience aliases
local public_phases = setmetatable({
  request = new_phase(PHASES.rewrite,
                      PHASES.access,
                      PHASES.balancer,
                      PHASES.response,
                      PHASES.header_filter,
                      PHASES.body_filter,
                      PHASES.log,
                      PHASES.error,
                      PHASES.admin_api,
                      PHASES.cluster_listener),
}, {
  __index = function(t, k)
    error("unknown phase or phase alias: " .. k)
  end
})


for k, v in pairs(PHASES) do
  public_phases[k] = v
end


return {
  new = new_phase,
  check = check_phase,
  check_not = check_not_phase,
  phases = public_phases,
}
