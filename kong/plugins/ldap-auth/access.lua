local constants = require "kong.constants"
local ldap = require "kong.plugins.ldap-auth.ldap"


local kong = kong
local error = error
local decode_base64 = ngx.decode_base64
local tostring =  tostring
local re_find = ngx.re.find
local re_match = ngx.re.match
local lower = string.lower
local upper = string.upper
local sub = string.sub
local fmt = string.format
local tcp = ngx.socket.tcp
local sha256_hex = require("kong.tools.sha256").sha256_hex


local AUTHORIZATION = "authorization"
local PROXY_AUTHORIZATION = "proxy-authorization"


local _M = {}


local function retrieve_credentials(authorization_header_value, conf)
  local lower_header_type = lower(conf.header_type)
  local regex = "^\\s*" .. lower_header_type .. "\\s+"
  local from, to, err = re_find(lower(authorization_header_value), regex, "jo")
  if err then
    kong.log.err("error while find header_type: ", lower_header_type, " in authorization header value")
    return nil
  end

  if not from then
    kong.log.info("header_type: ", lower_header_type, " not found in authorization header value")
    return nil
  end

  local username, password
  if from == 1 then
    local cred = sub(authorization_header_value, to + 1)
    local decoded_cred = decode_base64(cred)
    local m, err = re_match(decoded_cred, "^(.*?):(.+)$", "jo")
    if err then
      kong.log.err("error while decoding credentials: ", err)
      return nil
    end

    if type(m) == "table" and #m == 2 then
      username = m[1]
      password = m[2]
    else
      kong.log.err("no valid credentials found in authorization header value")
      return nil
    end

  end

  return username, password
end


local function ldap_authenticate(given_username, given_password, conf)
  local is_authenticated
  local err, suppressed_err, ok, _

  local sock = tcp()

  sock:settimeout(conf.timeout)

  local opts

  -- keep TLS connections in a separate pool to avoid reusing non-secure
  -- connections and vice-versa, because STARTTLS use the same port
  if conf.start_tls then
    opts = {
      pool = conf.ldap_host .. ":" .. conf.ldap_port .. ":starttls"
    }
  end

  ok, err = sock:connect(conf.ldap_host, conf.ldap_port, opts)
  if not ok then
    kong.log.err("failed to connect to ", conf.ldap_host, ":",
                   tostring(conf.ldap_port), ": ", err)
    return nil, err
  end

  if conf.start_tls then
    -- convert connection to a STARTTLS connection only if it is a new connection
    local count, err = sock:getreusedtimes()
    if not count then
      -- connection was closed, just return instead
      return nil, err
    end

    if count == 0 then
      local ok, err = ldap.start_tls(sock)
      if not ok then
        return nil, err
      end
    end
  end

  if conf.start_tls or conf.ldaps then
    _, err = sock:sslhandshake(true, conf.ldap_host, conf.verify_ldap_host)
    if err ~= nil then
      return false, fmt("failed to do SSL handshake with %s:%s: %s",
                        conf.ldap_host, tostring(conf.ldap_port), err)
    end
  end

  local who = conf.attribute .. "=" .. given_username .. "," .. conf.base_dn
  is_authenticated, err = ldap.bind_request(sock, who, given_password)

  ok, suppressed_err = sock:setkeepalive(conf.keepalive)
  if not ok then
    kong.log.err("failed to keepalive to ", conf.ldap_host, ":",
                   tostring(conf.ldap_port), ": ", suppressed_err)
  end

  return is_authenticated, err
end


local function cache_key(conf, username, password)
  local hash, err = sha256_hex(fmt("%s:%u:%s:%s:%u:%s:%s",
                                   lower(conf.ldap_host),
                                   conf.ldap_port,
                                   conf.base_dn,
                                   conf.attribute,
                                   conf.cache_ttl,
                                   username,
                                   password))

  if err then
    return nil, err
  end

  return "ldap_auth_cache:" .. hash
end


local function load_credential(given_username, given_password, conf)
  local ok, err = ldap_authenticate(given_username, given_password, conf)
  if err ~= nil then
    kong.log.err(err)
  end

  if ok == nil then
    return nil
  end

  if ok == false then
    return false
  end

  local key
  key, err = cache_key(conf, given_username, given_password)
  if err then
    return nil, err
  end

  return {
    id = key,
    username = given_username,
    password = given_password,
  }
end


local function authenticate(conf, given_credentials)
  local given_username, given_password = retrieve_credentials(given_credentials, conf)
  if given_username == nil then
    return false
  end

  local key, err = cache_key(conf, given_username, given_password)
  if err then
    return error(err)
  end

  local credential
  credential, err = kong.cache:get(key, {
    ttl = conf.cache_ttl,
    neg_ttl = conf.cache_ttl
  }, load_credential, given_username, given_password, conf)

  if err or credential == nil then
    return error(err)
  end


  return credential and credential.password == given_password, credential
end


local function set_consumer(consumer, credential)
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

local function unauthorized(message, authorization_scheme)
  return {
    status = 401,
    message = message,
    headers = { ["WWW-Authenticate"] = authorization_scheme }
  }
end

local function do_authentication(conf)
  local ctx = {}
  local authorization_value = kong.request.get_header(AUTHORIZATION, ctx)
  local proxy_authorization_value = kong.request.get_header(PROXY_AUTHORIZATION, ctx)

  local scheme = conf.header_type
  if scheme == "ldap" then
    -- ensure backwards compatibility (see GH PR #3656)
    -- TODO: provide migration to capitalize older configurations
    scheme = upper(scheme)
  end

  local www_auth_content = conf.realm and fmt('%s realm="%s"', scheme, conf.realm) or scheme
  -- If both headers are missing, return 401
  if not (authorization_value or proxy_authorization_value) then
    return false, unauthorized("Unauthorized", www_auth_content)
  end

  local is_authorized, credential
  if proxy_authorization_value then
    is_authorized, credential = authenticate(conf, proxy_authorization_value)
  end

  if not is_authorized and authorization_value then
    is_authorized, credential = authenticate(conf, authorization_value)
  end

  if not is_authorized then
    return false, unauthorized("Unauthorized", www_auth_content)
  end

  if conf.hide_credentials then
    kong.service.request.clear_header(AUTHORIZATION)
    kong.service.request.clear_header(PROXY_AUTHORIZATION)
  end

  set_consumer(nil, credential)

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


function _M.execute(conf)
  if conf.anonymous then
    return logical_OR_authentication(conf)
  else
    return logical_AND_authentication(conf)
  end
end


return _M
