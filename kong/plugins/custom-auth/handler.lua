local http  = require("resty.http")
local cjson = require("cjson.safe")

local error = error

local handler = {
  PRIORITY = 1000,
  VERSION = "0.0.1",
}

local function unauthorized()
  return {
    status = 401,
    message = "Unauthorized",
  }
end

local function bad_request()
  return {
    status = 400,
    message = "Bad Request",
  }
end

local function internal_server_error()
  return {
    status = 500,
    message = "Internal Server Error",
  }
end

local function load_auth(key)
  kong.log.debug("try to load from db " .. key)
  local auth, err = kong.db.custom_auth_table:select_by_key(key)
  if not auth then
    kong.log.debug("not found from db")
    return nil, err
  end

  if auth.ttl == 0 then
    kong.log.debug("db key expired")
    return nil
  end

  return auth, nil, auth.ttl
end

local function get_from_remote_server(conf, header, auth)
  local httpc = http.new()
  local res, err = httpc:request_uri(conf.auth_server_url, {
    method = "GET",
    headers = {
      [conf.request_header_name] = header,
    },
  })

  -- if request_header_name enabled
  if res ~= nil and res.status == 200 then
    kong.log.debug("remote server returned 200 and proceed")

    local forward_token = nil

    if conf.forward_key ~= nil then
      local body_table, err = cjson.decode(res.body)

      if err then
        return false, {
          status = 500,
          message = "Error while decoding 3rd party service response: " .. err,
        }
      end

      -- if res.headers[conf.forward_key] == nil then
      if body_table.headers[conf.forward_key] == nil then
        kong.log.warn("No " .. conf.forward_key .. " from remove auth server")
        -- make it configurable to fail here or proceed?
      else
        forward_token = body_table.headers[conf.forward_key]
        kong.service.request.set_header(conf.forward_key, forward_token)
      end
    end

    local entity, err
    if auth then
      entity, err = kong.db.custom_auth_table:update(
      { id = auth.id },
      { expire_at = os.time() + conf.ttl,
      key = header,
      forward_token = forward_token }
      )
    else
      entity, err = kong.db.custom_auth_table:insert({
        expire_at = os.time() + conf.ttl,
        key = header,
        forward_token = forward_token
      })
    end
    if not entity then
      kong.log.err("Error when inserting keyauth credential: " .. err)
      return false, internal_server_error()
    end
  else
    kong.log.warn("remote server returned " .. res.status)
    return false, unauthorized()
  end

  return true
end

function get_from_cache(header)
  local cache_key = kong.db.custom_auth_table:cache_key(header)
  local auth, err = kong.cache:get(cache_key, nil, load_auth, header)

  if err then
    kong.log.err(err)
    return false, internal_server_error()
  end

  if auth then
    local forward_token = ""
    if auth.forward_token then
      forward_token = auth.forward_token
    end

    kong.log.debug("find auth in cache and proceed, expire_at: " .. auth.expire_at .. " forward_token: " .. forward_token)
    kong.log.debug("now is " .. os.time())

  else
    kong.log.debug("not in cache")
  end

  if auth and os.time() < auth.expire_at then
    if auth.forward_token then
      kong.service.request.set_header(conf.forward_key, auth.forward_token)
    end
    -- make response header configurable?
    -- kong.response.set_header("Kong-Custom-Auth-cache", "Hit")
    return false
  end

  return true, nil, auth
end

function handler:access(conf)
  kong.log("custom-plugin access handler")

  local header = kong.request.get_header(conf.request_header_name)

  if header == nil then
    local err = bad_request()
    return kong.response.exit(err.status, err.message, err.headers)
  end

  local proceed, err, auth = get_from_cache(header)

  if not proceed then
    if err then
      return kong.response.exit(err.status, err.message, err.headers)
    end
    -- don't proceed and no error, then we have a cache hit
    return
  end

  -- kong.response.set_header("Kong-Custom-Auth-Cache", "Miss")
  local ok, err = get_from_remote_server(conf, header, auth)

  if not ok then
    return kong.response.exit(err.status, err.message, err.headers)
  end
end

return handler
