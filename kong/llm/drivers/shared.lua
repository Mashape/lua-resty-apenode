local _M = {}

-- imports
local cjson      = require("cjson.safe")
local http       = require("resty.http")
local fmt        = string.format
local os         = os
local parse_url  = require("socket.url").parse
local aws_stream = require("kong.tools.aws_stream")
local ai_plugin_ctx = require("kong.llm.plugin.ctx")
local ai_plugin_o11y = require("kong.llm.plugin.observability")
--

-- static
local str_find     = string.find
local str_sub      = string.sub
local string_match = string.match
local split        = require("kong.tools.string").split
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy

local function str_ltrim(s) -- remove leading whitespace from string.
  return type(s) == "string" and s:gsub("^%s*", "")
end

local function str_rtrim(s) -- remove trailing whitespace from string.
  return type(s) == "string" and s:match('^(.*%S)%s*$')
end
--

local log_entry_keys = {
  USAGE_CONTAINER = "usage",
  META_CONTAINER = "meta",
  PAYLOAD_CONTAINER = "payload",
  CACHE_CONTAINER = "cache",

  -- payload keys
  REQUEST_BODY = "request",
  RESPONSE_BODY = "response",

  -- meta keys
  PLUGIN_ID = "plugin_id",
  PROVIDER_NAME = "provider_name",
  REQUEST_MODEL = "request_model",
  RESPONSE_MODEL = "response_model",
  LLM_LATENCY = "llm_latency",

  -- usage keys
  PROMPT_TOKENS = "prompt_tokens",
  COMPLETION_TOKENS = "completion_tokens",
  TOTAL_TOKENS = "total_tokens",
  TIME_PER_TOKEN = "time_per_token",
  COST = "cost",

  -- cache keys
  VECTOR_DB = "vector_db",
  EMBEDDINGS_PROVIDER = "embeddings_provider",
  EMBEDDINGS_MODEL = "embeddings_model",
  CACHE_STATUS = "cache_status",
}

local openai_override = os.getenv("OPENAI_TEST_PORT")

---- IDENTITY SETTINGS
local GCP_SERVICE_ACCOUNT do
  GCP_SERVICE_ACCOUNT = os.getenv("GCP_SERVICE_ACCOUNT")
end

local GCP = require("resty.gcp.request.credentials.accesstoken")
local aws_config = require "resty.aws.config"  -- reads environment variables whilst available
local AWS = require("resty.aws")
local AWS_REGION do
  AWS_REGION = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
end
----

_M._CONST = {
  ["SSE_TERMINATOR"] = "[DONE]",
  ["AWS_STREAM_CONTENT_TYPE"] = "application/vnd.amazon.eventstream",
}

_M._SUPPORTED_STREAMING_CONTENT_TYPES = {
  ["text/event-stream"] = true,
  ["application/vnd.amazon.eventstream"] = true,
  ["application/json"] = true,
  ["application/stream+json"] = true,
}

_M.streaming_has_token_counts = {
  ["cohere"] = true,
  ["llama2"] = true,
  ["anthropic"] = true,
  ["gemini"] = true,
  ["bedrock"] = true,
}

_M.upstream_url_format = {
  openai        = fmt("%s://api.openai.com:%s", openai_override and "http" or "https", openai_override or "443"),
  anthropic     = "https://api.anthropic.com:443",
  cohere        = "https://api.cohere.com:443",
  azure         = fmt("%s://%%s.openai.azure.com:%s/openai/deployments/%%s", openai_override and "http" or "https", openai_override or "443"),
  gemini        = "https://generativelanguage.googleapis.com",
  gemini_vertex = "https://%s",
  bedrock       = "https://bedrock-runtime.%s.amazonaws.com",
  mistral       = "https://api.mistral.ai:443",
  huggingface   = "https://api-inference.huggingface.co/models/%s",
}

_M.operation_map = {
  openai = {
    ["llm/v1/completions"] = {
      path = "/v1/completions",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/v1/chat/completions",
      method = "POST",
    },
  },
  anthropic = {
    ["llm/v1/completions"] = {
      path = "/v1/complete",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/v1/messages",
      method = "POST",
    },
  },
  cohere = {
    ["llm/v1/completions"] = {
      path = "/v1/generate",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/v1/chat",
      method = "POST",
    },
  },
  azure = {
    ["llm/v1/completions"] = {
      path = "/completions",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/chat/completions",
      method = "POST",
    },
  },
  gemini = {
    ["llm/v1/chat"] = {
      path = "/v1beta/models/%s:%s",
      method = "POST",
    },
  },
  gemini_vertex = {
    ["llm/v1/chat"] = {
      path = "/v1/projects/%s/locations/%s/publishers/google/models/%s:%s",
    },
  },
  huggingface = {
    ["llm/v1/completions"] = {
      path = "/models/%s",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/models/%s",
      method = "POST",
    },
  },
  bedrock = {
    ["llm/v1/chat"] = {
      path = "/model/%s/%s",
      method = "POST",
    },
  },
}

_M.clear_response_headers = {
  shared = { -- deprecared, not using
    "Content-Length",
  },
  openai = {
    "Set-Cookie",
  },
  azure = {
    "Set-Cookie",
  },
  mistral = {
    "Set-Cookie",
  },
  gemini = {
    "Set-Cookie",
  },
  bedrock = {
    "Set-Cookie",
  },
}

---
-- Takes an already 'standardised' input, and merges
-- any missing fields with their defaults as defined
-- in the plugin config.
--
-- It it supposed to be completely provider-agnostic,
-- and only operate to assist the Kong operator to
-- allow their users and admins to define a pre-runed
-- set of default options for any AI inference request.
--
-- @param {table} request kong-format inference request conforming to one of many supported formats
-- @param {table} options the 'config.model.options' table from any Kong AI plugin
-- @return {table} the input 'request' table, but with (missing) default options merged in
-- @return {string} error if any is thrown - request should definitely be terminated if this is not nil
function _M.merge_config_defaults(request, options, request_format)
  if options then
    request.temperature = options.temperature or request.temperature
    request.max_tokens = options.max_tokens or request.max_tokens 
    request.top_p = options.top_p or request.top_p
    request.top_k = options.top_k or request.top_k
  end

  return request, nil
end

local function handle_stream_event(event_table, model_info, route_type)
  if event_table.done then
    -- return analytics table
    return "[DONE]", nil, {
      prompt_tokens = event_table.prompt_eval_count or 0,
      completion_tokens = event_table.eval_count or 0,
    }

  else
    -- parse standard response frame
    if route_type == "stream/llm/v1/chat" then
      return {
        choices = {
          [1] = {
            delta = {
              content = event_table.message and event_table.message.content or "",
            },
            index = 0,
          },
        },
        model = event_table.model,
        object = "chat.completion.chunk",
      }

    elseif route_type == "stream/llm/v1/completions" then
      return {
        choices = {
          [1] = {
            text = event_table.response or "",
            index = 0,
          },
        },
        model = event_table.model,
        object = "text_completion",
      }

    end
  end
end

---
-- Manages cloud SDKs, for using "workload identity" authentications,
-- that are tied to this specific plugin in-memory.
--
-- This allows users to run different authentication configurations
-- between different AI Plugins.
--
-- @param {table} this_cache self - stores all the SDK instances
-- @param {table} plugin_config the configuration to cache against and also provide SDK settings with
-- @return {table} self
_M.cloud_identity_function = function(this_cache, plugin_config)
  if plugin_config.model.provider == "gemini" and
      plugin_config.auth and
      plugin_config.auth.gcp_use_service_account then

    ngx.log(ngx.DEBUG, "loading gcp sdk for plugin ", kong.plugin.get_id())

    local service_account_json = (plugin_config.auth and plugin_config.auth.gcp_service_account_json) or GCP_SERVICE_ACCOUNT

    local ok, gcp_auth = pcall(GCP.new, nil, service_account_json)
    if ok and gcp_auth then
      -- store our item for the next time we need it
      gcp_auth.service_account_json = service_account_json
      this_cache[plugin_config] = { interface = gcp_auth, error = nil }
      return this_cache[plugin_config]
    end

    return { interface = nil, error = "cloud-authentication with GCP failed" }

  elseif plugin_config.model.provider == "bedrock" then
    ngx.log(ngx.DEBUG, "loading aws sdk for plugin ", kong.plugin.get_id())
    local aws

    local region = plugin_config.model.options
                and plugin_config.model.options.bedrock
                and plugin_config.model.options.bedrock.aws_region
                or AWS_REGION

    if not region then
      return { interface = nil, error = "AWS region not specified anywhere" }
    end

    local access_key_set = (plugin_config.auth and plugin_config.auth.aws_access_key_id)
                        or aws_config.global.AWS_ACCESS_KEY_ID
    local secret_key_set = plugin_config.auth and plugin_config.auth.aws_secret_access_key
                        or aws_config.global.AWS_SECRET_ACCESS_KEY

    aws = AWS({
      -- if any of these are nil, they either use the SDK default or
      -- are deliberately null so that a different auth chain is used
      region = region,
    })

    if access_key_set and secret_key_set then
      -- Override credential config according to plugin config, if set
      local creds = aws:Credentials {
        accessKeyId = access_key_set,
        secretAccessKey = secret_key_set,
      }

      aws.config.credentials = creds
    end

    this_cache[plugin_config] = { interface = aws, error = nil }

    return this_cache[plugin_config]
  end
end

---
-- Splits a HTTPS data chunk or frame into individual
-- SSE-format messages, see:
-- https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#event_stream_format
--
-- For compatibility, it also looks for the first character being '{' which
-- indicates that the input is not text/event-stream format, but instead a chunk
-- of delimited application/json, which some providers return, in which case
-- it simply splits the frame into separate JSON messages and appends 'data: '
-- as if it were an SSE message.
--
-- @param {string} frame input string to format into SSE events
-- @param {string} content_type sets parser
-- @return {table} n number of split SSE messages, or empty table
function _M.frame_to_events(frame, content_type)
  local events = {}

  if (not frame) or (#frame < 1) or (type(frame)) ~= "string" then
    return
  end

  -- some new LLMs return the JSON object-by-object,
  -- because that totally makes sense to parse?!
  local frame_start = frame and frame:sub(1, 1)
  if frame_start == "," or frame_start == "[" then
    local done = false

    -- if this is the first frame, it will begin with array opener '['
    frame = (string.sub(str_ltrim(frame), 1, 1) == "[" and string.sub(str_ltrim(frame), 2)) or frame

    -- it may start with ',' which is the start of the new frame
    frame = (string.sub(str_ltrim(frame), 1, 1) == "," and string.sub(str_ltrim(frame), 2)) or frame

    -- it may end with the array terminator ']' indicating the finished stream
    if string.sub(str_rtrim(frame), -1) == "]" then
      frame = string.sub(str_rtrim(frame), 1, -2)
      done = true
    end

    -- for multiple events that arrive in the same frame, split by top-level comma
    for _, v in ipairs(split(frame, "\n,")) do
      events[#events+1] = { data = v }
    end

    if done then
      -- add the done signal here
      -- but we have to retrieve the metadata from a previous filter run
      events[#events+1] = { data = _M._CONST.SSE_TERMINATOR }
    end

  elseif content_type == _M._CONST.AWS_STREAM_CONTENT_TYPE then
    local parser = aws_stream:new(frame)
    while true do
      local msg = parser:next_message()

      if not msg then
        break
      end

      events[#events+1] = { data = cjson.encode(msg) }
    end

  -- check if it's raw json and just return the split up data frame
  -- Cohere / Other flat-JSON format parser
  -- just return the split up data frame
  elseif (not kong or not kong.ctx.plugin.truncated_frame) and string.sub(str_ltrim(frame), 1, 1) == "{" then
    for event in frame:gmatch("[^\r\n]+") do
      events[#events + 1] = {
        data = event,
      }
    end

  -- standard SSE parser
  else
    local event_lines = split(frame, "\n")
    local struct = { event = nil, id = nil, data = nil }

    for i, dat in ipairs(event_lines) do
      if #dat < 1 then
        events[#events + 1] = struct
        struct = { event = nil, id = nil, data = nil }
      end

      -- test for truncated chunk on the last line (no trailing \r\n\r\n)
      if #dat > 0 and #event_lines == i then
        ngx.log(ngx.DEBUG, "[ai-proxy] truncated sse frame head")
        if kong then
          kong.ctx.plugin.truncated_frame = dat
        end

        break  -- stop parsing immediately, server has done something wrong
      end

      -- test for abnormal start-of-frame (truncation tail)
      if kong and kong.ctx.plugin.truncated_frame then
        -- this is the tail of a previous incomplete chunk
        ngx.log(ngx.DEBUG, "[ai-proxy] truncated sse frame tail")
        dat = fmt("%s%s", kong.ctx.plugin.truncated_frame, dat)
        kong.ctx.plugin.truncated_frame = nil
      end

      local s1, _ = str_find(dat, ":") -- find where the cut point is

      if s1 and s1 ~= 1 then
        local field = str_sub(dat, 1, s1-1) -- returns "data" from data: hello world
        local value = str_ltrim(str_sub(dat, s1+1)) -- returns "hello world" from data: hello world

        -- for now not checking if the value is already been set
        if     field == "event" then struct.event = value
        elseif field == "id"    then struct.id = value
        elseif field == "data"  then struct.data = value
        end -- if
      end -- if
    end
  end

  return events
end

function _M.to_ollama(request_table, model)
  local input = {}

  if request_table.prompt and request_table.messages then
    return kong.response.exit(400, "cannot run raw 'prompt' and chat history 'messages' requests at the same time - refer to schema")

  elseif request_table.messages then
    input.messages = request_table.messages

  elseif request_table.prompt then
    input.prompt = request_table.prompt

  end

  -- common parameters
  input.stream = request_table.stream or false -- for future capability
  input.model = model.name or request_table.name

  -- handle function calling translation from Ollama format
  input.tools = request_table.tools
  input.tool_choice = request_table.tool_choice

  if model.options then
    input.options = {}

    input.options.num_predict = request_table.max_tokens
    input.options.temperature = request_table.temperature
    input.options.top_p = request_table.top_p
    input.options.top_k = request_table.top_k
  end

  return input, "application/json", nil
end

function _M.from_ollama(response_string, model_info, route_type)
  local output, err, _, analytics

  if route_type == "stream/llm/v1/chat" then
    local response_table, err = cjson.decode(response_string.data)
    if err then
      return nil, "failed to decode ollama response"
    end

    output, _, analytics = handle_stream_event(response_table, model_info, route_type)

  elseif route_type == "stream/llm/v1/completions" then
    local response_table, err = cjson.decode(response_string.data)
    if err then
      return nil, "failed to decode ollama response"
    end

    output, _, analytics = handle_stream_event(response_table, model_info, route_type)

  else
    local response_table, err = cjson.decode(response_string)
    if err then
      return nil, "failed to decode ollama response"
    end

    -- there is no direct field indicating STOP reason, so calculate it manually
    local stop_length = (model_info.options and model_info.options.max_tokens) or -1
    local stop_reason = "stop"
    if response_table.eval_count and response_table.eval_count == stop_length then
      stop_reason = "length"
    end

    output = {}

    -- common fields
    output.model = response_table.model
    output.created = response_table.created_at

    -- analytics
    output.usage = {
      completion_tokens = response_table.eval_count or 0,
      prompt_tokens = response_table.prompt_eval_count or 0,
      total_tokens = (response_table.eval_count or 0) + 
                    (response_table.prompt_eval_count or 0),
    }

    if route_type == "llm/v1/chat" then
      output.object = "chat.completion"
      output.choices = {
        {
          finish_reason = response_table.finish_reason or stop_reason,
          index = 0,
          message = response_table.message,
        }
      }

    elseif route_type == "llm/v1/completions" then
      output.object = "text_completion"
      output.choices = {
        {
          index = 0,
          text = response_table.response,
        }
      }

    else
      return nil, "no ollama-format transformer for response type " .. route_type

    end
  end

  if output and output ~= _M._CONST.SSE_TERMINATOR then
    output, err = cjson.encode(output)
  end

  -- err maybe be nil from successful decode above
  return output, err, analytics
end

function _M.conf_from_request(kong_request, source, key)
  if source == "uri_captures" then
    return kong_request.get_uri_captures().named[key]
  elseif source == "headers" then
    return kong_request.get_header(key)
  elseif source == "query_params" then
    return kong_request.get_query_arg(key)
  else
    return nil, "source '" .. source .. "' is not supported"
  end
end


function _M.merge_model_options(kong_request, conf_m)
  if not conf_m then
    return
  end

  local err
  conf_m = cycle_aware_deep_copy(conf_m)
  conf_m.model = conf_m.model or {}

  -- handle model name
  local model_m = string_match(conf_m.model.name or "", '%$%((.-)%)')
  if model_m then
    local splitted = split(model_m, '.')
    if #splitted ~= 2 then
      return nil, "cannot parse expression for field 'model.name'"
    end

    -- find the request parameter, with the configured name
    model_m, err = _M.conf_from_request(kong_request, splitted[1], splitted[2])
    if err then
      return nil, err
    end
    if not model_m then
      return nil, "'" .. splitted[1] .. "', key '" .. splitted[2] .. "' was not provided"
    end

    -- replace the value
    conf_m.model.name = model_m
  end

  -- handle all other options
  for k, v in pairs(conf_m.model.options or {}) do
    if type(v) == "string" then
      local prop_m = string_match(v or "", '%$%((.-)%)')
      if prop_m then
        local splitted = split(prop_m, '.')
        if #splitted ~= 2 then
          return nil, "cannot parse expression for field '" .. v .. "'"
        end

        -- find the request parameter, with the configured name
        prop_m, err = _M.conf_from_request(kong_request, splitted[1], splitted[2])
        if err then
          return nil, err
        end
        if not prop_m then
          return nil, splitted[1] .. " key " .. splitted[2] .. " was not provided"
        end

        -- replace the value
        conf_m.model.options[k] = prop_m
      end
    end
  end

  return conf_m
end


-- used by llm/init.lua:ai_introspect_body only (transformer plugins)
function _M.pre_request(conf, request_table)
  -- process form/json body auth information
  local auth_param_name = conf.auth and conf.auth.param_name
  local auth_param_value = conf.auth and conf.auth.param_value
  local auth_param_location = conf.auth and conf.auth.param_location

  if auth_param_name and auth_param_value and auth_param_location == "body" and request_table then
    if request_table[auth_param_name] == nil or not conf.auth.allow_override then
      request_table[auth_param_name] = auth_param_value
    end
  end

  -- retrieve the plugin name
  local plugin_name = conf.__key__:match('plugins:(.-):')
  if not plugin_name or plugin_name == "" then
    return nil, "no plugin name is being passed by the plugin"
  end

  -- if enabled AND request type is compatible, capture the input for analytics
  if conf.logging and conf.logging.log_payloads then
    kong.log.set_serialize_value(fmt("ai.%s.%s.%s", plugin_name, log_entry_keys.PAYLOAD_CONTAINER, log_entry_keys.REQUEST_BODY), kong.request.get_raw_body())
  end

  local start_time_key = "ai_request_start_time_" .. plugin_name
  kong.ctx.plugin[start_time_key] = ngx.now()

  return true, nil
end

local function get_plugin_analytics_container(plugin_name)
  -- check if we already have analytics in this context
  local request_analytics = kong.ctx.shared.llm_request_analytics
  if not request_analytics then
    request_analytics = {}
    kong.ctx.shared.llm_request_analytics = request_analytics
  end

  request_analytics[plugin_name] = request_analytics[plugin_name] or {
    [log_entry_keys.META_CONTAINER] = {},
    [log_entry_keys.USAGE_CONTAINER] = {},
    [log_entry_keys.CACHE_CONTAINER] = {},
  }

  return request_analytics[plugin_name]
end

-- used by llm/init.lua:ai_introspect_body only (transformer plugins)
function _M.post_request(conf, response_object)
  local body_string, err

  if not response_object then
    return
  end

  if type(response_object) == "string" then
    -- set raw string body first, then decode
    body_string = response_object

    -- unpack the original response object for getting token and meta info
    response_object, err = cjson.decode(response_object)
    if err then
      return nil, "failed to decode LLM response from JSON"
    end
  else
    -- this has come from another AI subsystem, is already formatted, and contains "response" field
    body_string = response_object.response or "ERROR__NOT_SET"
  end

  local plugin_name = conf.__key__:match('plugins:(.-):')
  if not plugin_name or plugin_name == "" then
    return nil, "no plugin name is being passed by the plugin"
  end

  -- create or load exsiting a analytics structure for this plugin
  local request_analytics_plugin = get_plugin_analytics_container(plugin_name)

   -- Set meta data
  local meta_container = request_analytics_plugin[log_entry_keys.META_CONTAINER]
  meta_container[log_entry_keys.PLUGIN_ID] = conf.__plugin_id
  meta_container[log_entry_keys.PROVIDER_NAME] = conf.model.provider
  local model_t = ai_plugin_ctx.get_request_model_table_inuse()
  meta_container[log_entry_keys.REQUEST_MODEL] = model_t and model_t.name or "UNSPECIFIED"
  meta_container[log_entry_keys.RESPONSE_MODEL] = response_object.model or conf.model.name

  -- Set the llm latency meta, and time per token usage
  local start_time_key = "ai_request_start_time_" .. plugin_name
  if kong.ctx.plugin[start_time_key] then
    local llm_latency = math.floor((ngx.now() - kong.ctx.plugin[start_time_key]) * 1000)
    meta_container[log_entry_keys.LLM_LATENCY] = llm_latency

    if response_object.usage and response_object.usage.completion_tokens then
      local time_per_token = 0
      if response_object.usage.completion_tokens > 0 then
        time_per_token  = math.floor(llm_latency / response_object.usage.completion_tokens)
      end
      request_analytics_plugin[log_entry_keys.USAGE_CONTAINER][log_entry_keys.TIME_PER_TOKEN] = time_per_token
    end
  end

  -- set extra per-provider meta
  if kong.ctx.plugin.ai_extra_meta and type(kong.ctx.plugin.ai_extra_meta) == "table" then
    for k, v in pairs(kong.ctx.plugin.ai_extra_meta) do
      request_analytics_plugin[log_entry_keys.META_CONTAINER][k] = v
    end
  end

  -- Capture openai-format usage stats from the transformed response body
  if response_object.usage then
    if response_object.usage.prompt_tokens then
      request_analytics_plugin[log_entry_keys.USAGE_CONTAINER][log_entry_keys.PROMPT_TOKENS] = response_object.usage.prompt_tokens
    end
    if response_object.usage.completion_tokens then
      request_analytics_plugin[log_entry_keys.USAGE_CONTAINER][log_entry_keys.COMPLETION_TOKENS] = response_object.usage.completion_tokens
    end
    if response_object.usage.total_tokens then
      request_analytics_plugin[log_entry_keys.USAGE_CONTAINER][log_entry_keys.TOTAL_TOKENS] = response_object.usage.total_tokens
    end

    ai_plugin_o11y.metrics_set("llm_prompt_tokens_count", response_object.usage.prompt_tokens)
    ai_plugin_o11y.metrics_set("llm_completion_tokens_count", response_object.usage.completion_tokens)

    if response_object.usage.prompt_tokens and response_object.usage.completion_tokens and
       conf.model.options and conf.model.options.input_cost and conf.model.options.output_cost then
        local cost = (response_object.usage.prompt_tokens * conf.model.options.input_cost +
                      response_object.usage.completion_tokens * conf.model.options.output_cost) / 1000000 -- 1 million
        request_analytics_plugin[log_entry_keys.USAGE_CONTAINER][log_entry_keys.COST] = cost
        ai_plugin_o11y.metrics_set("llm_usage_cost", cost)
    end

  else
    -- log tokens response for reports and billing
    local response_tokens, err = _M.calculate_cost(response_object, {}, 1.0)
    if err then
      kong.log.warn("failed calculating cost for response tokens: ", err)
      response_tokens = 0
    end

    ai_plugin_o11y.metrics_set("llm_completion_tokens_count", response_tokens)
  end

  -- Log response body if logging payloads is enabled
  if conf.logging and conf.logging.log_payloads then
    kong.log.set_serialize_value(fmt("ai.%s.%s.%s", plugin_name, log_entry_keys.PAYLOAD_CONTAINER, log_entry_keys.RESPONSE_BODY), body_string)
  end

  -- Update context with changed values
  request_analytics_plugin[log_entry_keys.PAYLOAD_CONTAINER] = {
    [log_entry_keys.RESPONSE_BODY] = body_string,
  }

  if conf.logging and conf.logging.log_statistics then
    -- Log meta data
    kong.log.set_serialize_value(fmt("ai.%s.%s", plugin_name, log_entry_keys.META_CONTAINER),
      request_analytics_plugin[log_entry_keys.META_CONTAINER])

    -- Log usage data
    kong.log.set_serialize_value(fmt("ai.%s.%s", plugin_name, log_entry_keys.USAGE_CONTAINER),
      request_analytics_plugin[log_entry_keys.USAGE_CONTAINER])

    -- Log cache data
    kong.log.set_serialize_value(fmt("ai.%s.%s", plugin_name, log_entry_keys.CACHE_CONTAINER),
      request_analytics_plugin[log_entry_keys.CACHE_CONTAINER])
  end

  return true
end


function _M.http_request(url, body, method, headers, http_opts, buffered)
  local httpc = http.new()

  if http_opts.http_timeout then
    httpc:set_timeouts(http_opts.http_timeout)
  end

  if http_opts.proxy_opts then
    httpc:set_proxy_options(http_opts.proxy_opts)
  end

  local parsed = parse_url(url)

  if buffered then
    local ok, err, _ = httpc:connect({
      scheme = parsed.scheme,
      host = parsed.host,
      port = parsed.port or 443,  -- this always fails. experience.
      ssl_server_name = parsed.host,
      ssl_verify = http_opts.https_verify,
    })
    if not ok then
      return nil, err
    end

    local res, err = httpc:request({
        path = parsed.path or "/",
        query = parsed.query,
        method = method,
        headers = headers,
        body = body,
    })
    if not res then
      return nil, "connection failed: " .. err
    end

    return res, nil, httpc
  else
    -- 'single-shot'
    local res, err = httpc:request_uri(
      url,
      {
        method = method,
        body = body,
        headers = headers,
        ssl_verify = http_opts.https_verify,
      })
    if not res then
      return nil, "request failed: " .. err
    end

    return res, nil, nil
  end
end

-- Function to count the number of words in a string
local function count_words(any)
  local count = 0
  if type(any) == "string" then
    for _ in any:gmatch("%S+") do
      count = count + 1
    end
  elseif type(any) == "table" then -- is multi-modal input
    for _, item in ipairs(any) do
      if item.type == "text" and item.text then
        for _ in (item.text):gmatch("%S+") do
          count = count + 1
        end
      end
    end
  end
  return count
end

-- Function to count the number of words or tokens based on the content type
local function count_prompt(content, tokens_factor)
  local count = 0

  if type(content) == "string" then
    count = count_words(content) * tokens_factor
  elseif type(content) == "table" then
    for _, item in ipairs(content) do
      if type(item) == "string" then
        count = count + (count_words(item) * tokens_factor)
      elseif type(item) == "number" then
        count = count + 1
      elseif type(item) == "table" then
        for _2, item2 in ipairs(item) do
          if type(item2) == "number" then
            count = count + 1
          else
            return nil, "Invalid request format"
          end
        end
      else
          return nil, "Invalid request format"
      end
    end
  else 
    return nil, "Invalid request format"
  end
  return count, nil
end

function _M.calculate_cost(query_body, tokens_models, tokens_factor)
  local query_cost = 0
  local err

  if not query_body then
    return nil, "cannot calculate tokens on empty request"
  end

  if query_body.choices then
    -- Calculate the cost based on the content type
    for _, choice in ipairs(query_body.choices) do
      if choice.message and choice.message.content then 
        query_cost = query_cost + (count_words(choice.message.content) * tokens_factor)
      elseif choice.text then 
        query_cost = query_cost + (count_words(choice.text) * tokens_factor)
      end
    end
  elseif query_body.messages then
    -- Calculate the cost based on the content type
    for _, message in ipairs(query_body.messages) do
        query_cost = query_cost + (count_words(message.content) * tokens_factor)
    end
  elseif query_body.prompt then
    -- Calculate the cost based on the content type
    query_cost, err = count_prompt(query_body.prompt, tokens_factor)
    if err then
        return nil, err
    end
  end

  -- Round the total cost quantified
  query_cost = math.floor(query_cost + 0.5)

  return query_cost, nil
end

function _M.override_upstream_url(parsed_url, conf)
  if conf.route_type == "preserve" then
    -- if `upstream_path` was set, already processes before,
    -- for some provider, like azure and huggingface, the specific prefix need to prepended to the path.
    if conf.model.options and conf.model.options.upstream_path then
      return
    end
    parsed_url.path = kong.request.get_path()
  end
end

-- for unit tests
_M._count_words = count_words

return _M
