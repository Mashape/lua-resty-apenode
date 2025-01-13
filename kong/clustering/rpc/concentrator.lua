local _M = {}
local _MT = { __index = _M, }


local uuid = require("resty.jit-uuid")
local queue = require("kong.clustering.rpc.queue")
local cjson = require("cjson")
local jsonrpc = require("kong.clustering.rpc.json_rpc_v2")
local rpc_utils = require("kong.clustering.rpc.utils")
local isarray = require("table.isarray")
local isempty = require("table.isempty")
local tb_insert = table.insert


local type = type
local setmetatable = setmetatable
local tostring = tostring
local pcall = pcall
local assert = assert
local string_format = string.format
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local exiting = ngx.worker.exiting
local is_timeout = rpc_utils.is_timeout
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_DEBUG = ngx.DEBUG
local new_error = jsonrpc.new_error


local RESP_CHANNEL_PREFIX = "rpc:resp:" -- format: rpc:resp:<worker_uuid>
local REQ_CHANNEL_PREFIX = "rpc:req:" -- format: rpc:req:<dst_node_id>


local RPC_REQUEST_ENQUEUE_SQL = [[
BEGIN;
  INSERT INTO clustering_rpc_requests (
    "node_id",
    "reply_to",
    "ttl",
    "payload"
  ) VALUES (
    %s,
    %s,
    CURRENT_TIMESTAMP(3) AT TIME ZONE 'UTC' + INTERVAL '%d second',
    %s
  );
  SELECT pg_notify(%s, NULL);
COMMIT;
]]


local RPC_REQUEST_DEQUEUE_SQL = [[
BEGIN;
  DELETE FROM
    clustering_rpc_requests
    USING (
      SELECT * FROM clustering_rpc_requests WHERE node_id = %s FOR UPDATE SKIP LOCKED
    ) q
    WHERE q.id = clustering_rpc_requests.id RETURNING clustering_rpc_requests.*;
COMMIT;
]]


function _M.new(manager, db)
  local self = {
    manager = manager,
    db = db,
    interest = {}, -- id: callback pair
    sub_unsub = queue.new(4096), -- pub/sub event queue, executed on the read thread
    sequence = 0,
  }

  return setmetatable(self, _MT)
end


function _M:_get_next_id()
  local res = self.sequence
  self.sequence = res + 1

  return res
end


local function enqueue_notifications(notifications, notifications_queue)
  assert(notifications_queue)

  if notifications then
    for _, n in ipairs(notifications) do
      assert(notifications_queue:push(n))
    end
  end
end


function _M:process_one_response(payload)
  assert(payload.jsonrpc == jsonrpc.VERSION)
  local payload_id = payload.id

  -- response
  local cb = self.interest[payload_id]
  self.interest[payload_id] = nil -- edge trigger only once

  if not cb then
    ngx_log(ngx_WARN, "[rpc] no interest for concentrator response id: ", payload_id, ", dropping it")
    return
  end

  local res, err = cb(payload)
  if not res then
    ngx_log(ngx_WARN, "[rpc] concentrator response interest handler failed: id: ",
            payload_id, ", err: ", err)
  end
end


function _M:process_one_request(target_id, reply_to, payload, collection)
  if type(payload) ~= "table" then
    local res, err = self:_enqueue_rpc_response(
                      reply_to,
                      new_error(nil, jsonrpc.INVALID_REQUEST, "not an valid object"),
                      collection)
    if not res then
      ngx_log(ngx_WARN, "[rpc] unable to enqueue RPC error: ", err)
    end

    return
  end

  local payload_id = payload.id

  local res, err = self.manager:_local_call(target_id, payload.method,
                                            payload.params, not payload_id)

  -- notification has no callback or id
  if not payload_id then
    ngx_log(ngx_DEBUG, "[rpc] notification has no response")
    return
  end

  if res then
    -- call success
    res, err = self:_enqueue_rpc_response(reply_to, {
      jsonrpc = jsonrpc.VERSION,
      id = payload_id,
      result = res,
    }, collection)
    if not res then
      ngx_log(ngx_WARN, "[rpc] unable to enqueue RPC call result: ", err)
    end

  else
    -- call failure
    res, err = self:_enqueue_rpc_response(reply_to, {
      jsonrpc = jsonrpc.VERSION,
      id = payload_id,
      error = {
        code = jsonrpc.SERVER_ERROR,
        message = tostring(err),
      }
    }, collection)
    if not res then
      ngx_log(ngx_WARN, "[rpc] unable to enqueue RPC error: ", err)
    end
  end
end


function _M:_event_loop(lconn)
  local notifications_queue = queue.new(4096)
  local rpc_resp_channel_name = RESP_CHANNEL_PREFIX .. self.worker_id

  -- we always subscribe to our worker's receiving channel first
  local res, err = lconn:query('LISTEN "' .. rpc_resp_channel_name .. '";')
  if not res then
    return nil, "unable to subscribe to concentrator response channel: " .. err
  end

  while not exiting() do
    while true do
      local n, err = notifications_queue:pop(0)
      if not n then
        if err then
          return nil, "unable to pop from notifications queue: " .. err
        end

        break
      end

      assert(n.operation == "notification")

      if n.channel == rpc_resp_channel_name then
        -- an response for a previous RPC call we asked for
        local payload = cjson_decode(n.payload)

        if not isarray(payload) then
          -- one rpc response
          self:process_one_response(payload)

        else
          -- batch rpc response
          for _, v in ipairs(payload) do
            self:process_one_response(v)
          end
        end

      else
        -- other CP inside the cluster asked us to forward a call
        assert(n.channel:sub(1, #REQ_CHANNEL_PREFIX) == REQ_CHANNEL_PREFIX,
               "unexpected concentrator request channel name: " .. n.channel)

        local target_id = n.channel:sub(#REQ_CHANNEL_PREFIX + 1)
        local sql = string_format(RPC_REQUEST_DEQUEUE_SQL, self.db.connector:escape_literal(target_id))
        local calls, err = self.db.connector:query(sql)
        if not calls then
          return nil, "concentrator request dequeue query failed: " .. err
        end

        assert(calls[1] == true)
        ngx_log(ngx_DEBUG, "concentrator got ", calls[2].affected_rows,
                " calls from database for node ", target_id)
        for _, call in ipairs(calls[2]) do
          local payload = assert(call.payload)
          local reply_to = assert(call.reply_to,
                                  "unknown requester for RPC")

          if not isarray(payload) then
            -- one rpc call
            self:process_one_request(target_id, reply_to, payload)

            goto continue
          end

          -- rpc call with an empty Array
          if isempty(payload) then
            local res, err = self:_enqueue_rpc_response(
                              reply_to,
                              new_error(nil, jsonrpc.INVALID_REQUEST, "empty batch array"))
            if not res then
              ngx_log(ngx_WARN, "[rpc] unable to enqueue RPC error: ", err)
            end

            goto continue
          end

          -- batching rpc call

          local collection = {}

          for _, v in ipairs(payload) do
            self:process_one_request(target_id, reply_to, v, collection)
          end

          if not isempty(collection) then
            local res, err = self:_enqueue_rpc_response(reply_to, collection)
            if not res then
              ngx_log(ngx_WARN, "[rpc] unable to enqueue RPC call result: ", err)
            end
          end

          ::continue::
        end -- for _, call
      end -- if n.channel == rpc_resp_channel_name
    end -- while true

    local res, err = lconn:wait_for_notification()
    if not res then
      if not is_timeout(err) then
        return nil, "wait_for_notification error: " .. err
      end

      repeat
        local sql, err = self.sub_unsub:pop(0)
        if err then
          return nil, err
        end

        local _, notifications
        res, err, _, notifications = lconn:query(sql or "SELECT 1;") -- keepalive
        if not res then
          return nil, "query to Postgres failed: " .. err
        end

        enqueue_notifications(notifications, notifications_queue)
      until not sql

    else
      notifications_queue:push(res)
    end
  end -- while not exiting()
end


function _M:start(delay)
  if not self.worker_id then
    -- this can not be generated inside `:new()` as ngx.worker.id()
    -- does not yet exist there and can only be generated inside
    -- init_worker phase
    self.worker_id = uuid.generate_v5(kong.node.get_id(),
                                      tostring(ngx.worker.id()))
  end

  assert(ngx.timer.at(delay or 0, function(premature)
    if premature then
      return
    end

    local lconn = self.db.connector:connect("write")
    lconn:settimeout(1000)
    self.db.connector:store_connection(nil, "write")

    local _, res_or_perr, err = pcall(self._event_loop, self, lconn)
    -- _event_loop never returns true
    local delay = math.random(5, 10)

    ngx_log(ngx_ERR, "[rpc] concentrator event loop error: ",
            res_or_perr or err, ", reconnecting in ",
            math.floor(delay), " seconds")

    local res, err = lconn:disconnect()
    if not res then
      ngx_log(ngx_ERR, "[rpc] unable to close postgres connection: ", err)
    end

    self:start(delay)
  end))
end


-- enqueue a RPC request to DP node with ID node_id
function _M:_enqueue_rpc_request(node_id, payload)
  local sql = string_format(RPC_REQUEST_ENQUEUE_SQL,
                            self.db.connector:escape_literal(node_id),
                            self.db.connector:escape_literal(self.worker_id),
                            5,
                            self.db.connector:escape_literal(cjson_encode(payload)),
                            self.db.connector:escape_literal(REQ_CHANNEL_PREFIX .. node_id))
  return self.db.connector:query(sql)
end


-- enqueue a RPC response from CP worker with ID worker_id
-- collection is only for rpc batch call.
-- if collection is nil, it means the rpc is a single call.
function _M:_enqueue_rpc_response(worker_id, payload, collection)
  if collection then
    tb_insert(collection, payload)
    return
  end

  local sql = string_format("SELECT pg_notify(%s, %s);",
                            self.db.connector:escape_literal(RESP_CHANNEL_PREFIX .. worker_id),
                            self.db.connector:escape_literal(cjson_encode(payload)))
  return self.db.connector:query(sql)
end


-- subscribe to RPC calls for worker with ID node_id
function _M:_enqueue_subscribe(node_id)
  return self.sub_unsub:push('LISTEN "' .. REQ_CHANNEL_PREFIX .. node_id .. '";')
end


-- unsubscribe to RPC calls for worker with ID node_id
function _M:_enqueue_unsubscribe(node_id)
  return self.sub_unsub:push('UNLISTEN "' .. REQ_CHANNEL_PREFIX .. node_id .. '";')
end


-- asynchronously start executing a RPC, node_id is
-- needed for this implementation, because all nodes
-- over concentrator shares the same "socket" object
-- This way the manager code wouldn't tell the difference
-- between calls made over WebSocket or concentrator
function _M:call(node_id, method, params, callback)
  local id

  -- notification has no callback or id
  if callback then
    id = self:_get_next_id()
    self.interest[id] = callback
  end

  return self:_enqueue_rpc_request(node_id, {
    jsonrpc = jsonrpc.VERSION,
    method = method,
    params = params,
    id = id,
  })
end


return _M
