local redis = require "resty.redis"
local version = require "version"

local DEFAULT_TIMEOUT = 2000


local function connect(host, port, password)
  local redis_client = redis:new()
  redis_client:set_timeout(DEFAULT_TIMEOUT)
  assert(redis_client:connect(host, port))
  if password then
    assert(redis_client:auth(password))
  end
  local red_version = string.match(redis_client:info(), 'redis_version:([%g]+)\r\n')
  return redis_client, assert(version(red_version))
end

local function reset_redis(host, port, password)
  local redis_client = connect(host, port, password)

  local config_res = redis_client:config("get", "databases")
  local num_databases = (config_res and config_res[2]) and tonumber(config_res[2]) or 1

  for db = 0, num_databases - 1 do
    redis_client:select(db)
    local cursor = "0"
    repeat
      local result = redis_client:scan(cursor)
      cursor = result[1]
      for _, key in ipairs(result[2]) do redis_client:del(key) end
    until cursor == "0"
  end

  redis_client:close()
end

local function add_admin_user(redis_client, username, password)
  assert(redis_client:acl("setuser", username, "on", "allkeys", "allcommands", ">" .. password))
end

local function add_basic_user(redis_client, username, password)
  assert(redis_client:acl("setuser", username, "on", "allkeys", "+get", ">" .. password))
end

local function remove_user(redis_client, username)
  assert(redis_client:acl("deluser", username))
end


return {
  connect = connect,
  add_admin_user = add_admin_user,
  add_basic_user = add_basic_user,
  remove_user = remove_user,
  reset_redis = reset_redis,
}
