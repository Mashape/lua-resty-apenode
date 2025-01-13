local constants = require "kong.constants"
local openssl_mac = require "resty.openssl.mac"


local sha256_base64 = require("kong.tools.sha256").sha256_base64
local string_split = require("kong.tools.string").split


local ngx = ngx
local kong = kong
local error = error
local time = ngx.time
local abs = math.abs
local decode_base64 = ngx.decode_base64
local parse_time = ngx.parse_http_time
local re_gmatch = ngx.re.gmatch
local hmac_sha1 = ngx.hmac_sha1
local ipairs = ipairs
local fmt = string.format
local string_lower = string.lower
local kong_request = kong.request
local kong_client = kong.client
local kong_service_request = kong.service.request


local AUTHORIZATION = "authorization"
local PROXY_AUTHORIZATION = "proxy-authorization"
local DATE = "date"
local X_DATE = "x-date"
local DIGEST = "digest"
local SIGNATURE_NOT_VALID = "HMAC signature cannot be verified"
local SIGNATURE_NOT_SAME = "HMAC signature does not match"


local hmac = {
  ["hmac-sha1"] = function(secret, data)
    return hmac_sha1(secret, data)
  end,
  ["hmac-sha256"] = function(secret, data)
    return openssl_mac.new(secret, "HMAC", nil, "sha256"):final(data)
  end,
  ["hmac-sha384"] = function(secret, data)
    return openssl_mac.new(secret, "HMAC", nil, "sha384"):final(data)
  end,
  ["hmac-sha512"] = function(secret, data)
    return openssl_mac.new(secret, "HMAC", nil, "sha512"):final(data)
  end,
}


local function list_as_set(list)
  local set = kong.table.new(0, #list)
  for _, v in ipairs(list) do
    set[v] = true
  end

  return set
end


local function validate_params(params, conf)
  -- check username and signature are present
  if not params.username or not params.signature then
    return nil, "username or signature missing"
  end

  -- check enforced headers are present
  if conf.enforce_headers and #conf.enforce_headers >= 1 then
    local enforced_header_set = list_as_set(conf.enforce_headers)

    if params.hmac_headers then
      for _, header in ipairs(params.hmac_headers) do
        enforced_header_set[header] = nil
      end
    end

    for _, header in ipairs(conf.enforce_headers) do
      if enforced_header_set[header] then
        return nil, "enforced header not used for signature creation"
      end
    end
  end

  -- check supported alorithm used
  for _, algo in ipairs(conf.algorithms) do
    if algo == params.algorithm then
      return true
    end
  end

  return nil, fmt("algorithm %s not supported", params.algorithm)
end


local function retrieve_hmac_fields(authorization_header)
  local hmac_params = {}

  -- parse the header to retrieve hamc parameters
  if authorization_header then
    local iterator, iter_err = re_gmatch(authorization_header,
                                         "\\s*[Hh]mac\\s*username=\"(.+)\"," ..
                                         "\\s*algorithm=\"(.+)\",\\s*header" ..
                                         "s=\"(.+)\",\\s*signature=\"(.+)\"",
                                         "jo")
    if not iterator then
      kong.log.err(iter_err)
      return
    end

    local m, err = iterator()
    if err then
      kong.log.err(err)
      return
    end

    if m and #m >= 4 then
      hmac_params.username = m[1]
      hmac_params.algorithm = m[2]
      hmac_params.hmac_headers = string_split(m[3], " ")
      hmac_params.signature = m[4]
    end
  end

  return hmac_params
end


-- plugin assumes the request parameters being used for creating
-- signature by client are not changed by core or any other plugin
local function create_hash(request_uri, hmac_params)
  local signing_string = ""
  local hmac_headers = hmac_params.hmac_headers

  local count = #hmac_headers
  local ctx = {}
  for i = 1, count do
    local header = hmac_headers[i]
    local header_value = kong.request.get_header(header, ctx)

    if not header_value then
      if header == "@request-target" then
        local request_target = string_lower(kong.request.get_method()) .. " " .. request_uri
        signing_string = signing_string .. header .. ": " .. request_target

      elseif header == "request-line" then
        -- request-line in hmac headers list
        local request_line = fmt("%s %s HTTP/%.01f",
                                 kong_request.get_method(),
                                 request_uri,
                                 assert(kong_request.get_http_version()))
        signing_string = signing_string .. request_line

      else
        signing_string = signing_string .. header .. ":"
      end

    else
      signing_string = signing_string .. header .. ":" .. " " .. header_value
    end

    if i < count then
      signing_string = signing_string .. "\n"
    end
  end

  return hmac[hmac_params.algorithm](hmac_params.secret, signing_string)
end


local function validate_signature(hmac_params)
  local signature_1 = create_hash(kong_request.get_path_with_query(), hmac_params)
  local signature_2 = decode_base64(hmac_params.signature)
  return signature_1 == signature_2
end


local function load_credential_into_memory(username)
  local key, err = kong.db.hmacauth_credentials:select_by_username(username)
  if err then
    return nil, err
  end
  return key
end


local function load_credential(username)
  local credential, err
  if username then
    local credential_cache_key = kong.db.hmacauth_credentials:cache_key(username)
    credential, err = kong.cache:get(credential_cache_key, nil,
                                     load_credential_into_memory,
                                     username)
  end

  if err then
    return error(err)
  end

  return credential
end


local function validate_clock_skew(date_header_name, allowed_clock_skew, ctx)
  local date = kong_request.get_header(date_header_name, ctx)
  if not date then
    return false
  end

  local requestTime = parse_time(date)
  if not requestTime then
    return false
  end

  local skew = abs(time() - requestTime)
  if skew > allowed_clock_skew then
    return false
  end

  return true
end


local function validate_body(ctx)
  local body, err = kong_request.get_raw_body()
  if err then
    kong.log.debug(err)
    return false
  end

  local digest_received = kong_request.get_header(DIGEST, ctx)
  if not digest_received then
    -- if there is no digest and no body, it is ok
    return body == ""
  end

  local digest_created = "SHA-256=" .. sha256_base64(body or '')

  return digest_created == digest_received
end


local function set_consumer(consumer, credential)
  kong_client.authenticate(consumer, credential)

  local set_header = kong_service_request.set_header
  local clear_header = kong_service_request.clear_header

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

  if credential and credential.username then
    set_header(constants.HEADERS.CREDENTIAL_IDENTIFIER, credential.username)
  else
    clear_header(constants.HEADERS.CREDENTIAL_IDENTIFIER)
  end

  if credential then
    clear_header(constants.HEADERS.ANONYMOUS)
  else
    set_header(constants.HEADERS.ANONYMOUS, true)
  end
end

local function unauthorized(message, www_auth_content)
  return { status = 401, message = message, headers = { ["WWW-Authenticate"] = www_auth_content } }
end


local function do_authentication(conf)
  local ctx = {}
  local authorization = kong_request.get_header(AUTHORIZATION, ctx)
  local proxy_authorization = kong_request.get_header(PROXY_AUTHORIZATION, ctx)
  local www_auth_content = conf.realm and fmt('hmac realm="%s"', conf.realm) or 'hmac'

  -- If both headers are missing, return 401
  if not (authorization or proxy_authorization) then
    return false, unauthorized("Unauthorized", www_auth_content)
  end

  -- validate clock skew
  if not (validate_clock_skew(X_DATE, conf.clock_skew, ctx) or
          validate_clock_skew(DATE, conf.clock_skew, ctx)) then
    return false, unauthorized(
      "HMAC signature cannot be verified, a valid date or " ..
      "x-date header is required for HMAC Authentication",
      www_auth_content
    )
  end

  -- retrieve hmac parameter from Proxy-Authorization header
  local hmac_params = retrieve_hmac_fields(proxy_authorization)

  -- Try with the authorization header
  if not hmac_params.username then
    hmac_params = retrieve_hmac_fields(authorization)
    if hmac_params and conf.hide_credentials then
      kong_service_request.clear_header(AUTHORIZATION)
    end

  elseif conf.hide_credentials then
    kong_service_request.clear_header(PROXY_AUTHORIZATION)
  end

  local ok, err = validate_params(hmac_params, conf)
  if not ok then
    kong.log.debug(err)
    return false, unauthorized(SIGNATURE_NOT_VALID, www_auth_content)
  end

  -- validate signature
  local credential = load_credential(hmac_params.username)
  if not credential then
    kong.log.debug("failed to retrieve credential for ", hmac_params.username)
    return false, unauthorized(SIGNATURE_NOT_VALID, www_auth_content)
  end

  hmac_params.secret = credential.secret

  if not validate_signature(hmac_params) then
    return false, unauthorized(SIGNATURE_NOT_SAME, www_auth_content)
  end

  -- If request body validation is enabled, then verify digest.
  if conf.validate_request_body and not validate_body() then
    kong.log.debug("digest validation failed")
    return false, unauthorized(SIGNATURE_NOT_SAME, www_auth_content)
  end

  -- Retrieve consumer
  local consumer_cache_key, consumer
  consumer_cache_key = kong.db.consumers:cache_key(credential.consumer.id)
  consumer, err      = kong.cache:get(consumer_cache_key, nil,
                                      kong_client.load_consumer,
                                      credential.consumer.id)
  if err then
    return error(err)
  end

  set_consumer(consumer, credential)

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

  if not consumer then
    local err_msg = "anonymous consumer " .. anonymous .. " is configured but doesn't exist"
    kong.log.err(err_msg)
    return kong.response.error(500, err_msg)
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
    return kong.response.error(err.status, err.message, err.headers)
  end
end


local _M = {}

function _M.execute(conf)

  if conf.anonymous then
    return logical_OR_authentication(conf)
  else
    return logical_AND_authentication(conf)
  end
end


return _M
