local kong = kong
local ngx_encode_base64 = ngx.encode_base64
local ngx_decode_base64 = ngx.decode_base64
local null = ngx.null
local cjson = require "cjson.safe"

local date = require("date")
local get_request_id = require("kong.observability.tracing.request_id").get

local EMPTY = {}

local isempty = require "table.isempty"
local split = require("kong.tools.string").split
local ngx_req_get_headers  = ngx.req.get_headers
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_get_http_version = ngx.req.http_version
local ngx_req_start_time = ngx.req.start_time


local raw_content_types = {
  ["text/plain"] = true,
  ["text/html"] = true,
  ["application/xml"] = true,
  ["text/xml"] = true,
  ["application/soap+xml"] = true,
}


local function read_request_body(skip_large_bodies)
  ngx.req.read_body()
  local body = ngx.req.get_body_data()

  if not body then
    -- see if body was buffered to tmp file, payload could have exceeded client_body_buffer_size
    local body_filepath = ngx.req.get_body_file()
    if body_filepath then
      if skip_large_bodies then
        ngx.log(ngx.ERR, "request body was buffered to disk, too large")
      else
        local file = io.open(body_filepath, "rb")
        body = file:read("*all")
        file:close()
      end
    end
  end

  return body
end


local function validate_http_status_code(status_code)
  if not status_code then
    return false
  end

  if type(status_code) == "string" then
    status_code = tonumber(status_code)

    if not status_code then
      return false
    end
  end

  if status_code >= 100 and status_code <= 599 then
    return status_code
  end

  return false
end


--[[
  Response format should be
  {
      "statusCode": httpStatusCode,
      "headers": { "headerName": "headerValue", ... },
      "body": "..."
  }
--]]
local function validate_custom_response(response)
  if not validate_http_status_code(response.statusCode) then
    return nil, "statusCode validation failed"
  end

  if response.headers ~= nil and type(response.headers) ~= "table" then
    return nil, "headers must be a table"
  end

  if response.body ~= nil and type(response.body) ~= "string" then
    return nil, "body must be a string"
  end

  if response.isBase64Encoded ~= nil and type(response.isBase64Encoded) ~= "boolean" then
    return nil, "isBase64Encoded must be a boolean"
  end

  return true
end


local function extract_proxy_response(content)
  local serialized_content, err
  if type(content) == "string" then
    serialized_content, err = cjson.decode(content)
    if not serialized_content then
      return nil, err
    end

  elseif type(content) == "table" then
    serialized_content = content

  else
    return nil, "proxy response must be json format"
  end

  local ok, err = validate_custom_response(serialized_content)
  if not ok then
    return nil, err
  end

  local headers = serialized_content.headers or {}
  local body = serialized_content.body or ""
  local isBase64Encoded = serialized_content.isBase64Encoded
  if isBase64Encoded == true then
    body = ngx_decode_base64(body)
  end

  local multiValueHeaders = serialized_content.multiValueHeaders
  if multiValueHeaders and multiValueHeaders ~= null then
    for header, values in pairs(multiValueHeaders) do
      headers[header] = values
    end
  end

  headers["Content-Length"] = #body

  return {
    status_code = tonumber(serialized_content.statusCode),
    body = body,
    headers = headers,
  }
end


local function aws_serializer(ctx, config)
  ctx = ctx or ngx.ctx
  local var = ngx.var

  -- prepare headers
  local headers = ngx_req_get_headers()
  local multiValueHeaders = {}
  for hname, hvalue in pairs(headers) do
    if type(hvalue) == "table" then
      -- multi value
      multiValueHeaders[hname] = hvalue
      headers[hname] = hvalue[1]

    else
      -- single value
      multiValueHeaders[hname] = { hvalue }
    end
  end

  -- prepare url-captures/path-parameters
  local pathParameters = {}
  for name, value in pairs(ctx.router_matches.uri_captures or EMPTY) do
    if type(name) == "string" then  -- skip numerical indices, only named
      pathParameters[name] = value
    end
  end

  -- query parameters
  local queryStringParameters = ngx_req_get_uri_args()
  local multiValueQueryStringParameters = {}
  for qname, qvalue in pairs(queryStringParameters) do
    if type(qvalue) == "table" then
      -- multi value
      multiValueQueryStringParameters[qname] = qvalue
      queryStringParameters[qname] = qvalue[1]

    else
      -- single value
      multiValueQueryStringParameters[qname] = { qvalue }
    end
  end

  -- prepare body
  local body, isBase64Encoded
  local skip_large_bodies = true
  local base64_encode_body = true

  if config then
    if config.skip_large_bodies ~= nil then
      skip_large_bodies = config.skip_large_bodies
    end

    if config.base64_encode_body ~= nil then
      base64_encode_body = config.base64_encode_body
    end
  end

  do
    body = read_request_body(skip_large_bodies)
    if body ~= "" and base64_encode_body then
      body = ngx_encode_base64(body)
      isBase64Encoded = true
    else
      isBase64Encoded = false
    end
  end

  -- prepare path
  local uri = var.upstream_uri or var.request_uri
  local path = uri:match("^([^%?]+)")  -- strip any query args

  local requestContext
  do
    local http_version = ngx_get_http_version()
    local protocol = http_version and 'HTTP/'..http_version or nil
    local httpMethod = var.request_method
    local domainName = var.host
    local domainPrefix = split(domainName, ".")[1]
    local identity = {
      sourceIp = var.realip_remote_addr or var.remote_addr,
      userAgent = headers["user-agent"],
    }
    local requestId = get_request_id()
    local start_time = ngx_req_start_time()
    -- The CLF-formatted request time (dd/MMM/yyyy:HH:mm:ss +-hhmm).
    local requestTime = date(start_time):fmt("%d/%b/%Y:%H:%M:%S %z")
    local requestTimeEpoch = start_time * 1000

    -- Kong does not have the concept of stage, so we just let resource path be the same as path
    local resourcePath = path

    requestContext = {
      path = path,
      protocol = protocol,
      httpMethod = httpMethod,
      domainName = domainName,
      domainPrefix = domainPrefix,
      identity = identity,
      requestId = requestId,
      requestTime = requestTime,
      requestTimeEpoch = requestTimeEpoch,
      resourcePath = resourcePath,
    }
  end

  local request = {
    version                         = "1.0",
    resource                        = ctx.router_matches.uri,
    path                            = path,
    httpMethod                      = var.request_method,
    headers                         = headers,
    multiValueHeaders               = multiValueHeaders,
    pathParameters                  = pathParameters,
    queryStringParameters           = queryStringParameters,
    multiValueQueryStringParameters = multiValueQueryStringParameters,
    body                            = body,
    isBase64Encoded                 = isBase64Encoded,
    requestContext                  = requestContext,
  }

  return request
end


-- Build the JSON blob that you want to provide to your Lambda function as input.
local function build_request_payload(conf)
  local upstream_body = kong.table.new(0, 6)
  local ctx = ngx.ctx

  if conf.awsgateway_compatible then
    upstream_body = aws_serializer(ctx, conf)

  elseif conf.forward_request_body or
    conf.forward_request_headers or
    conf.forward_request_method or
    conf.forward_request_uri then

    -- new behavior to forward request method, body, uri and their args
    if conf.forward_request_method then
      upstream_body.request_method = kong.request.get_method()
    end

    if conf.forward_request_headers then
      upstream_body.request_headers = kong.request.get_headers()
    end

    if conf.forward_request_uri then
      upstream_body.request_uri = kong.request.get_path_with_query()
      upstream_body.request_uri_args = kong.request.get_query()
    end

    if conf.forward_request_body then
      local content_type = ngx.var.http_content_type
      local body_raw = read_request_body(conf.skip_large_bodies)
      local body_args, err = kong.request.get_body()
      if err and err:match("content type") then
        body_args = {}
        if not raw_content_types[content_type] and conf.base64_encode_body then
          -- don't know what this body MIME type is, base64 it just in case
          body_raw = ngx_encode_base64(body_raw)
          upstream_body.request_body_base64 = true
        end
      end

      upstream_body.request_body      = body_raw
      upstream_body.request_body_args = body_args
    end

  else
    -- backwards compatible upstream body for configurations not specifying
    -- `forward_request_*` values
    local body_args = kong.request.get_body()
    upstream_body = kong.table.merge(kong.request.get_query(), body_args)
  end

  local upstream_body_json, err = cjson.encode(upstream_body)
  if not upstream_body_json then
    kong.log.err("could not JSON encode upstream body",
                 " to forward request values: ", err)
  end

  return upstream_body_json
end


-- TODO: remove this in the next major release
-- function to remove array_mt metatables from empty tables
-- This is just a backward compatibility code to keep a
-- long-lived behavior that Kong responsed JSON objects
-- instead of JSON arrays for empty arrays.
local function remove_array_mt_for_empty_table(tbl)
  if type(tbl) ~= "table" then
    return tbl
  end

  -- Check if the current table(array) is empty and has a array_mt metatable, and remove it
  if isempty(tbl) and getmetatable(tbl) == cjson.array_mt then
    setmetatable(tbl, nil)
  end

  for _, value in pairs(tbl) do
    if type(value) == "table" then
      remove_array_mt_for_empty_table(value)
    end
  end

  return tbl
end


return {
  aws_serializer = aws_serializer,
  validate_http_status_code = validate_http_status_code,
  validate_custom_response = validate_custom_response,
  build_request_payload = build_request_payload,
  extract_proxy_response = extract_proxy_response,
  remove_array_mt_for_empty_table = remove_array_mt_for_empty_table,
}
