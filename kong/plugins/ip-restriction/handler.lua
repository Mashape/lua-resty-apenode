local cjson = require "cjson.safe"
local lrucache = require "resty.lrucache"
local ipmatcher = require "resty.ipmatcher"
local kong_meta = require "kong.meta"


local cjson_encode = cjson.encode
local error = error
local kong = kong
local ngx_exit = ngx.exit
local ngx_var = ngx.var
local ngx_req = ngx.req


local IPMATCHER_COUNT = 512
local IPMATCHER_TTL   = 3600
local cache = lrucache.new(IPMATCHER_COUNT)


local IpRestrictionHandler = {
  PRIORITY = 990,
  VERSION = kong_meta.version,
}


local isempty
do
  local tb_isempty = require "table.isempty"

  isempty = function(t)
    return t == nil or tb_isempty(t)
  end
end


local is_http_subsystem = ngx.config.subsystem == "http"


local do_exit
if is_http_subsystem then
  do_exit = function(status, message)
    return kong.response.error(status, message)
  end

else
  do_exit = function(status, message)
    local tcpsock, err = ngx_req.socket(true)
    if err then
      error(err)
    end

    tcpsock:send(cjson_encode({
      message = message
    }))

    return ngx_exit(status)
  end
end

local function match_bin(list, binary_remote_addr)
  local matcher, err

  matcher = cache:get(list)
  if not matcher then
    matcher, err = ipmatcher.new(list)
    if err then
      return error("failed to create a new ipmatcher instance: " .. err)
    end

    cache:set(list, matcher, IPMATCHER_TTL)
  end

  local is_match
  is_match, err = matcher:match_bin(binary_remote_addr)
  if err then
    return error("invalid binary ip address: " .. err)
  end

  return is_match
end


local function do_restrict(conf)
  local binary_remote_addr = ngx_var.binary_remote_addr
  if not binary_remote_addr then
    local status = 403
    local message = "Cannot identify the client IP address, unix domain sockets are not supported."

    return do_exit(status, message)
  end

  local deny = conf.deny
  local allow = conf.allow
  local status = conf.status or 403
  local default_message = string.format("IP address not allowed: %s", ngx_var.remote_addr)
  local message = conf.message or default_message

  if not isempty(deny) then
    local blocked = match_bin(deny, binary_remote_addr)
    if blocked then
      return do_exit(status, message)
    end
  end

  if not isempty(allow) then
    local allowed = match_bin(allow, binary_remote_addr)
    if not allowed then
      return do_exit(status, message)
    end
  end
end


function IpRestrictionHandler:access(conf)
  return do_restrict(conf)
end


function IpRestrictionHandler:preread(conf)
  return do_restrict(conf)
end


return IpRestrictionHandler
