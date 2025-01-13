-- socket represents an open WebSocket connection
-- unlike the WebSocket object, it can be accessed via different requests
-- with the help of semaphores


local _M = {}
local _MT = { __index = _M, }


local utils = require("kong.clustering.rpc.utils")
local queue = require("kong.clustering.rpc.queue")
local jsonrpc = require("kong.clustering.rpc.json_rpc_v2")
local constants = require("kong.constants")
local isarray = require("table.isarray")
local isempty = require("table.isempty")
local tb_clear = require("table.clear")
local tb_insert = table.insert


local type = type
local assert = assert
local unpack = unpack
local string_format = string.format
local kong = kong
local is_timeout = utils.is_timeout
local compress_payload = utils.compress_payload
local decompress_payload = utils.decompress_payload
local exiting = ngx.worker.exiting
local ngx_time = ngx.time
local ngx_log = ngx.log
local new_error = jsonrpc.new_error


local CLUSTERING_PING_INTERVAL = constants.CLUSTERING_PING_INTERVAL
local PING_WAIT = CLUSTERING_PING_INTERVAL * 1.5
local PING_TYPE = "PING"
local PONG_TYPE = "PONG"
local ngx_WARN = ngx.WARN
local ngx_DEBUG = ngx.DEBUG


-- create a new socket wrapper, wb is the WebSocket object to use
-- timeout and max_payload_len must already been set by caller when
-- creating the `wb` object
function _M.new(manager, wb, node_id)
  local self = {
    wb = wb,
    interest = {}, -- id: callback pair
    outgoing = queue.new(4096), -- write queue
    manager = manager,
    node_id = node_id,
    sequence = 0,
  }

  return setmetatable(self, _MT)
end


function _M:_get_next_id()
  local res = self.sequence
  self.sequence = res + 1

  return res
end


function _M:push_request(msg)
  return self.outgoing:push(msg)
end


-- collection is only for rpc batch call.
-- if collection is nil, it means the rpc is a single call.
function _M:push_response(msg, err_prefix, collection)
  -- may be a batch
  if collection then
    tb_insert(collection, msg)
    return true
  end

  local res, err = self.outgoing:push(msg)
  if not res then
    return nil, err_prefix .. err
  end

  return true
end


function _M._dispatch(premature, self, cb, payload, collection)
  if premature then
    return
  end

  local res, err = cb(self.node_id, unpack(payload.params))
  if not res then
    ngx_log(ngx_WARN, "[rpc] RPC callback failed: ", err)

    -- notification has no response
    if not payload.id then
      return
    end

    res, err = self:push_response(new_error(payload.id, jsonrpc.SERVER_ERROR, err),
                                  "[rpc] unable to push RPC call error: ",
                                  collection)
    if not res then
      ngx_log(ngx_WARN, err)
    end

    return
  end

  -- notification has no response
  if not payload.id then
    ngx_log(ngx_DEBUG, "[rpc] notification has no response")
    return
  end

  -- success
  res, err = self:push_response({
    jsonrpc = jsonrpc.VERSION,
    id = payload.id,
    result = res,
  }, "[rpc] unable to push RPC call result: ", collection)
  if not res then
    ngx_log(ngx_WARN, err)
  end
end


function _M:process_rpc_msg(payload, collection)
  if type(payload) ~= "table" then
    local res, err = self:push_response(
                      new_error(nil, jsonrpc.INVALID_REQUEST, "not a valid object"),
                      collection)
    if not res then
      return nil, err
    end

    return true
  end

  assert(payload.jsonrpc == jsonrpc.VERSION)

  local payload_id = payload.id
  local payload_method = payload.method

  if payload_method then
    -- invoke

    ngx_log(ngx_DEBUG, "[rpc] got RPC call: ", payload_method, " (id: ", payload_id, ")")

    local dispatch_cb = self.manager.callbacks.callbacks[payload_method]
    if not dispatch_cb and payload_id then
      local res, err = self:push_response(new_error(payload_id, jsonrpc.METHOD_NOT_FOUND),
                                          "unable to send \"METHOD_NOT_FOUND\" error back to client: ",
                                          collection)
      if not res then
        return nil, err
      end

      return true
    end

    local res, err

    -- call dispatch

    if collection then

      -- TODO: async call by using a new manager of timer
      -- collection is not nil, it means it is a batch call
      -- we should call sync function
      _M._dispatch(nil, self, dispatch_cb, payload, collection)

    else

      -- collection is nil, it means it is a single call
      -- we should call async function
      local name = string_format("JSON-RPC callback for node_id: %s, id: %d, method: %s",
                                 self.node_id, payload_id or 0, payload_method)
      res, err = kong.timer:named_at(name, 0, _M._dispatch, self, dispatch_cb, payload)

      if not res and payload_id then
        local reso, erro = self:push_response(new_error(payload_id, jsonrpc.INTERNAL_ERROR),
                                              "unable to send \"INTERNAL_ERROR\" error back to client: ",
                                              collection)
        if not reso then
          return nil, erro
        end

        return nil, "unable to dispatch JSON-RPC callback: " .. err
      end
    end

  else
    -- response, don't care about `collection`
    local interest_cb = self.interest[payload_id]
    self.interest[payload_id] = nil -- edge trigger only once

    if not interest_cb then
      ngx_log(ngx_WARN, "[rpc] no interest for RPC response id: ", payload_id, ", dropping it")

      return true
    end

    local res, err = interest_cb(payload)
    if not res then
      ngx_log(ngx_WARN, "[rpc] RPC response interest handler failed: id: ",
              payload_id, ", err: ", err)
    end
  end -- if payload.method

  return true
end


-- start reader and writer thread and event loop
function _M:start()
  self.read_thread = ngx.thread.spawn(function()
    local last_seen = ngx_time()

    while not exiting() do
      local data, typ, err = self.wb:recv_frame()

      if err then
        if not is_timeout(err) then
          return nil, err
        end

        local waited = ngx_time() - last_seen
        if waited > PING_WAIT then
          return nil, "did not receive ping frame from other end within " ..
                      PING_WAIT .. " seconds"
        end

        if waited > CLUSTERING_PING_INTERVAL then
          local res, err = self:push_response(PING_TYPE, "unable to send ping: ")
          if not res then
            return nil, err
          end
        end

        -- timeout
        goto continue
      end

      last_seen = ngx_time()

      if typ == "ping" then
        local res, err = self:push_response(PONG_TYPE, "unable to handle ping: ")
        if not res then
          return nil, err
        end

        goto continue
      end

      if typ == "pong" then
        ngx_log(ngx_DEBUG, "[rpc] got PONG frame")

        goto continue
      end

      if typ == "close" then
        return true
      end

      assert(typ == "binary")

      local payload = decompress_payload(data)

      -- single rpc call
      if not isarray(payload) then
        local ok, err = self:process_rpc_msg(payload)
        if not ok then
          return nil, err
        end

        goto continue
      end

      -- rpc call with an empty array
      if isempty(payload) then
        local res, err = self:push_response(
                          new_error(nil, jsonrpc.INVALID_REQUEST, "empty batch array"))
        if not res then
          return nil, err
        end

        goto continue
      end

      -- batch rpc call

      local collection = {}

      ngx_log(ngx_DEBUG, "[rpc] got batch RPC call: ", #payload)

      for _, v in ipairs(payload) do
        local ok, err = self:process_rpc_msg(v, collection)
        if not ok then
          return nil, err
        end
      end

      -- may be responses or all notifications
      if isempty(collection) then
        goto continue
      end

      assert(isarray(collection))

      local res, err = self:push_response(collection,
                                          "[rpc] unable to push RPC call result: ")
      if not res then
        return nil, err
      end

      ::continue::
    end
  end)

  self.write_thread = ngx.thread.spawn(function()
    local batch_requests = {}

    while not exiting() do
      -- 0.5 seconds for not waiting too long
      local payload, err = self.outgoing:pop(0.5)
      if err then
        return nil, err
      end

      -- timeout
      if not payload then
        local n = #batch_requests
        if n > 0 then
          local bytes, err = self.wb:send_binary(compress_payload(batch_requests))
          if not bytes then
            return nil, err
          end

          ngx_log(ngx_DEBUG, "[rpc] sent batch RPC call: ", n)

          tb_clear(batch_requests)
        end
        goto continue
      end

      if payload == PING_TYPE then
        local _, err = self.wb:send_ping()
        if err then
          return nil, "failed to send PING frame to peer: " .. err

        else
          ngx_log(ngx_DEBUG, "[rpc] sent PING frame to peer")
        end
        goto continue
      end

      if payload == PONG_TYPE then
        local _, err = self.wb:send_pong()
        if err then
          return nil, "failed to send PONG frame to peer: " .. err

        else
          ngx_log(ngx_DEBUG, "[rpc] sent PONG frame to peer")
        end
        goto continue
      end

      assert(type(payload) == "table")

      -- batch enabled
      local batch_size = self.manager.batch_size

      if batch_size > 0 then
        tb_insert(batch_requests, payload)

        -- send batch requests
        local n = #batch_requests
        if n >= batch_size then
          local bytes, err = self.wb:send_binary(compress_payload(batch_requests))
          if not bytes then
            return nil, err
          end

          ngx_log(ngx_DEBUG, "[rpc] sent batch RPC call: ", n)

          tb_clear(batch_requests)
        end
        goto continue
      end

      local bytes, err = self.wb:send_binary(compress_payload(payload))
      if not bytes then
        return nil, err
      end

      ::continue::
    end
  end)
end


function _M:join()
  local ok, err, perr = ngx.thread.wait(self.write_thread, self.read_thread)
  self:stop()

  if not ok then
    return nil, err
  end

  if perr then
    return nil, perr
  end

  return true
end


function _M:stop()
  ngx.thread.kill(self.write_thread)
  ngx.thread.kill(self.read_thread)

  if self.wb.close then
    self.wb:close()

  else
    self.wb:send_close()
  end
end


-- asynchronously start executing a RPC, _node_id is not
-- needed for this implementation, but it is important
-- for concentrator socket, so we include it just to keep
-- the signature consistent
function _M:call(node_id, method, params, callback)
  assert(node_id == self.node_id)

  local id

  -- notification has no callback or id
  if callback then
    id = self:_get_next_id()
    self.interest[id] = callback
  end

  return self:push_request({
    jsonrpc = jsonrpc.VERSION,
    method = method,
    params = params,
    id = id,
  })
end


return _M
