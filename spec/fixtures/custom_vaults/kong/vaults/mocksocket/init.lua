local env = require "kong.vaults.env"
local http = require "resty.http"


local assert = assert
local getenv = os.getenv


local function init()
  env.init()
  assert(getenv("KONG_PROCESS_SECRETS") == nil, "KONG_PROCESS_SECRETS environment variable found")
  assert(env.get({}, "KONG_PROCESS_SECRETS") == nil, "KONG_PROCESS_SECRETS environment variable found")
end


local function get(conf, resource, version)
  local client, err = http.new()
  if not client then
    return nil, err
  end

  client:set_timeouts(20000, 20000, 20000)
  assert(client:request_uri("http://mockbin.org/headers", {
    headers = {
      Accept = "application/json",
    },
  }))

  return env.get(conf, resource, version)
end


return {
  VERSION = "1.0.0",
  init = init,
  get = get,
}
