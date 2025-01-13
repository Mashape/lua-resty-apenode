local crypto = require "kong.plugins.basic-auth.crypto"
local constants = require "kong.constants"


local crypto_hash = crypto.hash
local decode_base64 = ngx.decode_base64
local re_gmatch = ngx.re.gmatch
local re_match = ngx.re.match
local error = error
local kong = kong


local HEADERS_CONSUMER_ID           = constants.HEADERS.CONSUMER_ID
local HEADERS_CONSUMER_CUSTOM_ID    = constants.HEADERS.CONSUMER_CUSTOM_ID
local HEADERS_CONSUMER_USERNAME     = constants.HEADERS.CONSUMER_USERNAME
local HEADERS_CREDENTIAL_IDENTIFIER = constants.HEADERS.CREDENTIAL_IDENTIFIER
local HEADERS_ANONYMOUS             = constants.HEADERS.ANONYMOUS


local _M = {}


-- Fast lookup for credential retrieval depending on the type of the authentication
--
-- All methods must respect:
--
-- @param request ngx request object
-- @param {table} conf Plugin config
-- @return {string} public_key
-- @return {string} private_key
local function retrieve_credentials(header_name, conf, ctx)
  local username, password
  local authorization_header = kong.request.get_header(header_name, ctx)

  if authorization_header then
    local iterator, iter_err = re_gmatch(authorization_header, "\\s*[Bb]asic\\s*(.+)", "oj")
    if not iterator then
      kong.log.err(iter_err)
      return
    end

    local m, err = iterator()
    if err then
      kong.log.err(err)
      return
    end

    if m and m[1] then
      local decoded_basic = decode_base64(m[1])
      if decoded_basic then
        local basic_parts, err = re_match(decoded_basic, "([^:]+):(.*)", "oj")
        if err then
          kong.log.err(err)
          return
        end

        if not basic_parts then
          kong.log.err("header has unrecognized format")
          return
        end

        username = basic_parts[1]
        password = basic_parts[2]
      end
    end
  end

  if conf.hide_credentials then
    kong.service.request.clear_header(header_name)
  end

  return username, password
end


--- Validate a credential in the Authorization header against one fetched from the database.
-- @param credential The retrieved credential from the username passed in the request
-- @param given_password The password as given in the Authorization header
-- @return Success of authentication
local function validate_credentials(credential, given_password)
  local digest, err = crypto_hash(credential.consumer.id, given_password)
  if err then
    kong.log.err(err)
  end

  return credential.password == digest
end


local function load_credential_into_memory(username)
  local credential, err = kong.db.basicauth_credentials:select_by_username(username)
  if err then
    return nil, err
  end
  return credential
end


local function load_credential_from_db(username)
  if not username then
    return
  end

  local credential_cache_key = kong.db.basicauth_credentials:cache_key(username)
  local credential, err      = kong.cache:get(credential_cache_key, nil,
                                              load_credential_into_memory,
                                              username)
  if err then
    return error(err)
  end

  return credential
end


local function set_consumer(consumer, credential)
  kong.client.authenticate(consumer, credential)

  local set_header = kong.service.request.set_header
  local clear_header = kong.service.request.clear_header

  if consumer and consumer.id then
    set_header(HEADERS_CONSUMER_ID, consumer.id)
  else
    clear_header(HEADERS_CONSUMER_ID)
  end

  if consumer and consumer.custom_id then
    set_header(HEADERS_CONSUMER_CUSTOM_ID, consumer.custom_id)
  else
    clear_header(HEADERS_CONSUMER_CUSTOM_ID)
  end

  if consumer and consumer.username then
    set_header(HEADERS_CONSUMER_USERNAME, consumer.username)
  else
    clear_header(HEADERS_CONSUMER_USERNAME)
  end

  if credential and credential.username then
    set_header(HEADERS_CREDENTIAL_IDENTIFIER, credential.username)
  else
    clear_header(HEADERS_CREDENTIAL_IDENTIFIER)
  end

  if credential then
    clear_header(HEADERS_ANONYMOUS)
  else
    set_header(HEADERS_ANONYMOUS, true)
  end
end


local function unauthorized(message, www_auth_content)
  return { status = 401, message = message, headers = { ["WWW-Authenticate"] = www_auth_content } }
end


local function do_authentication(conf)
  local www_authenticate = "Basic realm=\"" .. conf.realm .. "\""
  local ctx = {}

  -- If both headers are missing, return 401
  if not (kong.request.get_header("authorization", ctx) or kong.request.get_header("proxy-authorization", ctx)) then
    return false, unauthorized("Unauthorized", www_authenticate)
  end

  local credential
  local given_username, given_password = retrieve_credentials("proxy-authorization", conf, ctx)
  if given_username and given_password then
    credential = load_credential_from_db(given_username)
  end

  -- Try with the authorization header
  if not credential then
    given_username, given_password = retrieve_credentials("authorization", conf, ctx)
    if given_username and given_password then
      credential = load_credential_from_db(given_username)
    else
      return false, unauthorized("Unauthorized", www_authenticate)
    end
  end

  if not credential or not validate_credentials(credential, given_password) then
    return false, unauthorized("Unauthorized", www_authenticate)
  end

  -- Retrieve consumer
  local consumer_cache_key = kong.db.consumers:cache_key(credential.consumer.id)
  local consumer, err      = kong.cache:get(consumer_cache_key, nil,
                                            kong.client.load_consumer,
                                            credential.consumer.id)
  if err then
    return error(err)
  end

  set_consumer(consumer, credential)

  return true
end


function _M.execute(conf)
  if conf.anonymous and kong.client.get_credential() then
    -- we're already authenticated, and we're configured for using anonymous,
    -- hence we're in a logical OR between auth methods and we're already done.
    return
  end

  local ok, err = do_authentication(conf)
  if not ok then
    if conf.anonymous then
      -- get anonymous user
      local consumer_cache_key = kong.db.consumers:cache_key(conf.anonymous)
      local consumer, err      = kong.cache:get(consumer_cache_key, nil,
                                                kong.client.load_consumer,
                                                conf.anonymous, true)
      if err then
        return error(err)
      end

      if not consumer then
        local err_msg = "anonymous consumer " .. conf.anonymous .. " is configured but doesn't exist"
        kong.log.err(err_msg)
        return kong.response.error(500, err_msg)
      end

      set_consumer(consumer)

    else
      return kong.response.error(err.status, err.message, err.headers)
    end
  end
end


return _M
