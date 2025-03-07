local constants = require "kong.constants"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local kong_meta = require "kong.meta"


local fmt = string.format
local kong = kong
local type = type
local error = error
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local re_gmatch = ngx.re.gmatch

local consts = {
  JWT_CLAIM_HEADER_PREFIX = "X-Jwt-Claim"
}

local JwtHandler = {
  VERSION = kong_meta.version,
  PRIORITY = 1450,
}


--- Retrieve a JWT in a request.
-- Checks for the JWT in URI parameters, then in cookies, and finally
-- in the configured header_names (defaults to `[Authorization]`).
-- @param conf Plugin configuration
-- @return token JWT token contained in request (can be a table) or nil
-- @return err
local function retrieve_tokens(conf)
  local token_set = {}
  local args = kong.request.get_query()
  for _, v in ipairs(conf.uri_param_names) do
    local token = args[v] -- can be a table
    if token then
      if type(token) == "table" then
        for _, t in ipairs(token) do
          if t ~= "" then
            token_set[t] = true
          end
        end

      elseif token ~= "" then
        token_set[token] = true
      end
    end
  end

  local var = ngx.var
  for _, v in ipairs(conf.cookie_names) do
    local cookie = var["cookie_" .. v]
    if cookie and cookie ~= "" then
      token_set[cookie] = true
    end
  end

  local request_headers = kong.request.get_headers()
  for _, v in ipairs(conf.header_names) do
    local token_header = request_headers[v]
    if token_header then
      if type(token_header) == "table" then
        token_header = token_header[1]
      end
      local iterator, iter_err = re_gmatch(token_header, "\\s*[Bb]earer\\s+(.+)", "jo")
      if not iterator then
        kong.log.err(iter_err)
        break
      end

      local m, err = iterator()
      if err then
        kong.log.err(err)
        break
      end

      if m and #m > 0 then
        if m[1] ~= "" then
          token_set[m[1]] = true
        end
      end
    end
  end

  local tokens_n = 0
  local tokens = {}
  for token, _ in pairs(token_set) do
    tokens_n = tokens_n + 1
    tokens[tokens_n] = token
  end

  if tokens_n == 0 then
    return nil
  end

  if tokens_n == 1 then
    return tokens[1]
  end

  return tokens
end


local function load_credential(jwt_secret_key)
  local row, err = kong.db.jwt_secrets:select_by_key(jwt_secret_key)
  if err then
    return nil, err
  end
  return row
end


local function set_consumer(consumer, credential, token)
  kong.client.authenticate(consumer, credential)

  local set_header = kong.service.request.set_header
  local clear_header = kong.service.request.clear_header

  if consumer and consumer.id then
    set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
  else
    clear_header(constants.HEADERS.CONSUMER_ID)
  end

  if consumer and consumer.custom_id then
    set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
  else
    clear_header(constants.HEADERS.CONSUMER_CUSTOM_ID)
  end

  if consumer and consumer.username then
    set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
  else
    clear_header(constants.HEADERS.CONSUMER_USERNAME)
  end

  if credential and credential.key then
    set_header(constants.HEADERS.CREDENTIAL_IDENTIFIER, credential.key)
  else
    clear_header(constants.HEADERS.CREDENTIAL_IDENTIFIER)
  end

  if credential then
    clear_header(constants.HEADERS.ANONYMOUS)
  else
    set_header(constants.HEADERS.ANONYMOUS, true)
  end

  kong.ctx.shared.authenticated_jwt_token = token -- TODO: wrap in a PDK function?
end

local function unauthorized(message, www_auth_content, errors)
  return { status = 401, message = message, headers = { ["WWW-Authenticate"] = www_auth_content }, errors = errors }
end

-- set header keys from claims
local function set_headers(conf, claims)
  local set_header = kong.service.request.set_header
  for _, v in ipairs(conf.headers_to_set) do
    if claims[v] then
      set_header(consts.JWT_CLAIM_HEADER_PREFIX.."-"..v, claims[v])
    end
  end
end

local function do_authentication(conf)
  local token, err = retrieve_tokens(conf)
  if err then
    return error(err)
  end

  local www_authenticate_base = conf.realm and fmt('Bearer realm="%s"', conf.realm) or 'Bearer'
  local www_authenticate_with_error = www_authenticate_base .. ' error="invalid_token"'
  local token_type = type(token)
  if token_type ~= "string" then
    if token_type == "nil" then
      return false, unauthorized("Unauthorized", www_authenticate_base)
    elseif token_type == "table" then
      return false, unauthorized("Multiple tokens provided", www_authenticate_with_error)
    else
      return false, unauthorized("Unrecognizable token", www_authenticate_with_error)
    end
  end

  -- Decode token to find out who the consumer is
  local jwt, err = jwt_decoder:new(token)
  if err then
    return false, unauthorized("Bad token; " .. tostring(err), www_authenticate_with_error)
  end

  local claims = jwt.claims
  local header = jwt.header

  local jwt_secret_key = claims[conf.key_claim_name] or header[conf.key_claim_name]
  if not jwt_secret_key then
    return false, unauthorized("No mandatory '" .. conf.key_claim_name .. "' in claims", www_authenticate_with_error)
  elseif jwt_secret_key == "" then
    return false, unauthorized("Invalid '" .. conf.key_claim_name .. "' in claims", www_authenticate_with_error)
  end

  -- Retrieve the secret
  local jwt_secret_cache_key = kong.db.jwt_secrets:cache_key(jwt_secret_key)
  local jwt_secret, err      = kong.cache:get(jwt_secret_cache_key, nil,
                                              load_credential, jwt_secret_key)
  if err then
    return error(err)
  end

  if not jwt_secret then
    return false, unauthorized("No credentials found for given '" .. conf.key_claim_name .. "'", www_authenticate_with_error)
  end

  local algorithm = jwt_secret.algorithm or "HS256"

  -- Verify "alg"
  if jwt.header.alg ~= algorithm then
    return false, unauthorized("Invalid algorithm", www_authenticate_with_error)
  end

  local jwt_secret_value = algorithm ~= nil and algorithm:sub(1, 2) == "HS" and
                           jwt_secret.secret or jwt_secret.rsa_public_key

  if conf.secret_is_base64 then
    jwt_secret_value = jwt:base64_decode(jwt_secret_value)
  end

  if not jwt_secret_value then
    return false, unauthorized("Invalid key/secret", www_authenticate_with_error)
  end

  -- Now verify the JWT signature
  if not jwt:verify_signature(jwt_secret_value) then
    return false, unauthorized("Invalid signature", www_authenticate_with_error)
  end

  -- Verify the JWT registered claims
  local ok_claims, errors = jwt:verify_registered_claims(conf.claims_to_verify)
  if not ok_claims then
    return false, unauthorized(nil, www_authenticate_with_error, errors)
  end

  -- Verify the JWT registered claims
  if conf.maximum_expiration ~= nil and conf.maximum_expiration > 0 then
    local ok, errors = jwt:check_maximum_expiration(conf.maximum_expiration)
    if not ok then
      return false, unauthorized(nil, www_authenticate_with_error, errors)
    end
  end

  -- Retrieve the consumer
  local consumer_cache_key = kong.db.consumers:cache_key(jwt_secret.consumer.id)
  local consumer, err      = kong.cache:get(consumer_cache_key, nil,
                                            kong.client.load_consumer,
                                            jwt_secret.consumer.id, true)
  if err then
    return error(err)
  end

  -- However this should not happen
  if not consumer then
    return false, {
      status = 401,
      message = fmt("Could not find consumer for '%s=%s'", conf.key_claim_name, jwt_secret_key)
    }
  end

  set_consumer(consumer, jwt_secret, token)

  set_headers(conf, claims)

  return true
end


local function set_anonymous_consumer(anonymous)
  local consumer_cache_key = kong.db.consumers:cache_key(anonymous)
  local consumer, err = kong.cache:get(consumer_cache_key, nil,
                                        kong.client.load_consumer,
                                        anonymous, true)
  if err then
    return error(err)
  end

  set_consumer(consumer)
end


--- When conf.anonymous is enabled we are in "logical OR" authentication flow.
--- Meaning - either anonymous consumer is enabled or there are multiple auth plugins
--- and we need to passthrough on failed authentication.
local function logical_OR_authentication(conf)
  if kong.client.get_credential() then
    -- we're already authenticated and in "logical OR" between auth methods -- early exit
    return
  end

  local ok, _ = do_authentication(conf)
  if not ok then
    set_anonymous_consumer(conf.anonymous)
  end
end

--- When conf.anonymous is not set we are in "logical AND" authentication flow.
--- Meaning - if this authentication fails the request should not be authorized
--- even though other auth plugins might have successfully authorized user.
local function logical_AND_authentication(conf)
  local ok, err = do_authentication(conf)
  if not ok then
    return kong.response.exit(err.status, err.errors or { message = err.message }, err.headers)
  end
end


function JwtHandler:access(conf)
  -- check if preflight request and whether it should be authenticated
  if not conf.run_on_preflight and kong.request.get_method() == "OPTIONS" then
    return
  end

  if conf.anonymous then
    return logical_OR_authentication(conf)
  else
    return logical_AND_authentication(conf)
  end
end


return JwtHandler
