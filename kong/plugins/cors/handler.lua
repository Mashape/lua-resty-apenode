local lrucache   = require "resty.lrucache"
local url        = require "socket.url"
local kong_meta = require "kong.meta"


local kong     = kong
local re_find  = ngx.re.find
local find     = string.find
local concat   = table.concat
local tostring = tostring
local ipairs   = ipairs


local HTTP_OK = 200


local CorsHandler = {}


CorsHandler.PRIORITY = 2000
CorsHandler.VERSION = kong_meta.version


-- per-plugin cache of normalized origins for runtime comparison
local mt_cache = { __mode = "k" }
local config_cache = setmetatable({}, mt_cache)


-- per-worker cache of parsed requests origins with 1000 slots
local normalized_req_domains = lrucache.new(10e3)


local function normalize_origin(domain)
  local parsed_obj = assert(url.parse(domain))
  if not parsed_obj.host then
    return {
      domain = domain,
      host = domain,
    }
  end

  local port = parsed_obj.port
  if (parsed_obj.scheme == "http" and port == "80")
     or (parsed_obj.scheme == "https" and port == "443") then
    port = nil
  end

  return {
    domain = (parsed_obj.scheme and parsed_obj.scheme .. "://" or "") ..
              parsed_obj.host ..
              (port and ":" .. port or ""),
    host = parsed_obj.host,
  }
end

local function add_vary_header(header_filter)
  if header_filter then
    kong.response.add_header("vary", "Origin")
  else
    kong.response.set_header("vary", "Origin")
  end
end

local function configure_origin(conf, header_filter, ctx)
  local n_origins = conf.origins ~= nil and #conf.origins or 0
  local set_header = kong.response.set_header

  if n_origins == 0 or (n_origins == 1 and conf.origins[1] == "*") then
    set_header("Access-Control-Allow-Origin", "*")
    return true
  end

  -- always set Vary header (it can be used for calculating cache key)
  -- https://github.com/rs/cors/issues/10
  add_vary_header(header_filter)

  if n_origins == 1 then
    -- if this doesnt look like a regex, set the ACAO header directly
    -- otherwise, we'll fall through to an iterative search and
    -- set the ACAO header based on the client Origin
    local from, _, err = re_find(conf.origins[1], "^[A-Za-z0-9.:/-]+$", "jo")
    if err then
      kong.log.err("could not inspect origin for type: ", err)
    end

    if from then
      set_header("Access-Control-Allow-Origin", conf.origins[1])
      return false
    end
  end

  local req_origin = kong.request.get_header("origin", ctx)
  if req_origin then
    local cached_domains = config_cache[conf]
    if not cached_domains then
      cached_domains = {}

      for _, entry in ipairs(conf.origins) do
        if entry == "*" then
          set_header("Access-Control-Allow-Origin", "*")
          return true
        end

        local domain
        local maybe_regex, _, err = re_find(entry, "[^A-Za-z0-9.:/-]", "jo")
        if err then
          kong.log.err("could not inspect origin for type: ", err)
        end

        if maybe_regex then
          -- Kong 0.x did not anchor regexes:
          -- Perform adjustments to support regexes
          -- explicitly anchored by the user.
          if entry:sub(-1) ~= "$" then
            entry = entry .. "$"
          end

          if entry:sub(1, 1) == "^" then
            entry = entry:sub(2)
          end

          domain = { regex = entry }

        else
          domain = normalize_origin(entry)
        end

        domain.by_host = not find(entry, ":", 1, true)
        table.insert(cached_domains, domain)
      end

      config_cache[conf] = cached_domains
    end

    local normalized_req_origin = normalized_req_domains:get(req_origin)
    if not normalized_req_origin then
      normalized_req_origin = normalize_origin(req_origin)
      normalized_req_domains:set(req_origin, normalized_req_origin)
    end

    for _, cached_domain in ipairs(cached_domains) do
      local found, _, err

      if cached_domain.regex then
        local subject = cached_domain.by_host
                      and normalized_req_origin.host
                      or  normalized_req_origin.domain

        found, _, err = re_find(subject, cached_domain.regex, "ajo")
        if err then
          kong.log.err("could not search for domain: ", err)
        end

      else
        found = (normalized_req_origin.domain == cached_domain.domain)
      end

      if found then
        set_header("Access-Control-Allow-Origin", normalized_req_origin.domain)
        return false
      end
    end
  end

  kong.response.clear_header("Access-Control-Allow-Origin")
  return false
end


local function configure_credentials(conf, allow_all, header_filter, ctx)
  local set_header = kong.response.set_header

  if not conf.credentials then
    return
  end

  if not allow_all then
    set_header("Access-Control-Allow-Credentials", true)
    return
  end

  -- Access-Control-Allow-Origin is '*', must change it because ACAC cannot
  -- be 'true' if ACAO is '*'.
  local req_origin = kong.request.get_header("origin", ctx)
  if req_origin then
    add_vary_header(header_filter)
    set_header("Access-Control-Allow-Origin", req_origin)
    set_header("Access-Control-Allow-Credentials", true)
  end
end


function CorsHandler:access(conf)
  local ctx = {}
  if kong.request.get_method() ~= "OPTIONS"
     or not kong.request.get_header("Origin", ctx)
     or not kong.request.get_header("Access-Control-Request-Method", ctx)
  then
    return
  end

  -- don't add any response header because we are delegating the preflight to
  -- the upstream API (conf.preflight_continue=true), or because we already
  -- added them all
  kong.ctx.plugin.skip_response_headers = true

  if conf.preflight_continue then
    return
  end

  local allow_all = configure_origin(conf, false, ctx)
  configure_credentials(conf, allow_all, false, ctx)

  local set_header = kong.response.set_header

  if conf.headers and #conf.headers > 0 then
    set_header("Access-Control-Allow-Headers", concat(conf.headers, ","))

  else
    local acrh = kong.request.get_header("Access-Control-Request-Headers", ctx)
    if acrh then
      set_header("Access-Control-Allow-Headers", acrh)
    else
      kong.response.clear_header("Access-Control-Allow-Headers")
    end
  end

  local methods = conf.methods and concat(conf.methods, ",")
                  or "GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS,TRACE,CONNECT"

  set_header("Access-Control-Allow-Methods", methods)

  if conf.max_age then
    set_header("Access-Control-Max-Age", tostring(conf.max_age))
  end

  if conf.private_network and
    kong.request.get_header("Access-Control-Request-Private-Network", ctx) == 'true' then
      set_header("Access-Control-Allow-Private-Network", 'true')
  end

  return kong.response.exit(HTTP_OK)
end


function CorsHandler:header_filter(conf)
  if kong.ctx.plugin.skip_response_headers then
    return
  end

  local ctx = {}
  local allow_all = configure_origin(conf, true, ctx)
  configure_credentials(conf, allow_all, true, ctx)

  if conf.exposed_headers and #conf.exposed_headers > 0 then
    kong.response.set_header("Access-Control-Expose-Headers",
                             concat(conf.exposed_headers, ","))
  end
end


return CorsHandler
