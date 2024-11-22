-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local utils = require "kong.enterprise_edition.debug_session.utils"
local kong_table = require "kong.tools.table"

local get_ctx_key = utils.get_ctx_key
local pack = kong_table.pack
local unpack = kong_table.unpack

local TOTAL_TIME_CTX_KEY = get_ctx_key("redis_total_time")

local _M = {}
local time_ns = require "kong.tools.time".time_ns

local ngx = ngx

local tracer
local instrum

local function initialized()
  return tracer ~= nil and instrum ~= nil
end

function _M.instrument()
  local redis = require("resty.redis")
  for method_name, _ in pairs(redis) do
    if type(redis[method_name]) ~= "function" then
      goto continue
    end

    local old_func = redis[method_name]
    redis[method_name] = function(self, ...)
      if not initialized() then
        return old_func(self, ...)
      end

      if not instrum.is_valid_phase() then
        return old_func(self, ...)
      end

      if instrum.should_skip_instrumentation(instrum.INSTRUMENTATIONS.io) then
        return old_func(self, ...)
      end

      local redis_io_span = tracer.start_span("kong.io.redis")
      local redis_timing_init = time_ns()

      local res = pack(old_func(self, ...))

      if not redis_io_span then
        return unpack(res)
      end

      -- Calculate the time spent in this Redis operation
      local elapsed = time_ns() - redis_timing_init
      -- set accumulated time or initialize
      ngx.ctx[TOTAL_TIME_CTX_KEY] = (ngx.ctx[TOTAL_TIME_CTX_KEY] or 0) + elapsed
      redis_io_span:finish()
      return unpack(res)
    end

    ::continue::
  end
end

function _M.init(opts)
  tracer = opts.tracer
  instrum = opts.instrum
end

-- retrieve the total accumulated Redis time in ms
function _M.get_total_time()
  return ngx.ctx[TOTAL_TIME_CTX_KEY] and ngx.ctx[TOTAL_TIME_CTX_KEY] / 1e6 or 0
end


return _M
