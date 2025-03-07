local pdk_tracer = require "kong.pdk.tracing".new()
local buffer = require "string.buffer"
local kong_table = require "kong.tools.table"
local tablepool = require "tablepool"
local tablex = require "pl.tablex"
local base = require "resty.core.base"
local cjson = require "cjson"
local ngx_re = require "ngx.re"
local tracing_context = require "kong.observability.tracing.tracing_context"

local ngx = ngx
local var = ngx.var
local type = type
local next = next
local pack = kong_table.pack
local unpack = kong_table.unpack
local assert = assert
local pairs = pairs
local new_tab = base.new_tab
local time_ns = require("kong.tools.time").time_ns
local tablepool_release = tablepool.release
local get_method = ngx.req.get_method
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local tonumber = tonumber
local setmetatable = setmetatable
local cjson_encode = cjson.encode
local _log_prefix = "[tracing] "
local split = ngx_re.split
local request_id_get = require "kong.observability.tracing.request_id".get

local _M = {}
local tracer = pdk_tracer
local NOOP = function() end
local available_types = {}

local POOL_SPAN_STORAGE = "KONG_SPAN_STORAGE"

-- Record DB query
function _M.db_query(connector)
  local f = connector.query

  local function wrap(self, sql, ...)
    local span = tracer.start_span("kong.database.query")
    span:set_attribute("db.system", kong.db and kong.db.strategy)
    span:set_attribute("db.statement", sql)
    tracer.set_active_span(span)
    -- raw query
    local ret = pack(f(self, sql, ...))
    -- ends span
    span:finish()

    return unpack(ret)
  end

  connector.query = wrap
end


-- Record Router span
function _M.router()
  local span = tracer.start_span("kong.router")
  tracer.set_active_span(span)
  return span
end


-- Create a span without adding it to the KONG_SPANS list
function _M.create_span(...)
  return tracer.create_span(...)
end


--- Record OpenResty Balancer results.
-- The span includes the Lua-Land resolve DNS time
-- and the connection/response time between Nginx and upstream server.
function _M.balancer(ctx)
  local balancer_data = ctx.balancer_data
  if not balancer_data then
    return
  end

  local span
  local balancer_tries = balancer_data.tries
  local try_count = balancer_data.try_count
  local upstream_connect_time = split(var.upstream_connect_time, ", ", "jo")

  local last_try_balancer_span
  do
    local balancer_span = tracing_context.get_unlinked_span("balancer", ctx)
    -- pre-created balancer span was not linked yet
    if balancer_span and not balancer_span.linked then
      last_try_balancer_span = balancer_span
    end
  end

  for i = 1, try_count do
    local try = balancer_tries[i]
    local span_name = "kong.balancer"
    local span_options = {
      span_kind = 3, -- client
      start_time_ns = try.balancer_start_ns,
      attributes = {
        ["try_count"] =  i,
        ["net.peer.ip"] = try.ip,
        ["net.peer.port"] = try.port,
      }
    }

    -- one of the unsuccessful tries
    if i < try_count or try.state ~= nil or not last_try_balancer_span then
      span = tracer.start_span(span_name, span_options)

      if try.state then
        span:set_attribute("http.status_code", try.code)
        span:set_status(2)
      end

      if balancer_data.hostname ~= nil then
        span:set_attribute("net.peer.name", balancer_data.hostname)
      end

      if try.balancer_latency_ns ~= nil then
        local try_upstream_connect_time = (tonumber(upstream_connect_time[i], 10) or 0) * 1000
        span:finish(try.balancer_start_ns + try.balancer_latency_ns + try_upstream_connect_time * 1e6)
      else
        span:finish()
      end

    else
      -- last try: load the last span (already created/propagated)
      span = last_try_balancer_span
      tracer.set_active_span(span)
      tracer:link_span(span, span_name, span_options)

      if try.state then
        span:set_attribute("http.status_code", try.code)
        span:set_status(2)
      end

      if balancer_data.hostname ~= nil then
        span:set_attribute("net.peer.name", balancer_data.hostname)
      end

      local upstream_finish_time = ctx.KONG_BODY_FILTER_ENDED_AT_NS
      span:finish(upstream_finish_time)
    end
  end
end

-- Generator for different plugin phases
local function plugin_callback(phase)
  local name_memo = {}

  return function(plugin)
    local plugin_name = plugin.name
    local name = name_memo[plugin_name]
    if not name then
      name = "kong." .. phase .. ".plugin." .. plugin_name
      name_memo[plugin_name] = name
    end

    local span = tracer.start_span(name)
    tracer.set_active_span(span)
    return span
  end
end

_M.plugin_rewrite = plugin_callback("rewrite")
_M.plugin_access = plugin_callback("access")
_M.plugin_header_filter = plugin_callback("header_filter")


--- Record HTTP client calls
-- This only record `resty.http.request_uri` method,
-- because it's the most common usage of lua-resty-http library.
function _M.http_client()
  local http = require "resty.http"
  local luasocket_http = require "resty.luasocket.http"

  local function get_wrapper(f)
    return function(self, arg1, arg2)
      local params = arg2 or arg1
      local uri = arg2 and arg1 or params.path

      local method = params and params.method or "GET"
      local attributes = new_tab(0, 5)
      -- passing full URI to http.url attribute
      attributes["http.url"] = uri
      attributes["http.method"] = method
      attributes["http.flavor"] = params and params.version or "1.1"
      attributes["http.user_agent"] = params and params.headers and params.headers["User-Agent"]
          or http._USER_AGENT

      local http_proxy = self.proxy_opts and (self.proxy_opts.https_proxy or self.proxy_opts.http_proxy)
      if http_proxy then
        attributes["http.proxy"] = http_proxy
      end

      local span = tracer.start_span("kong.internal.request", {
        span_kind = 3, -- client
        attributes = attributes,
      })

      if not span then
        if err then
          log(ngx_ERR, "failed to start span: ", err)
        end
        return f(self, arg1, arg2)
      end

      tracer.set_active_span(span)

      local res, err = f(self, arg1, arg2)
      if res then
        attributes["http.status_code"] = res.status -- number
      else
        span:record_error(err)
      end
      span:finish()
      return res, err
    end
  end

  luasocket_http.request_uri = get_wrapper(request_uri)
  luasocket_http.request = get_wrapper(request)
  http.request_uri = get_wrapper(request_uri)
  http.request = get_wrapper(request)
end

--- Register available_types
-- functions in this list will be replaced with NOOP
-- if tracing module is NOT enabled.
for k, _ in pairs(_M) do
  available_types[k] = true
end
_M.available_types = available_types


-- Record inbound request
function _M.request(ctx)
  local client = kong.client

  local method = get_method()
  local scheme = ctx.scheme or var.scheme
  local host = var.host
  -- passing full URI to http.url attribute
  local req_uri = scheme .. "://" .. host .. (ctx.request_uri or var.request_uri)

  local start_time = ctx.KONG_PROCESSING_START
                 and ctx.KONG_PROCESSING_START * 1e6
                  or time_ns()

  local http_flavor = ngx.req.http_version()
  if type(http_flavor) == "number" then
    http_flavor = string.format("%.1f", http_flavor)
  end

  local active_span = tracer.start_span("kong", {
    span_kind = 2, -- server
    start_time_ns = start_time,
    attributes = {
      ["http.method"] = method,
      ["http.url"] = req_uri,
      ["http.host"] = host,
      ["http.scheme"] = scheme,
      ["http.flavor"] = http_flavor,
      ["http.client_ip"] = client.get_forwarded_ip(),
      ["net.peer.ip"] = client.get_ip(),
      ["kong.request.id"] = request_id_get(),
    },
  })

  -- update the tracing context with the request span trace ID
  tracing_context.set_raw_trace_id(active_span.trace_id, ctx)

  tracer.set_active_span(active_span)
end


function _M.precreate_balancer_span(ctx)
  if _M.balancer == NOOP then
    -- balancer instrumentation not enabled
    return
  end

  local root_span = ctx.KONG_SPANS and ctx.KONG_SPANS[1]
  local balancer_span = tracer.create_span(nil, {
    span_kind = 3,
    parent = root_span,
  })
  -- The balancer span is created during headers propagation, but is
  -- linked later when the balancer data is available, so we add it
  -- to the unlinked spans table to keep track of it.
  tracing_context.set_unlinked_span("balancer", balancer_span, ctx)
end


do
  local raw_func

  local function wrap(host, port, ...)
    local span
    if _M.dns_query ~= NOOP then
      span = tracer.start_span("kong.dns", {
        span_kind = 3, -- client
      })
      tracer.set_active_span(span)
    end

    local ip_addr, res_port, try_list = raw_func(host, port, ...)
    if span then
      span:set_attribute("dns.record.domain", host)
      span:set_attribute("dns.record.port", port)
      if ip_addr then
        span:set_attribute("dns.record.ip", ip_addr)
      else
        span:record_error(res_port)
        span:set_status(2)
      end
      span:finish()
    end

    return ip_addr, res_port, try_list
  end

  --- Get Wrapped DNS Query
  -- Called before Kong's config loader.
  --
  -- returns a wrapper for the provided input function `f`
  -- that stores dns info in the `kong.dns` span when the dns
  -- instrumentation is enabled.
  function _M.get_wrapped_dns_query(f)
    raw_func = f
    return wrap
  end

  -- append available_types
  available_types.dns_query = true
end


-- runloop
function _M.runloop_before_header_filter()
  local root_span = ngx.ctx.KONG_SPANS and ngx.ctx.KONG_SPANS[1]
  if root_span then
    root_span:set_attribute("http.status_code", ngx.status)
    local r = ngx.ctx.route
    root_span:set_attribute("http.route", r and r.paths and r.paths[1] or "")
  end
end


function _M.runloop_log_before(ctx)
  -- add balancer
  _M.balancer(ctx)

  local active_span = tracer.active_span()
  -- check root span type to avoid encounter error
  if active_span and type(active_span.finish) == "function" then
    local end_time = ctx.KONG_BODY_FILTER_ENDED_AT_NS
    active_span:finish(end_time)
  end
end

-- serialize lazily
local lazy_format_spans
do
  local lazy_mt = {
    __tostring = function(spans)
      local logs_buf = buffer.new(1024)

      for i = 1, #spans do
        local span = spans[i]

        logs_buf:putf("\nSpan #%d name=%s", i, span.name)

        if span.end_time_ns then
          logs_buf:putf(" duration=%fms", (span.end_time_ns - span.start_time_ns) / 1e6)
        end

        if span.attributes then
          logs_buf:putf(" attributes=%s", cjson_encode(span.attributes))
        end
      end

      local str = logs_buf:get()

      logs_buf:free()

      return str
    end
  }

  lazy_format_spans = function(spans)
    return setmetatable(spans, lazy_mt)
  end
end

-- clean up
function _M.runloop_log_after(ctx)
  -- Clears the span table and put back the table pool,
  -- this avoids reallocation.
  -- The span table MUST NOT be used after released.
  if type(ctx.KONG_SPANS) == "table" then
    ngx_log(ngx_DEBUG, _log_prefix, "collected ", #ctx.KONG_SPANS, " spans: ", lazy_format_spans(ctx.KONG_SPANS))

    for i = 1, #ctx.KONG_SPANS do
      local span = ctx.KONG_SPANS[i]
      if type(span) == "table" and type(span.release) == "function" then
        span:release()
      end
    end

    tablepool_release(POOL_SPAN_STORAGE, ctx.KONG_SPANS)
  end
end

function _M.init(config)
  local trace_types = config.tracing_instrumentations
  local sampling_rate = config.tracing_sampling_rate
  assert(type(trace_types) == "table" and next(trace_types))
  assert(sampling_rate >= 0 and sampling_rate <= 1)

  local enabled = trace_types[1] ~= "off"

  -- noop instrumentations
  -- TODO: support stream module
  if not enabled or ngx.config.subsystem == "stream" then
    for k, _ in pairs(available_types) do
      _M[k] = NOOP
    end

    -- remove root span generator
    _M.request = NOOP
  end

  if trace_types[1] ~= "all" then
    for k, _ in pairs(available_types) do
      if not tablex.find(trace_types, k) then
        _M[k] = NOOP
      end
    end
  end

  if enabled then
    -- global tracer
    tracer = pdk_tracer.new("instrument", {
      sampling_rate = sampling_rate,
    })
    tracer.set_global_tracer(tracer)
  end
end

return _M
