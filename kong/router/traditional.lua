local ipmatcher     = require "resty.ipmatcher"
local lrucache      = require "resty.lrucache"
local isempty       = require "table.isempty"
local clone         = require "table.clone"
local clear         = require "table.clear"
local bit           = require "bit"
local utils         = require "kong.router.utils"


local setmetatable  = setmetatable
local is_http       = ngx.config.subsystem == "http"
local get_method    = ngx.req.get_method
local get_headers   = ngx.req.get_headers
local re_match      = ngx.re.match
local re_find       = ngx.re.find
local header        = ngx.header
local var           = ngx.var
local ngx_log       = ngx.log
local ngx_ERR       = ngx.ERR
local worker_id     = ngx.worker.id
local concat        = table.concat
local sort          = table.sort
local byte          = string.byte
local upper         = string.upper
local lower         = string.lower
local find          = string.find
local format        = string.format
local sub           = string.sub
local tonumber      = tonumber
local pairs         = pairs
local ipairs        = ipairs
local error         = error
local type          = type
local max           = math.max
local band          = bit.band
local bor           = bit.bor
local yield         = require("kong.tools.yield").yield
local server_name   = require("ngx.ssl").server_name


local sanitize_uri_postfix = utils.sanitize_uri_postfix
local check_select_params  = utils.check_select_params
local strip_uri_args       = utils.strip_uri_args
local get_service_info     = utils.get_service_info
local add_debug_headers    = utils.add_debug_headers
local get_upstream_uri_v0  = utils.get_upstream_uri_v0
local route_match_stat     = utils.route_match_stat


-- limits regex degenerate times to the low miliseconds
local REGEX_PREFIX  = "(*LIMIT_MATCH=10000)"
local SLASH         = byte("/")
local DOT           = byte(".")

local ERR           = ngx.ERR
local WARN          = ngx.WARN


local APPENDED = {}


local function append(destination, value)
  local n = destination[0] + 1
  destination[0] = n
  destination[n] = value
end


local log
do
  log = function(lvl, ...)
    ngx_log(lvl, "[router] ", ...)
  end
end


local get_header
if is_http then
  get_header = require("kong.tools.http").get_header
end


local split_port
do
  local ZERO, NINE, LEFTBRACKET, RIGHTBRACKET = ("09[]"):byte(1, -1)


  local function safe_add_port(host, port)
    if not port then
      return host
    end

    return host .. ":" .. port
  end


  local function onlydigits(s, begin)
    for i = begin or 1, #s do
      local c = byte(s, i)
      if c < ZERO or c > NINE then
        return false
      end
    end
    return true
  end


  --- Splits an optional ':port' section from a hostname
  -- the port section must be decimal digits only.
  -- brackets ('[]') are peeled off the hostname if present.
  -- if there's more than one colon and no brackets, no split is possible.
  -- on non-parseable input, returns name unchanged,
  -- every string input produces at least one string output.
  -- @tparam string name the string to split.
  -- @tparam number default_port default port number
  -- @treturn string hostname without port
  -- @treturn string hostname with port
  -- @treturn boolean true if input had a port number
  local function l_split_port(name, default_port)
    if byte(name, 1) == LEFTBRACKET then
      if byte(name, -1) == RIGHTBRACKET then
        return sub(name, 2, -2), safe_add_port(name, default_port), false
      end

      local splitpos = find(name, "]:", 2, true)
      if splitpos then
        if splitpos == #name - 1 then
          return sub(name, 2, splitpos - 1), name .. (default_port or ""), false
        end

        if onlydigits(name, splitpos + 2) then
          return sub(name, 2, splitpos - 1), name, true
        end
      end

      return name, safe_add_port(name, default_port), false
    end

    local firstcolon = find(name, ":", 1, true)
    if not firstcolon then
      return name, safe_add_port(name, default_port), false
    end

    if firstcolon == #name then
      local host = sub(name, 1, firstcolon - 1)
      return host, safe_add_port(host, default_port), false
    end

    if not onlydigits(name, firstcolon + 1) then
      if default_port then
        return name, format("[%s]:%s", name, default_port), false
      end

      return name, name, false
    end

    return sub(name, 1, firstcolon - 1), name, true
  end


  -- split_port is a pure function, so we can memoize it.
  local memo_h = setmetatable({}, { __mode = "k" })
  local memo_hp = setmetatable({}, { __mode = "k" })
  local memo_p = setmetatable({}, { __mode = "k" })


  split_port = function(name, default_port)
    local k = name .. "#" .. (default_port or "")
    local h, hp, p = memo_h[k], memo_hp[k], memo_p[k]
    if not h then
      h, hp, p = l_split_port(name, default_port)
      memo_h[k], memo_hp[k], memo_p[k] = h, hp, p
    end

    return h, hp, p
  end
end


local DEFAULT_MATCH_LRUCACHE_SIZE = utils.DEFAULT_MATCH_LRUCACHE_SIZE


local MATCH_RULES = {
  HOST            = 0x00000040,
  HEADER          = 0x00000020,
  URI             = 0x00000010,
  METHOD          = 0x00000008,
  SNI             = 0x00000004,
  SRC             = 0x00000002,
  DST             = 0x00000001,
}


local SORTED_MATCH_RULES = is_http and {
  MATCH_RULES.HOST,
  MATCH_RULES.HEADER,
  MATCH_RULES.URI,
  MATCH_RULES.METHOD,
  MATCH_RULES.SNI,
  [0] = 5,
} or {
  MATCH_RULES.SNI,
  MATCH_RULES.SRC,
  MATCH_RULES.DST,
  [0] = 3,
}


local MATCH_SUBRULES = {
  HAS_REGEX_URI          = 0x01,
  PLAIN_HOSTS_ONLY       = 0x02,
  HAS_WILDCARD_HOST_PORT = 0x04,
}


local EMPTY_T = require("kong.tools.table").EMPTY


local match_route
local reduce
local lua_regex_cache_max_entries


local function _set_ngx(mock_ngx)
  if type(mock_ngx) ~= "table" then
    return
  end

  if mock_ngx.header then
    header = mock_ngx.header
  end

  if mock_ngx.var then
    var = mock_ngx.var
  end

  if mock_ngx.log then
    ngx_log = mock_ngx.log
  end

  if mock_ngx.ERR then
    ERR = mock_ngx.ERR
  end

  if type(mock_ngx.req) == "table" then
    if mock_ngx.req.get_method then
      get_method = mock_ngx.req.get_method
    end

    if mock_ngx.req.get_headers then
      get_headers = mock_ngx.req.get_headers
    end
  end

  if type(mock_ngx.config) == "table" then
    if mock_ngx.config.subsystem then
      is_http = mock_ngx.config.subsystem == "http"
    end
  end

  if type(mock_ngx.re) == "table" then
    if mock_ngx.re.match then
      re_match = mock_ngx.re.match
    end

    if mock_ngx.re.find then
      re_find = mock_ngx.re.find
    end
  end

  get_header = function(key)
    local mock_headers = mock_ngx.headers or {}
    local mock_var = mock_ngx.var or {}
    return mock_headers[key] or mock_var["http_" .. key]
  end
end


local function create_range_f(ip)
  if ip and find(ip, "/", nil, true) then
    local matcher = ipmatcher.new({ ip })
    return function(ip) return matcher:match(ip) end
  end
end


local function marshall_route(r)
  local route        = r.route
  local hosts        = route.hosts
  local headers      = route.headers
  local paths        = route.paths
  local methods      = route.methods
  local snis         = route.snis
  local sources      = route.sources
  local destinations = route.destinations

  if not (hosts or headers or methods or paths or snis or sources or destinations)
  then
    return nil, "could not categorize route"
  end

  local match_rules     = 0x00
  local match_weight    = 0
  local submatch_weight = 0
  local max_uri_length  = 0
  local hosts_t         = { [0] = 0 }
  local headers_t       = { [0] = 0 }
  local uris_t          = { [0] = 0 }
  local methods_t       = {}
  local sources_t       = { [0] = 0 }
  local destinations_t  = { [0] = 0 }
  local snis_t          = {}


  -- hosts


  if hosts then
    if type(hosts) ~= "table" then
      return nil, "hosts field must be a table"
    end

    local has_host_wildcard
    local has_host_plain
    local has_wildcard_host_port

    for i = 1, #hosts do
      local host = hosts[i]
      if type(host) ~= "string" then
        return nil, "hosts values must be strings"
      end

      if find(host, "*", nil, true) then
        -- wildcard host matching
        has_host_wildcard = true

        local wildcard_host_regex = host:gsub("%.", "\\.")
                                        :gsub("%*", ".+") .. "$"

        local _, _, has_port = split_port(host)
        if not has_port then
          wildcard_host_regex = wildcard_host_regex:gsub("%$$", [[(?::\d+)?$]])
        end

        if has_wildcard_host_port == nil and has_port then
          has_wildcard_host_port = true
        end

        append(hosts_t, {
          wildcard = true,
          value    = host,
          regex    = wildcard_host_regex,
        })

      else
        -- plain host matching
        has_host_plain = true
        append(hosts_t, { value = lower(host) })
        hosts_t[lower(host)] = host
      end
    end

    if has_host_plain or has_host_wildcard then
      match_rules = bor(match_rules, MATCH_RULES.HOST)
      match_weight = match_weight + 1
    end

    if not has_host_wildcard then
      submatch_weight = bor(submatch_weight, MATCH_SUBRULES.PLAIN_HOSTS_ONLY)
    end

    if has_wildcard_host_port then
      submatch_weight = bor(submatch_weight, MATCH_SUBRULES.HAS_WILDCARD_HOST_PORT)
    end
  end


  -- headers


  if headers then
    if type(headers) ~= "table" then
      return nil, "headers field must be a table"
    end

    for header_name, header_values in pairs(headers) do
      if type(header_values) ~= "table" then
        return nil, "header values must be a table for header '" ..
                    header_name .. "'"
      end

      header_name = lower(header_name)

      if header_name ~= "host" then
        local header_values_map = {}
        local header_values_count = #header_values
        for i = 1, header_values_count do
          header_values_map[lower(header_values[i])] = true
        end
        local header_pattern
        if header_values_count == 1 then
          local first_header = header_values[1]
          if sub(first_header, 1, 2) == "~*" then
            header_pattern = sub(first_header, 3)
          end
        end

        append(headers_t, {
          name = header_name,
          values_map = header_values_map,
          header_pattern = header_pattern,
        })
      end
    end

    if headers_t[0] > 0 then
      match_rules = bor(match_rules, MATCH_RULES.HEADER)
      match_weight = match_weight + 1
    end
  end


  -- paths


  if paths then
    if type(paths) ~= "table" then
      return nil, "paths field must be a table"
    end

    local count = #paths
    if count > 0 then
      match_rules = bor(match_rules, MATCH_RULES.URI)
      match_weight = match_weight + 1
      for i = 1, count do
        local path = paths[i]
        local is_regex = sub(path, 1, 1) == "~"

        if not is_regex then
          -- plain URI or URI prefix

          local uri_t = {
            is_prefix = true,
            value     = path,
          }

          append(uris_t, uri_t)
          uris_t[path] = uri_t
          max_uri_length = max(max_uri_length, #path)

        else

          path = sub(path, 2)
          -- regex URI
          local strip_regex  = REGEX_PREFIX .. path .. [[(?<uri_postfix>.*)]]

          local uri_t    = {
            is_regex     = true,
            value        = path,
            regex        = path,
            strip_regex  = strip_regex,
          }

          append(uris_t, uri_t)
          uris_t[path] = uri_t
          submatch_weight = bor(submatch_weight, MATCH_SUBRULES.HAS_REGEX_URI)
        end
      end
    end
  end


  -- methods


  if methods then
    if type(methods) ~= "table" then
      return nil, "methods field must be a table"
    end

    local count = #methods
    if count > 0 then
      match_rules = bor(match_rules, MATCH_RULES.METHOD)
      match_weight = match_weight + 1

      for i = 1, count do
        methods_t[upper(methods[i])] = true
      end
    end
  end


  -- snis

  if snis then
    if type(snis) ~= "table" then
      return nil, "snis field must be a table"
    end

    local count = #snis
    if count > 0 then
      match_rules = bor(match_rules, MATCH_RULES.SNI)
      match_weight = match_weight + 1

      for i = 1, count do
        local sni = snis[i]
        if type(sni) ~= "string" then
          return nil, "sni elements must be strings"
        end

        if #sni > 1 and byte(sni, -1) == DOT then
          -- last dot in FQDNs must not be used for routing
          sni = sub(sni, 1, -2)
        end

        snis_t[sni] = sni
      end
    end
  end


  -- sources


  if sources then
    if type(sources) ~= "table" then
      return nil, "sources field must be a table"
    end

    local count = #sources
    if count > 0 then
      match_rules = bor(match_rules, MATCH_RULES.SRC)
      match_weight = match_weight + 1

      for i = 1, count do
        local source = sources[i]
        if type(source) ~= "table" then
          return nil, "sources elements must be tables"
        end

        append(sources_t, {
          ip = source.ip,
          port = source.port,
          range_f = create_range_f(source.ip),
        })
      end
    end
  end


  -- destinations


  if destinations then
    if type(destinations) ~= "table" then
      return nil, "destinations field must be a table"
    end

    local count = #destinations
    if count > 0 then
      match_rules = bor(match_rules, MATCH_RULES.DST)
      match_weight = match_weight + 1

      for i = 1, count do
        local destination = destinations[i]
        if type(destination) ~= "table" then
          return nil, "destinations elements must be tables"
        end

        append(destinations_t, {
          ip = destination.ip,
          port = destination.port,
          range_f = create_range_f(destination.ip),
        })
      end
    end
  end


  -- upstream_url parsing


  local service = r.service

  local service_protocol, service_type,
        service_host, service_port,
        service_hostname_type, service_path = get_service_info(service)


  return {
    type            = service_type,
    route           = route,
    service         = service,
    strip_uri       = route.strip_path    == true,
    preserve_host   = route.preserve_host == true,
    match_rules     = match_rules,
    match_weight    = match_weight,
    submatch_weight = submatch_weight,
    max_uri_length  = max_uri_length,
    hosts           = hosts_t,
    headers         = headers_t,
    uris            = uris_t,
    methods         = methods_t,
    sources         = sources_t,
    destinations    = destinations_t,
    snis            = snis_t,
    upstream_url_t  = {
      scheme = service_protocol,
      type = service_hostname_type,
      host = service_host,
      port = service_port,
      path = service_path,
    },
  }
end


local function index_src_dst(source, indexes, funcs)
  for i = 1, source[0] do
    local src_dst_t = source[i]
    if src_dst_t.ip then
      indexes[src_dst_t.ip] = true

      if src_dst_t.range_f then
        append(funcs, src_dst_t.range_f)
      end
    end

    if src_dst_t.port then
      indexes[src_dst_t.port] = true
    end
  end
end


local function index_route_t(route_t, plain_indexes, prefix_uris, regex_uris,
                             wildcard_hosts, src_trust_funcs, dst_trust_funcs)
  for i = 1, route_t.hosts[0] do
    local host_t = route_t.hosts[i]
    if host_t.wildcard then
      append(wildcard_hosts, host_t)

    else
      plain_indexes.hosts[host_t.value] = true
    end
  end

  local headers = plain_indexes.headers
  for i = 1, route_t.headers[0] do
    local header_t = route_t.headers[i]
    if not headers[header_t.name] then
      headers[header_t.name] = true
      append(headers, header_t.name)
    end
  end

  for i = 1, route_t.uris[0] do
    local uri_t = route_t.uris[i]
    if uri_t.is_prefix then
      plain_indexes.uris[uri_t.value] = true
      append(prefix_uris, uri_t)

    else
      append(regex_uris, uri_t)
    end
  end

  for method in pairs(route_t.methods) do
    plain_indexes.methods[method] = true
  end

  for sni in pairs(route_t.snis) do
    plain_indexes.snis[sni] = true
  end

  index_src_dst(route_t.sources, plain_indexes.sources, src_trust_funcs)
  index_src_dst(route_t.destinations, plain_indexes.destinations, dst_trust_funcs)
end


local function sort_routes(r1, r2)
  if r1.submatch_weight ~= r2.submatch_weight then
    return r1.submatch_weight > r2.submatch_weight
  end

  if r1.headers[0] ~= r2.headers[0] then
    return r1.headers[0] > r2.headers[0]
  end

  -- only regex path use regex_priority
  if band(r1.submatch_weight, MATCH_SUBRULES.HAS_REGEX_URI) ~= 0 then
    do
      local rp1 = r1.route.regex_priority or 0
      local rp2 = r2.route.regex_priority or 0

      if rp1 ~= rp2 then
        return rp1 > rp2
      end
    end
  end

  if r1.max_uri_length ~= r2.max_uri_length then
    return r1.max_uri_length > r2.max_uri_length
  end

  if r1.route.created_at ~= nil and r2.route.created_at ~= nil then
    return r1.route.created_at < r2.route.created_at
  end
end


local function sort_categories(c1, c2)
  if c1.match_weight ~= c2.match_weight then
    return c1.match_weight > c2.match_weight
  end

  return c1.category_bit > c2.category_bit
end


local function sort_uris(p1, p2)
  return #p1.value > #p2.value
end


local function sort_sources(r1, r2)
  local sources_r1 = r1.sources
  local sources_r2 = r2.sources

  if sources_r1 == sources_r2 then
    return false
  end

  local ip_port_r1 = 0
  for i = 1, sources_r1[0] do
    if sources_r1[i].ip and sources_r1[i].port then
      ip_port_r1 = 1
      break
    end
  end

  local ip_port_r2 = 0
  for i = 1, sources_r2[0] do
    if sources_r2[i].ip and sources_r2[i].port then
      ip_port_r2 = 1
      break
    end
  end

  return ip_port_r1 > ip_port_r2
end


local function sort_destinations(r1, r2)
  local destinations_r1 = r1.destinations
  local destinations_r2 = r2.destinations

  if destinations_r1 == destinations_r2 then
    return false
  end

  local ip_port_r1 = 0
  for i = 1, destinations_r1[0] do
    if destinations_r1[i].ip and destinations_r1[i].port then
      ip_port_r1 = 1
      break
    end
  end

  local ip_port_r2 = 0
  for i = 1, destinations_r2[0] do
    if destinations_r2[i].ip and destinations_r2[i].port then
      ip_port_r2 = 1
      break
    end
  end

  return ip_port_r1 > ip_port_r2
end


local function sort_src_dst(source, func)
  if not isempty(source) then
    for _, routes in pairs(source) do
      sort(routes, func)
    end
  end
end


local function categorize_hosts_headers_uris(route_t, source, category, key)
  for i = 1, source[0] do
    local value = source[i][key or "value"]
    if category[value] then
      append(category[value], route_t)

    else
      category[value] = { [0] = 1, route_t }
    end
  end
end


local function categorize_methods_snis(route_t, source, category)
  for key in pairs(source) do
    if category[key] then
      append(category[key], route_t)
    else
      category[key] = { [0] = 1, route_t }
    end
  end
end


local function categorize_src_dst(route_t, source, category)
  if source[0] == 0 then
    return
  end

  for i = 1, source[0] do
    local src_dst_t = source[i]
    local ip = src_dst_t.ip
    if ip then
      if not category[ip] then
        category[ip] = { [0] = 0 }
      end

      if not APPENDED[ip] then
        append(category[ip], route_t)
        APPENDED[ip] = true
      end
    end

    local port = src_dst_t.port
    if port then
      if not category[port] then
        category[port] = { [0] = 0 }
      end

      if not APPENDED[port] then
        append(category[port], route_t)
        APPENDED[port] = true
      end
    end
  end

  clear(APPENDED)
end


local function categorize_route_t(route_t, bit_category, categories)
  local category = categories[bit_category]
  if not category then
    category                 = {
      match_weight           = route_t.match_weight,
      routes_by_hosts        = {},
      routes_by_headers      = {},
      routes_by_uris         = {},
      routes_by_methods      = {},
      routes_by_sources      = {},
      routes_by_destinations = {},
      routes_by_sni          = {},
      all                    = { [0] = 0 },
    }

    categories[bit_category] = category
  end

  append(category.all, route_t)
  categorize_hosts_headers_uris(route_t, route_t.hosts, category.routes_by_hosts)
  categorize_hosts_headers_uris(route_t, route_t.headers, category.routes_by_headers, "name")
  categorize_hosts_headers_uris(route_t, route_t.uris, category.routes_by_uris)
  categorize_methods_snis(route_t, route_t.methods, category.routes_by_methods)
  categorize_methods_snis(route_t, route_t.snis, category.routes_by_sni)
  categorize_src_dst(route_t, route_t.sources, category.routes_by_sources)
  categorize_src_dst(route_t, route_t.destinations, category.routes_by_destinations)
end


local function matcher_src_dst(source, ctx, ip_name, port_name)
  for i = 1, source[0] do
    local src_dst_t = source[i]
    local ip_ok
    if not src_dst_t.ip then
      ip_ok = true
    elseif src_dst_t.range_f then
      ip_ok = src_dst_t.range_f(ctx[ip_name])
    else
      ip_ok = src_dst_t.ip == ctx[ip_name]
    end

    if ip_ok then
      if not src_dst_t.port or (src_dst_t.port == ctx[port_name]) then
        ctx.matches[ip_name] = src_dst_t.ip
        ctx.matches[port_name] = src_dst_t.port
        return true
      end
    end
  end
end


local function match_regex_uri(uri_t, req_uri, matches)
  local m, err = re_match(req_uri, uri_t.strip_regex, "ajo")
  if err then
    return nil, err
  end

  if not m then
    return
  end

  local uri_postfix = m.uri_postfix
  if uri_postfix then
    matches.uri_prefix = sub(req_uri, 1, -(#uri_postfix + 1))

    -- remove the uri_postfix group
    m[#m] = nil
    m.uri_postfix = nil

    uri_postfix = sanitize_uri_postfix(uri_postfix)
  end

  matches.uri = uri_t.value
  matches.uri_postfix = uri_postfix

  if m[1] ~= nil then
    matches.uri_captures = m
  end

  return true
end


do
  local matchers = {
    [MATCH_RULES.HOST] = function(route_t, ctx)
      local hosts = route_t.hosts
      local req_host = ctx.hits.host or ctx.req_host
      local host = hosts[req_host] or hosts[ctx.host_no_port]
      if host then
        ctx.matches.host = host
        return true
      end

      for i = 1, hosts[0] do
        local host_t = hosts[i]
        if host_t.wildcard then
          local from, _, err = re_find(ctx.host_with_port, host_t.regex, "ajo")
          if err then
            log(ERR, "could not evaluate wildcard host regex: ", err)
            return
          end

          if from then
            ctx.matches.host = host_t.value
            return true
          end
        end
      end
    end,

    [MATCH_RULES.HEADER] = function(route_t, ctx)
      local headers = route_t.headers
      local matches_headers = {}
      ctx.matches.headers = matches_headers
      for i = 1, headers[0] do
        local found_in_req
        local header_t = headers[i]
        local req_header = ctx.req_headers[header_t.name]
        if type(req_header) == "table" then
          for j = 1, #req_header do
            local req_header_val = lower(req_header[j])
            if header_t.values_map[req_header_val] then
              found_in_req = true
              matches_headers[header_t.name] = req_header_val
              break
            end
            -- fallback to regex check if exact match failed
            if header_t.header_pattern and re_find(req_header_val, header_t.header_pattern, "jo") then
              found_in_req = true
              ctx.matches.headers[header_t.name] = req_header_val
              break
            end
          end

        elseif req_header then -- string
          req_header = lower(req_header)
          if header_t.values_map[req_header] then
            found_in_req = true
            matches_headers[header_t.name] = req_header
          end
          -- fallback to regex check if exact match failed
          if header_t.header_pattern and re_find(req_header, header_t.header_pattern, "jo") then
            found_in_req = true
            ctx.matches.headers[header_t.name] = req_header
          end
        end

        if not found_in_req then
          return
        end
      end

      return true
    end,

    [MATCH_RULES.URI] = function(route_t, ctx)
      local req_uri = ctx.req_uri
      if req_uri == "" then
        return
      end

      local matches = ctx.matches
      do
        local uri_t = route_t.uris[ctx.hits.uri or req_uri]
        if uri_t then
          if uri_t.is_regex then
            local is_match, err = match_regex_uri(uri_t, req_uri, matches)
            if is_match then
              return true
            end

            if err then
              log(ERR, "could not evaluate URI prefix/regex: ", err)
              return
            end
          end

          -- plain or prefix match from the index
          matches.uri_prefix = sub(req_uri, 1, #uri_t.value)
          matches.uri_postfix = sanitize_uri_postfix(sub(req_uri, #uri_t.value + 1))
          matches.uri = uri_t.value
          return true
        end
      end

      local uris = route_t.uris
      for i = 1, uris[0] do
        local uri_t = uris[i]
        if uri_t.is_regex then
          local is_match, err = match_regex_uri(uri_t, req_uri, matches)
          if is_match then
            return true
          end

          if err then
            log(ERR, "could not evaluate URI prefix/regex: ", err)
            return
          end

        else
          -- plain or prefix match (not from the index)
          local from, to = find(req_uri, uri_t.value, nil, true)
          if from == 1 then
            matches.uri_prefix = sub(req_uri, 1, to)
            matches.uri_postfix = sanitize_uri_postfix(sub(req_uri, to + 1))
            matches.uri = uri_t.value
            return true
          end
        end
      end
    end,

    [MATCH_RULES.METHOD] = function(route_t, ctx)
      if route_t.methods[ctx.req_method] then
        ctx.matches.method = ctx.req_method
        return true
      end
    end,

    [MATCH_RULES.SNI] = function(route_t, ctx)
      if ctx.req_scheme == "http" or route_t.snis[ctx.sni] then
        ctx.matches.sni = ctx.sni
        return true
      end
    end,

    [MATCH_RULES.SRC] = function(route_t, ctx)
      return matcher_src_dst(route_t.sources, ctx, "src_ip", "src_port")
    end,

    [MATCH_RULES.DST] = function(route_t, ctx)
      return matcher_src_dst(route_t.destinations, ctx, "dst_ip", "dst_port")
    end,
  }


  match_route = function(route_t, ctx)
    -- run cached matcher
    local match_rules = route_t.match_rules
    if type(matchers[match_rules]) == "function" then
      clear(ctx.matches)
      return matchers[match_rules](route_t, ctx)
    end

    -- build and cache matcher

    local matchers_set = { [0] = 0 }

    for _, bit_match_rule in pairs(MATCH_RULES) do
      if band(match_rules, bit_match_rule) ~= 0 then
        append(matchers_set, matchers[bit_match_rule])
      end
    end

    matchers[route_t.match_rules] = function(route_t, ctx)
      -- clear matches context for this try on this route
      clear(ctx.matches)

      for i = 1, matchers_set[0] do
        if not matchers_set[i](route_t, ctx) then
          return
        end
      end

      return true
    end

    return matchers[route_t.match_rules](route_t, ctx)
  end
end


do
  local reducers = {
    [MATCH_RULES.HOST] = function(category, ctx)
      return category.routes_by_hosts[ctx.hits.host or ctx.req_host]
    end,

    [MATCH_RULES.HEADER] = function(category, ctx)
      return category.routes_by_headers[ctx.hits.header_name]
    end,

    [MATCH_RULES.URI] = function(category, ctx)
      -- no ctx.req_uri indexing since regex URIs have a higher priority than
      -- plain URIs
      return category.routes_by_uris[ctx.hits.uri]
    end,

    [MATCH_RULES.METHOD] = function(category, ctx)
      return category.routes_by_methods[ctx.req_method]
    end,

    [MATCH_RULES.SNI] = function(category, ctx)
      return category.routes_by_sni[ctx.sni]
    end,

    [MATCH_RULES.SRC] = function(category, ctx)
      return category.routes_by_sources[ctx.src_ip]
          or category.routes_by_sources[ctx.src_port]
    end,

    [MATCH_RULES.DST] = function(category, ctx)
      return category.routes_by_destinations[ctx.dst_ip]
          or category.routes_by_destinations[ctx.dst_port]
    end,
  }

  local build_cached_reducer = function(bit_category)
    local reducers_count = 0
    local reducers_set = {}
    local header_rule = 0

    for i = 1, SORTED_MATCH_RULES[0] do
      local bit_match_rule = SORTED_MATCH_RULES[i]
      if band(bit_category, bit_match_rule) ~= 0 then
        reducers_count = reducers_count + 1
        reducers_set[reducers_count] = reducers[bit_match_rule]
        if bit_match_rule == MATCH_RULES.HEADER then
          header_rule = reducers_count
        end
      end
    end

    return function(category, ctx)
      local min_len = 0
      local smallest_set

      for i = 1, reducers_count do
        local candidates = reducers_set[i](category, ctx)
        if candidates ~= nil then
          if i == header_rule then
            return candidates
          end
          local candidates_len = #candidates
          if not smallest_set or candidates_len < min_len then
            min_len = candidates_len
            smallest_set = candidates
          end
        end
      end

      return smallest_set
    end
  end

  reduce = function(category, bit_category, ctx)
    if type(reducers[bit_category]) ~= "function" then
      -- build and cache reducer
      reducers[bit_category] = build_cached_reducer(bit_category)
    end

    -- run cached reducer
    return reducers[bit_category](category, ctx), category.all
  end
end


local function match_src_dst(source, ip, port, funcs)
  if source[ip] or source[port] then
    return true

  elseif funcs[0] > 0 then
    for i = 1, funcs[0] do
      if funcs[i](ip) then
        return true
      end
    end
  end
end


local function match_candidates(candidates, ctx)
  for i = 1, #candidates do
    if match_route(candidates[i], ctx) then
      return candidates[i]
    end
  end
end


local function find_match(ctx)
  -- iterate from the highest matching to the lowest category to
  -- find our route
  local category_idx = ctx.categories_lookup[ctx.req_category] or 1
  while category_idx <= ctx.categories_weight_sorted[0] do
    local matched_route

    local bit_category = ctx.categories_weight_sorted[category_idx].category_bit
    local category     = ctx.categories[bit_category]

    if category then
      local reduced_candidates, category_candidates = reduce(category,
                                                             bit_category,
                                                             ctx)
      if reduced_candidates then
        -- check against a reduced set of routes that is a strong candidate
        -- for this request, instead of iterating over all the routes of
        -- this category
        matched_route = match_candidates(reduced_candidates, ctx)
      end

      if not matched_route then
        -- no result from the reduced set, must check for results from the
        -- full list of routes from that category before checking a lower
        -- category
        matched_route = match_candidates(category_candidates, ctx)
      end

      if matched_route then
        local upstream_host
        local upstream_uri
        local upstream_url_t = matched_route.upstream_url_t

        if matched_route.route.id and ctx.routes_by_id[matched_route.route.id].route then
          matched_route.route = ctx.routes_by_id[matched_route.route.id].route
        end

        local matches = ctx.matches

        -- Path construction

        local request_prefix

        if matched_route.type == "http" then
          request_prefix = matched_route.strip_uri and matches.uri_prefix or nil

          -- if we do not have a path-match, then the postfix is simply the
          -- incoming path, without the initial slash
          local req_uri = ctx.req_uri
          local request_postfix = matches.uri_postfix or sub(req_uri, 2, -1)
          local upstream_base = upstream_url_t.path or "/"

          if matched_route.route.path_handling == "v1" then
            if matched_route.strip_uri then
              -- we drop the matched part, replacing it with the upstream path
              if byte(upstream_base, -1) == SLASH and
                 byte(request_postfix, 1) == SLASH then
                -- double "/", so drop the first
                upstream_uri = sub(upstream_base, 1, -2) .. request_postfix

              else
                upstream_uri = upstream_base .. request_postfix
              end

            else
              -- we retain the incoming path, just prefix it with the upstream
              -- path, but skip the initial slash
              upstream_uri = upstream_base .. sub(req_uri, 2, -1)
            end

          else -- matched_route.route.path_handling == "v0"
            upstream_uri = get_upstream_uri_v0(matched_route, request_postfix, req_uri,
                                               upstream_base)
          end

          -- preserve_host header logic

          if matched_route.preserve_host then
            upstream_host = ctx.raw_req_host
          end
        end

        if matched_route.preserve_host and upstream_host == nil then
          upstream_host = ctx.sni
        end

        return {
          route           = matched_route.route,
          service         = matched_route.service,
          headers         = matched_route.headers,
          upstream_url_t  = upstream_url_t,
          upstream_scheme = upstream_url_t.scheme,
          upstream_uri    = upstream_uri,
          upstream_host   = upstream_host,
          prefix          = request_prefix,
          matches         = {
            uri_captures  = matches.uri_captures,
            uri           = matches.uri,
            host          = matches.host,
            headers       = matches.headers,
            method        = matches.method,
            src_ip        = matches.src_ip,
            src_port      = matches.src_port,
            dst_ip        = matches.dst_ip,
            dst_port      = matches.dst_port,
            sni           = matches.sni,
          }
        }
      end
    end

    -- check lower category
    category_idx = category_idx + 1
  end
end


local _M = { DEFAULT_MATCH_LRUCACHE_SIZE = DEFAULT_MATCH_LRUCACHE_SIZE }


-- for unit-testing purposes only
_M._set_ngx = _set_ngx
_M.split_port = split_port


function _M.new(routes, cache, cache_neg)
  if type(routes) ~= "table" then
    return error("expected arg #1 routes to be a table")
  end


  -- hash table for fast lookup of plain properties
  -- incoming requests/connections
  local plain_indexes = {
    hosts             = {},
    headers           = { [0] = 0 },
    uris              = {},
    methods           = {},
    sources           = {},
    destinations      = {},
    snis              = {},
  }


  -- when hash lookup in plain_indexes fails, those are arrays
  -- of regexes for `uris` as prefixes and `hosts` as wildcards
  -- or IP ranges comparison functions
  local prefix_uris     = { [0] = 0 } -- will be sorted by length
  local regex_uris      = { [0] = 0 }
  local wildcard_hosts  = { [0] = 0 }
  local src_trust_funcs = { [0] = 0 }
  local dst_trust_funcs = { [0] = 0 }


  -- all routes grouped by the category they belong to, to reduce
  -- iterations over sets of routes per request
  local categories = {}

  -- all routes indexed by id
  local routes_by_id = {}

  if not cache then
    cache = lrucache.new(DEFAULT_MATCH_LRUCACHE_SIZE)
  end

  if not cache_neg then
    cache_neg = lrucache.new(DEFAULT_MATCH_LRUCACHE_SIZE)
  end

  -- index routes

  do
    local marshalled_routes = { [0] = 0 }

    for i = 1, #routes do
      yield(true)

      local route = routes[i]
      local r = routes[i].route
      if r.expression then
        ngx_log(ngx_ERR, "expecting a traditional route while expression is given. ",
                    "Likely it's a misconfiguration. Please check router_flavor")
      end

      if r.id ~= nil then
        routes_by_id[r.id] = route
      end

      local paths = r.paths
      local count = paths and #paths or 0
      if count > 1 then
        -- split routes by paths to sort properly
        for j = 1, count do
          r.paths = { paths[j] }
          local route_t, err = marshall_route(route)
          if not route_t then
            return nil, err
          end

          append(marshalled_routes, route_t)
        end

        r.paths = paths

      else
        local route_t, err = marshall_route(route)
        if not route_t then
          return nil, err
        end

        append(marshalled_routes, route_t)
      end
    end

    -- sort wildcard hosts and uri regexes since those rules
    -- don't have their own matching category
    --
    -- * plain hosts > wildcard hosts
    -- * more plain headers > less plain headers
    -- * regex uris > plain uris
    -- * longer plain URIs > shorter plain URIs

    sort(marshalled_routes, sort_routes)

    for i = 1, marshalled_routes[0] do
      yield(true)

      local route_t = marshalled_routes[i]
      categorize_route_t(route_t, route_t.match_rules, categories)
      index_route_t(route_t, plain_indexes, prefix_uris, regex_uris,
                    wildcard_hosts, src_trust_funcs, dst_trust_funcs)
    end
  end


  -- a sorted array of all categories bits (from the most significant
  -- matching-wise, to the least significant)
  local categories_weight_sorted = { [0] = 0 }


  -- a lookup array to get the category_idx from a category_bit. The
  -- idx will be a categories_weight_sorted index
  local categories_lookup = {}


  for category_bit, category in pairs(categories) do
    append(categories_weight_sorted, {
      category_bit = category_bit,
      match_weight = category.match_weight,
    })
  end

  sort(categories_weight_sorted, sort_categories)

  for i = 1, categories_weight_sorted[0] do
    categories_lookup[categories_weight_sorted[i].category_bit] = i
  end

  yield()

  sort(prefix_uris, sort_uris)

  if not isempty(categories) then
    for _, category in pairs(categories) do
      yield()

      sort_src_dst(category.routes_by_sources, sort_sources)
      sort_src_dst(category.routes_by_destinations, sort_destinations)
    end
  end


  local hits = {}
  local matches = {}
  local ctx = {
    hits = hits,
    matches = matches,
    categories = categories,
    categories_lookup = categories_lookup,
    categories_weight_sorted = categories_weight_sorted,
    routes_by_id = routes_by_id,
  }

  local match_headers        = plain_indexes.headers[0] > 0
  local match_prefix_uris    = prefix_uris[0] > 0
  local match_regex_uris     = regex_uris[0] > 0
  local match_hosts          = not isempty(plain_indexes.hosts)
  local match_wildcard_hosts = not isempty(wildcard_hosts)
  local match_uris           = not isempty(plain_indexes.uris)
  local match_methods        = not isempty(plain_indexes.methods)
  local match_snis           = not isempty(plain_indexes.snis)
  local match_sources        = not isempty(plain_indexes.sources)
  local match_destinations   = not isempty(plain_indexes.destinations)

  -- warning about the regex cache size being too small
  if not lua_regex_cache_max_entries then
    lua_regex_cache_max_entries = tonumber(kong.configuration.nginx_http_lua_regex_cache_max_entries) or 1024
  end

  if worker_id() == 0 and regex_uris[0] * 2 > lua_regex_cache_max_entries then
    ngx_log(WARN, "the 'nginx_http_lua_regex_cache_max_entries' setting is set to ",
                  lua_regex_cache_max_entries,
                  " but there are ", regex_uris[0], " regex paths configured. ",
                  "This may lead to performance issue due to regex cache trashing. ",
                  "Consider increasing the 'nginx_http_lua_regex_cache_max_entries' ",
                  "to at least ", regex_uris[0] * 2)
  end

  local function find_route(req_method, req_uri, req_host, req_scheme,
                            src_ip, src_port,
                            dst_ip, dst_port,
                            sni, req_headers)

    check_select_params(req_method, req_uri, req_host, req_scheme,
                        src_ip, src_port,
                        dst_ip, dst_port,
                        sni, req_headers)

    -- input sanitization for matchers

    local raw_req_host = req_host

    req_method = req_method or ""
    req_uri = req_uri or ""
    req_host = req_host or ""
    req_headers = req_headers or EMPTY_T
    src_ip = src_ip or ""
    src_port = src_port or ""
    dst_ip = dst_ip or ""
    dst_port = dst_port or ""
    sni = sni or ""

    local req_category = 0x00

    clear(hits)

    -- router, router, which of these routes is the fairest?
    --
    -- determine which category this request *might* be targeting

    -- header match

    local headers_key do
      local headers_count = 0
      if match_headers then
        for i = 1, plain_indexes.headers[0] do
          local name = plain_indexes.headers[i]
          local value = req_headers[name]
          if value then
            if type(value) == "table" then
              value = clone(value)
              for i, v in ipairs(value) do
                value[i] = v:lower()
              end
              sort(value)
              value = concat(value, ", ")

            else
              value = lower(value)
            end

            if headers_count == 0 then
              headers_key = { "|", name, "=", value }

            else
              headers_key[headers_count + 1] = "|"
              headers_key[headers_count + 2] = name
              headers_key[headers_count + 3] = "="
              headers_key[headers_count + 4] = value
            end

            headers_count = headers_count + 4

            if not hits.header_name then
              hits.header_name = name
              req_category = bor(req_category, MATCH_RULES.HEADER)
            end
          end
        end
      end
      headers_key = headers_key and concat(headers_key, nil, 1, headers_count) or ""
    end

    -- cache lookup

    local cache_key = req_method .. "|" .. req_uri .. "|" .. req_host
                                 .. "|" .. src_ip  .. "|" .. src_port
                                 .. "|" .. dst_ip  .. "|" .. dst_port
                                 .. "|" .. sni .. headers_key
    local match_t = cache:get(cache_key)
    if match_t then
      route_match_stat(ctx, "pos")

      return match_t
    end

    if cache_neg:get(cache_key) then
      route_match_stat(ctx, "neg")

      return nil
    end

    -- host match

    -- req_host might have port or maybe not, host_no_port definitely doesn't
    -- if there wasn't a port, req_port is assumed to be the default port
    -- according the protocol scheme
    local host_no_port, host_with_port
    if raw_req_host then
      host_no_port, host_with_port = split_port(req_host, req_scheme == "https" and 443 or 80)
      if match_hosts and (plain_indexes.hosts[host_with_port] or
                          plain_indexes.hosts[host_no_port])
      then
        req_category = bor(req_category, MATCH_RULES.HOST)

      elseif match_wildcard_hosts then
        for i = 1, wildcard_hosts[0] do
          local host = wildcard_hosts[i]
          local from, _, err = re_find(host_with_port, host.regex, "ajoi")
          if err then
            log(ERR, "could not match wildcard host: ", err)
            return
          end

          if from then
            hits.host    = host.value
            req_category = bor(req_category, MATCH_RULES.HOST)
            break
          end
        end
      end
    end

    -- uri match

    if match_regex_uris then
      for i = 1, regex_uris[0] do
        local from, _, err = re_find(req_uri, regex_uris[i].regex, "ajo")
        if err then
          log(ERR, "could not evaluate URI regex: ", err)
          return
        end

        if from then
          hits.uri     = regex_uris[i].value
          req_category = bor(req_category, MATCH_RULES.URI)
          break
        end
      end
    end

    if match_uris and not hits.uri then
      if plain_indexes.uris[req_uri] then
        hits.uri     = req_uri
        req_category = bor(req_category, MATCH_RULES.URI)

      elseif match_prefix_uris then
        for i = 1, prefix_uris[0] do
          if find(req_uri, prefix_uris[i].value, nil, true) == 1 then
            hits.uri     = prefix_uris[i].value
            req_category = bor(req_category, MATCH_RULES.URI)
            break
          end
        end
      end
    end

    -- method match

    if match_methods and plain_indexes.methods[req_method] then
      req_category = bor(req_category, MATCH_RULES.METHOD)
    end

    -- sni match

    if match_snis and plain_indexes.snis[sni] then
      req_category = bor(req_category, MATCH_RULES.SNI)
    end

    -- src match

    if match_sources and match_src_dst(plain_indexes.sources, src_ip, src_port, src_trust_funcs) then
      req_category = bor(req_category, MATCH_RULES.SRC)
    end

    -- dst match

    if match_destinations and match_src_dst(plain_indexes.destinations, dst_ip, dst_port, dst_trust_funcs) then
      req_category = bor(req_category, MATCH_RULES.DST)
    end

    --print("highest potential category: ", req_category)

    if req_category ~= 0x00 then
      ctx.req_category             = req_category
      ctx.raw_req_host             = raw_req_host
      ctx.req_method               = req_method
      ctx.req_uri                  = req_uri
      ctx.req_host                 = req_host
      ctx.req_scheme               = req_scheme
      ctx.req_headers              = req_headers
      ctx.src_ip                   = src_ip
      ctx.src_port                 = src_port
      ctx.dst_ip                   = dst_ip
      ctx.dst_port                 = dst_port
      ctx.sni                      = sni
      ctx.host_with_port           = host_with_port
      ctx.host_no_port             = host_no_port

      local match_t = find_match(ctx)
      if match_t then
        cache:set(cache_key, match_t)
        return match_t
      end
    end

    -- no match :'(
    cache_neg:set(cache_key, true)
  end

  local exec
  if is_http then
    exec = function(ctx)
      local req_method = get_method()
      local req_uri = ctx and ctx.request_uri or var.request_uri
      local req_host = get_header("host", ctx)
      local req_scheme = ctx and ctx.scheme or var.scheme
      local sni = server_name()

      req_host = req_host and lower(req_host) or nil

      local headers
      if match_headers then
        local err
        headers, err = get_headers()
        if err == "truncated" then
          local lua_max_req_headers = kong and kong.configuration and kong.configuration.lua_max_req_headers or 100
          log(ERR, "router: not all request headers were read in order to determine the route as ",
                    "the request contains more than ", lua_max_req_headers, " headers, route selection ",
                    "may be inaccurate, consider increasing the 'lua_max_req_headers' configuration value ",
                    "(currently at ", lua_max_req_headers, ")")
        end

        headers.host = nil
      end

      req_uri = strip_uri_args(req_uri)

      local match_t = find_route(req_method, req_uri, req_host, req_scheme,
                                 nil, nil, -- src_ip, src_port
                                 nil, nil, -- dst_ip, dst_port
                                 sni, headers)
      if match_t then
        -- debug HTTP request header logic
        add_debug_headers(ctx, header, match_t)
      end

      return match_t
    end

  else -- stream
    exec = function(ctx)
      local src_ip = var.remote_addr
      local dst_ip = var.server_addr
      local src_port = tonumber(var.remote_port, 10)
      local dst_port = (ctx or ngx.ctx).host_port or tonumber(var.server_port, 10)
      -- error value for non-TLS connections ignored intentionally
      local sni = server_name()
      -- fallback to preread SNI if current connection doesn't terminate TLS
      if not sni then
        sni = var.ssl_preread_server_name
      end

      local scheme
      if var.protocol == "UDP" then
        scheme = "udp"
      else
        scheme = sni and "tls" or "tcp"
      end

      -- when proxying TLS request in second layer or doing TLS passthrough
      -- rewrite the dst_ip, port back to what specified in proxy_protocol
      if var.kong_tls_passthrough_block == "1" or var.ssl_protocol then
        dst_ip = var.proxy_protocol_server_addr
        dst_port = tonumber(var.proxy_protocol_server_port, 10)
      end

      return find_route(nil, nil, nil, scheme,
                        src_ip, src_port,
                        dst_ip, dst_port,
                        sni)
    end
  end

  return {
    _set_ngx = _set_ngx,
    select = find_route,
    exec = exec
  }
end


return _M
