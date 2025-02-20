-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local fmt            = string.format
local http           = require("resty.http")
local ai_plugin_ctx  = require("kong.llm.plugin.ctx")
local ai_plugin_o11y = require("kong.llm.plugin.observability")
local ai_shared      = require("kong.llm.drivers.shared")
local llm            = require("kong.llm")
local kong_utils     = require("kong.tools.gzip")

local _M = {
  NAME = "ai-response-transformer-transform-response",
  STAGE = "RES_TRANSFORMATION",
  }

local FILTER_OUTPUT_SCHEMA = {
  transformed = "boolean",
  model = "table",
  -- TODO: refactor this so they don't need to be duplicated
  llm_prompt_tokens_count = "number",
  llm_completion_tokens_count = "number",
  llm_usage_cost = "number",
}

local _, set_ctx = ai_plugin_ctx.get_namespaced_accesors(_M.NAME, FILTER_OUTPUT_SCHEMA)
local _, set_global_ctx = ai_plugin_ctx.get_global_accessors(_M.NAME)

local _KEYBASTION = setmetatable({}, {
  __mode = "k",
  __index = ai_shared.cloud_identity_function,
})


local function bad_request(msg)
  kong.log.info(msg)
  return kong.response.exit(400, { error = { message = msg } })
end

local function internal_server_error(msg)
  kong.log.err(msg)
  return kong.response.exit(500, { error = { message = msg } })
end

local function create_http_opts(conf)
  local http_opts = {}

  if conf.http_proxy_host then -- port WILL be set via schema constraint
    http_opts.proxy_opts = http_opts.proxy_opts or {}
    http_opts.proxy_opts.http_proxy = fmt("http://%s:%d", conf.http_proxy_host, conf.http_proxy_port)
  end

  if conf.https_proxy_host then
    http_opts.proxy_opts = http_opts.proxy_opts or {}
    http_opts.proxy_opts.https_proxy = fmt("http://%s:%d", conf.https_proxy_host, conf.https_proxy_port)
  end

  http_opts.http_timeout = conf.http_timeout
  http_opts.https_verify = conf.https_verify

  return http_opts
end

local function subrequest(httpc, request_body, http_opts)
  httpc:set_timeouts(http_opts.http_timeout or 60000)

  local upstream_uri = ngx.var.upstream_uri
  if ngx.var.is_args == "?" or string.sub(ngx.var.request_uri, -1) == "?" then
      ngx.var.upstream_uri = upstream_uri .. "?" .. (ngx.var.args or "")
  end

  local ok, err = httpc:connect {
      scheme = ngx.var.upstream_scheme,
      host = ngx.ctx.balancer_data.host,
      port = ngx.ctx.balancer_data.port,
      proxy_opts = http_opts.proxy_opts,
      ssl_verify = http_opts.https_verify,
      ssl_server_name = ngx.ctx.balancer_data.host,
  }

  if not ok then
      return nil, "failed to connect to upstream: " .. err
  end

  local headers = kong.request.get_headers()
  headers["transfer-encoding"] = nil -- transfer-encoding is hop-by-hop, strip
                                      -- it out
  headers["content-length"] = nil -- clear content-length - it will be set
                                  -- later on by resty-http (if not found);
                                  -- further, if we leave it here it will
                                  -- cause issues if the value varies (if may
                                  -- happen, e.g., due to a different transfer
                                  -- encoding being used subsequently)

  if ngx.var.upstream_host == "" then
      headers["host"] = nil
  else
      headers["host"] = ngx.var.upstream_host
  end

  local res, err = httpc:request({
      method  = kong.request.get_method(),
      path    = ngx.var.upstream_uri,
      headers = headers,
      body    = request_body,
  })

  if not res then
      return nil, "subrequest failed: " .. err
  end

  return res
end


function _M:run(conf)
  -- get cloud identity SDK, if required
  local identity_interface = _KEYBASTION[conf.llm]

  if identity_interface and identity_interface.error then
    kong.log.err("error authenticating with ", conf.llm.model.provider, " using native provider auth, ", identity_interface.error)
    return kong.response.exit(500, "LLM request failed before proxying")
  end

  -- first find the configured LLM interface and driver
  local http_opts = create_http_opts(conf)
  conf.llm.__plugin_id = conf.__plugin_id
  conf.llm.__key__ = conf.__key__
  local ai_driver, err = llm.new_driver(conf.llm, http_opts, identity_interface)

  if not ai_driver then
    return internal_server_error(err)
  end

  kong.log.debug("intercepting plugin flow with one-shot request")
  local httpc = http.new()
  local res, err = subrequest(httpc,
    kong.request.get_raw_body(conf.max_request_body_size),
    http_opts)
  if err then
    return internal_server_error(err)
  end

  local res_body = res:read_body()
  local is_gzip = res.headers["Content-Encoding"] == "gzip"
  if is_gzip then
    res_body = kong_utils.inflate_gzip(res_body)
  end

  -- if asked, introspect the request before proxying
  kong.log.debug("introspecting response with LLM")

  local new_response_body, err = ai_driver:ai_introspect_body(
    res_body,
    conf.prompt,
    http_opts,
    conf.transformation_extract_pattern
  )

  if err then
    return bad_request(err)
  end

  if res.headers then
    res.headers["content-length"] = nil
    res.headers["content-encoding"] = nil
    res.headers["transfer-encoding"] = nil
  end

  local headers, body, status
  if conf.parse_llm_response_json_instructions then
    headers, body, status, err = ai_driver:parse_json_instructions(new_response_body)
    if err then
      return internal_server_error("failed to parse JSON response instructions from AI backend: " .. err)
    end

    if headers then
      for k, v in pairs(headers) do
        res.headers[k] = v  -- override e.g. ['content-type']
      end
    end

    headers = res.headers
  else

    headers = res.headers     -- headers from upstream
    body = new_response_body  -- replacement body from AI
    status = res.status       -- status from upstream
  end

  set_ctx("transformed", true)
  set_global_ctx("response_body_sent", true)
  set_ctx("model", conf.llm.model)
  set_ctx("llm_prompt_tokens_count", ai_plugin_o11y.metrics_get("llm_prompt_tokens_count") or 0)
  set_ctx("llm_completion_tokens_count", ai_plugin_o11y.metrics_get("llm_completion_tokens_count") or 0)
  set_ctx("llm_usage_cost", ai_plugin_o11y.metrics_get("llm_usage_cost") or 0)
  return kong.response.exit(status, body, headers)
end


return _M
