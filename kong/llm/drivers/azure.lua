local _M = {}

-- imports
local cjson = require("cjson.safe")
local fmt = string.format
local ai_shared = require("kong.llm.drivers.shared")
local openai_driver = require("kong.llm.drivers.openai")
local socket_url = require "socket.url"
local string_gsub = string.gsub
--

-- globals
local DRIVER_NAME = "azure"
--

_M.from_format = openai_driver.from_format
_M.to_format = openai_driver.to_format
_M.header_filter_hooks = openai_driver.header_filter_hooks

function _M.pre_request(conf)
  kong.service.request.set_header("Accept-Encoding", "gzip, identity")  -- tell server not to send brotli

  -- for azure provider, all of these must/will be set by now
  if conf.logging and conf.logging.log_statistics then
    kong.ctx.plugin.ai_extra_meta = {
      ["azure_instance_id"] = conf.model.options.azure_instance,
      ["azure_deployment_id"] = conf.model.options.azure_deployment_id,
      ["azure_api_version"] = conf.model.options.azure_api_version,
    }
  end

  return true
end

function _M.post_request(conf)
  if ai_shared.clear_response_headers[DRIVER_NAME] then
    for i, v in ipairs(ai_shared.clear_response_headers[DRIVER_NAME]) do
      kong.response.clear_header(v)
    end
  end
end

function _M.subrequest(body, conf, http_opts, return_res_table)
  local body_string, err

  if type(body) == "table" then
    body_string, err = cjson.encode(body)
    if err then 
      return nil, nil, "failed to parse body to json: " .. err
    end
  elseif type(body) == "string" then
    body_string = body
  else
    return nil, nil, "body must be table or string"
  end

  -- azure has non-standard URL format
  local url = (conf.model.options and conf.model.options.upstream_url)
  or fmt(
    "%s%s?api-version=%s",
    ai_shared.upstream_url_format[DRIVER_NAME]:format(conf.model.options.azure_instance, conf.model.options.azure_deployment_id),
        conf.model.options
    and conf.model.options.upstream_path
    or ai_shared.operation_map[DRIVER_NAME][conf.route_type].path,
    conf.model.options.azure_api_version
  )

  local method = ai_shared.operation_map[DRIVER_NAME][conf.route_type].method

  local headers = {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
  }

  if conf.auth and conf.auth.header_name then
    headers[conf.auth.header_name] = conf.auth.header_value
  end

  local res, err, httpc = ai_shared.http_request(url, body_string, method, headers, http_opts, return_res_table)
  if err then
    return nil, nil, "request to ai service failed: " .. err
  end

  if return_res_table then
    return res, res.status, nil, httpc
  else
    -- At this point, the entire request / response is complete and the connection
    -- will be closed or back on the connection pool.
    local status = res.status
    local body   = res.body

    if status > 299 then
      return body, res.status, "status code " .. status
    end

    return body, res.status, nil
  end
end

-- returns err or nil
function _M.configure_request(conf)
  local parsed_url

  if conf.model.options.upstream_url then
    parsed_url = socket_url.parse(conf.model.options.upstream_url)
  else
    -- azure has non-standard URL format
    local url = fmt(
      "%s%s",
      ai_shared.upstream_url_format[DRIVER_NAME]:format(conf.model.options.azure_instance, conf.model.options.azure_deployment_id),
          conf.model.options
      and conf.model.options.upstream_path
      or ai_shared.operation_map[DRIVER_NAME][conf.route_type]
      and ai_shared.operation_map[DRIVER_NAME][conf.route_type].path
      or "/"
    )

    parsed_url = socket_url.parse(url)
  end

  ai_shared.override_upstream_url(parsed_url, conf)

  -- if the path is read from a URL capture, 3re that it is valid
  parsed_url.path = string_gsub(parsed_url.path, "^/*", "/")

  kong.service.request.set_path(parsed_url.path)
  kong.service.request.set_scheme(parsed_url.scheme)
  kong.service.set_target(parsed_url.host, (tonumber(parsed_url.port) or 443))

  local auth_header_name = conf.auth and conf.auth.header_name
  local auth_header_value = conf.auth and conf.auth.header_value
  local auth_param_name = conf.auth and conf.auth.param_name
  local auth_param_value = conf.auth and conf.auth.param_value
  local auth_param_location = conf.auth and conf.auth.param_location

  if auth_header_name and auth_header_value then
    local exist_value = kong.request.get_header(auth_header_name)
    if exist_value == nil or not conf.auth.allow_override then
      kong.service.request.set_header(auth_header_name, auth_header_value)
    end
  end


  local query_table = kong.request.get_query()

  query_table["api-version"] = kong.request.get_query_arg("api-version")
                            or (conf.model.options and conf.model.options.azure_api_version)

  if auth_param_name and auth_param_value and auth_param_location == "query" then
    if query_table[auth_param_name] == nil or not conf.auth.allow_override then
      query_table[auth_param_name] = auth_param_value
    end
  end

  kong.service.request.set_query(query_table)

  -- if auth_param_location is "form", it will have already been set in a pre-request hook
  return true, nil
end


return _M
