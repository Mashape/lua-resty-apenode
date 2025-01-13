local http = require "kong.plugins.key-token.auth_service"
local error = error


local _M = {}


function _M:execute(plugin_conf)
  -- Here is the main logic
  -- 1. check if the client has the auth_key in the header.
  --    1.1 if user has no auth_key,  return 412
  --    1.2 if user has auth_key use the key to auth authentication server
  -- 2.1 if the JWT token is valid then go to 4
  -- 2.2 request the authentication server with the auth_key
  --    2.2.1 authentication server reply 200 with the JWT token is the auth_key is valid,
  --    2.2.2 authentication server reply 403 reject the request if the auth_key is invalid
  -- 3  cache the JWT token
  -- 4.1 if none 200, return immediately, no access to the upstream
  -- 4.2 if 200, access the upstream with the Authentication header
  local auth_key = kong.request.get_header(plugin_conf.request_key_name)
  local auth_server = plugin_conf.auth_server
  local ttl = plugin_conf.ttl
  local cached_token, err = self:get_cached_token(auth_key, auth_server, ttl)
  if err then
    kong.log.err("Failed to acquire token associates with the key. Error: " .. err)
    return
  end

  if cached_token then
    self:inject_token_to_service_header(cached_token)
    return
  end

end


function _M:get_cached_token(auth_key, auth_server, ttl)
  -- return the cached token if it is not out of life. or else return nil
  local cache = kong.cache
  local credential_cache_key = kong.db.keyauth_credentials:cache_key(auth_key)
  local credential, err = cache:get(credential_cache_key, { resurrent_ttl = ttl }, load_auth_token, auth_key, auth_server)
  if err then
    return nil, err
  else
    return credential, nil
  end
end


function _M:inject_token_to_service_header(token)
    kong.service.request.set_header("Authorizaion", "Bearer " .. token)
end


function _M:save_token_to_cache(auth_key, token)
end

function load_auth_token(auth_key, auth_server)
  -- Maybe to set TIMEOUT variable to control the timeout?
  local auth_headers = { auth_key = auth_key }
  local body, status_code, headers, status_text = http.request {
    url = auth_server,
    headers = auth_headers,
  }

  kong.log.debug("return code from auth service " .. status_code)
  if status_code == 200 then
    return body, nil
  else
    return nil, error("Auth server return non 200 code " .. status_code)
  end
end


return _M
