local _M = {}
local _MT = { __index = _M, }


local server = require("resty.websocket.server")
local client = require("resty.websocket.client")
local socket = require("kong.clustering.rpc.socket")
local future = require("kong.clustering.rpc.future")
local utils = require("kong.clustering.rpc.utils")
local jsonrpc = require("kong.clustering.rpc.json_rpc_v2")
local callbacks = require("kong.clustering.rpc.callbacks")
local clustering_tls = require("kong.clustering.tls")
local constants = require("kong.constants")
local table_isempty = require("table.isempty")
local pl_tablex = require("pl.tablex")
local cjson = require("cjson.safe")
local string_tools = require("kong.tools.string")


local ipairs = ipairs
local ngx_var = ngx.var
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local ngx_time = ngx.time
local exiting = ngx.worker.exiting
local pl_tablex_makeset = pl_tablex.makeset
local cjson_encode = cjson.encode
local cjson_decode = cjson.decode
local validate_client_cert = clustering_tls.validate_client_cert
local CLUSTERING_PING_INTERVAL = constants.CLUSTERING_PING_INTERVAL
local parse_proxy_url = require("kong.clustering.utils").parse_proxy_url


local _log_prefix = "[rpc] "
local RPC_MATA_V1 = "kong.meta.v1"
local RPC_SNAPPY_FRAMED = "x-snappy-framed"


local WS_OPTS = {
  timeout = constants.CLUSTERING_TIMEOUT,
  max_payload_len = kong.configuration.cluster_max_payload,
}
local KONG_VERSION = kong.version


-- create a new RPC manager, node_id is own node_id
function _M.new(conf, node_id)
  local self = {
    -- clients[node_id]: { socket1 => true, socket2 => true, ... }
    clients = {},
    client_capabilities = {},
    node_id = node_id,
    conf = conf,
    cluster_cert = assert(clustering_tls.get_cluster_cert(conf)),
    cluster_cert_key = assert(clustering_tls.get_cluster_cert_key(conf)),
    callbacks = callbacks.new(),

    batch_size = 0,  -- rpc batching
  }

  if conf.role == "control_plane" then
    self.concentrator = require("kong.clustering.rpc.concentrator").new(self, kong.db)
    self.client_info = {}  -- store DP node's ip addr and version
  end

  return setmetatable(self, _MT)
end


function _M:_add_socket(socket)
  local node_id = socket.node_id

  local sockets = self.clients[node_id]
  if not sockets then
    if self.concentrator then
      assert(self.concentrator:_enqueue_subscribe(node_id))
    end

    sockets = setmetatable({}, { __mode = "k", })
    self.clients[node_id] = sockets
  end

  assert(not sockets[socket])

  sockets[socket] = true
end


function _M:_remove_socket(socket)
  local node_id = socket.node_id
  local sockets = assert(self.clients[node_id])

  assert(sockets[socket])

  sockets[socket] = nil

  if table_isempty(sockets) then
    self.clients[node_id] = nil
    self.client_capabilities[node_id] = nil

    if self.concentrator then
      self.client_info[node_id] = nil
      assert(self.concentrator:_enqueue_unsubscribe(node_id))
    end
  end
end


-- Helper that finds a node by node_id and check
-- if capability is supported
-- Returns: "local" if found locally,
-- or "concentrator" if found from the concentrator
-- In case of error, return nil, err instead
function _M:_find_node_and_check_capability(node_id, cap)
  if self.client_capabilities[node_id] then
    if not self.client_capabilities[node_id].set[cap] then
      return nil, "requested capability does not exist, capability: " ..
                  cap .. ", node_id: " .. node_id
    end

    return "local"
  end

  -- now we are on cp side
  assert(self.concentrator)

  -- does concentrator knows more about this client?
  local res, err = kong.db.clustering_data_planes:select({ id = node_id })
  if err then
    return nil, "unable to query concentrator " .. err
  end

  if not res or ngx_time() - res.last_seen > CLUSTERING_PING_INTERVAL * 2 then
    return nil, "node is not connected, node_id: " .. node_id
  end

  for _, c in ipairs(res.rpc_capabilities) do
    if c == cap then
      return "concentrator"
    end
  end

  return nil, "requested capability does not exist, capability: " ..
              cap .. ", node_id: " .. node_id
end


-- CP => DP
function _M:_handle_meta_call(c, cert)
  local data, typ, err = c:recv_frame()
  if err then
    return nil, err
  end

  if typ ~= "binary" then
    return nil, "wrong frame type: " .. type
  end

  local payload = cjson_decode(data)
  assert(payload.jsonrpc == jsonrpc.VERSION)

  if payload.method ~= RPC_MATA_V1 .. ".hello" then
    return nil, "wrong RPC meta call: " .. tostring(payload.method)
  end

  local info = payload.params[1]

  local snappy_supported
  for _, v in ipairs(info.rpc_frame_encodings) do
    if v == RPC_SNAPPY_FRAMED then
      snappy_supported = true
      break
    end
  end

  if not snappy_supported then
    return nil, "unknown encodings: " .. cjson_encode(info.rpc_frame_encodings)
  end

  -- should have necessary info
  assert(type(info.kong_version) == "string")
  assert(type(info.kong_node_id) == "string")
  assert(type(info.kong_hostname) == "string")
  assert(type(info.kong_conf) == "table")

  local payload = {
    jsonrpc = jsonrpc.VERSION,
    result = {
      rpc_capabilities = self.callbacks:get_capabilities_list(),
      -- now we only support snappy
      rpc_frame_encoding = RPC_SNAPPY_FRAMED,
      },
    id = 1,
  }

  local bytes, err = c:send_binary(cjson_encode(payload))
  if not bytes then
    return nil, err
  end

  local capabilities_list = info.rpc_capabilities
  local node_id = info.kong_node_id

  -- we already set this dp node
  if self.client_capabilities[node_id] then
    return node_id
  end

  self.client_capabilities[node_id] = {
    set = pl_tablex_makeset(capabilities_list),
    list = capabilities_list,
  }

  -- we are on cp side
  assert(self.concentrator)
  assert(self.client_info)

  -- see communicate() in data_plane.lua
  local labels do
    if info.kong_conf.cluster_dp_labels then
      labels = {}
      for _, lab in ipairs(info.kong_conf.cluster_dp_labels) do
        local del = lab:find(":", 1, true)
        labels[lab:sub(1, del - 1)] = lab:sub(del + 1)
      end
    end
  end

  -- values in cert_details must be strings
  local cert_details = {
    expiry_timestamp = cert:get_not_after(),
  }

  -- store DP's ip addr
  self.client_info[node_id] = {
    ip = ngx_var.remote_addr,
    version = info.kong_version,
    labels = labels,
    cert_details = cert_details,
  }

  return node_id
end


-- DP => CP
function _M:_meta_call(c, meta_cap, node_id)
  local info = {
    rpc_capabilities = self.callbacks:get_capabilities_list(),

    -- now we only support snappy
    rpc_frame_encodings =  { RPC_SNAPPY_FRAMED, },

    kong_version = KONG_VERSION,
    kong_hostname = kong.node.get_hostname(),
    kong_node_id = self.node_id,
    kong_conf = kong.configuration.remove_sensitive(),
  }

  local payload = {
    jsonrpc = jsonrpc.VERSION,
    method = meta_cap .. ".hello",
    params = { info },
    id = 1,
  }

  local bytes, err = c:send_binary(cjson_encode(payload))
  if not bytes then
    return nil, err
  end

  local data, typ, err = c:recv_frame()
  if err then
    return nil, err
  end

  if typ ~= "binary" then
    return nil, "wrong frame type: " .. typ
  end

  local payload = cjson_decode(data)
  assert(payload.jsonrpc == jsonrpc.VERSION)

  -- now we only support snappy
  if payload.result.rpc_frame_encoding ~= RPC_SNAPPY_FRAMED then
    return nil, "unknown encoding: " .. payload.result.rpc_frame_encoding
  end

  local capabilities_list = payload.result.rpc_capabilities

  self.client_capabilities[node_id] = {
    set = pl_tablex_makeset(capabilities_list),
    list = capabilities_list,
  }

  -- tell outside that rpc is ready
  local worker_events = assert(kong.worker_events)

  -- notify this worker
  local ok, err = worker_events.post_local("clustering:jsonrpc", "connected",
                                           capabilities_list)
  if not ok then
    ngx_log(ngx_ERR, _log_prefix, "unable to post rpc connected event: ", err)
  end

  return true
end


-- low level helper used internally by :call() and concentrator
-- this one does not consider forwarding using concentrator
-- when node does not exist
function _M:_local_call(node_id, method, params, is_notification)
  if not self.client_capabilities[node_id] then
    return nil, "node is not connected, node_id: " .. node_id
  end

  local cap = utils.parse_method_name(method)
  if not self.client_capabilities[node_id].set[cap] then
    return nil, "requested capability does not exist, capability: " ..
                cap .. ", node_id: " .. node_id
  end

  local s = next(self.clients[node_id]) -- TODO: better LB?

  local fut = future.new(node_id, s, method, params, is_notification)
  assert(fut:start())

  -- notification need not to wait
  if is_notification then
    return true
  end

  local ok, err = fut:wait(5)
  if err then
    return nil, err
  end

  if ok then
    return fut.result
  end

  return nil, fut.error.message
end


function _M:_call_or_notify(is_notification, node_id, method, ...)
  local cap = utils.parse_method_name(method)

  local res, err = self:_find_node_and_check_capability(node_id, cap)
  if not res then
    return nil, err
  end

  local params = {...}

  ngx_log(ngx_DEBUG,
    _log_prefix,
    is_notification and "notifying " or "calling ",
    method,
    "(node_id: ", node_id, ")",
    " via ", res == "local" and "local" or "concentrator"
  )

  if res == "local" then
    res, err = self:_local_call(node_id, method, params, is_notification)

    if not res then
      ngx_log(ngx_DEBUG, _log_prefix, method, " failed, err: ", err)
      return nil, err
    end

    ngx_log(ngx_DEBUG, _log_prefix, method, " succeeded")

    return res
  end

  assert(res == "concentrator")

  -- try concentrator
  local fut = future.new(node_id, self.concentrator, method, params, is_notification)
  assert(fut:start())

  if is_notification then
    return true
  end

  local ok, err = fut:wait(5)

  if err then
    ngx_log(ngx_DEBUG, _log_prefix, method, " failed, err: ", err)

    return nil, err
  end

  if ok then
    ngx_log(ngx_DEBUG, _log_prefix, method, " succeeded")

    return fut.result
  end

  ngx_log(ngx_DEBUG, _log_prefix, method, " failed, err: ", fut.error.message)

  return nil, fut.error.message
end


-- public interface, try call on node_id locally first,
-- if node is not connected, try concentrator next
function _M:call(node_id, method, ...)
  return self:_call_or_notify(false, node_id, method, ...)
end


function _M:notify(node_id, method, ...)
  return self:_call_or_notify(true, node_id, method, ...)
end


-- handle incoming client connections
function _M:handle_websocket()
  local rpc_protocol = ngx_var.http_sec_websocket_protocol

  local meta_v1_supported
  local protocols = string_tools.split(rpc_protocol, ",")

  -- choice a proper protocol
  for _, v in ipairs(protocols) do
    -- now we only support kong.meta.v1
    if RPC_MATA_V1 == string_tools.strip(v) then
      meta_v1_supported = true
      break
    end
  end

  if not meta_v1_supported then
    ngx_log(ngx_ERR, _log_prefix, "unknown RPC protocol: " ..
                     tostring(rpc_protocol) ..
                     ", doesn't know how to communicate with client")
    return ngx_exit(ngx.HTTP_CLOSE)
  end

  local cert, err = validate_client_cert(self.conf, self.cluster_cert, ngx_var.ssl_client_raw_cert)
  if not cert then
    ngx_log(ngx_ERR, _log_prefix, "client's certificate failed validation: ", err)
    return ngx_exit(ngx.HTTP_CLOSE)
  end

  -- now we only use kong.meta.v1
  ngx.header["Sec-WebSocket-Protocol"] = RPC_MATA_V1

  local wb, err = server:new(WS_OPTS)
  if not wb then
    ngx_log(ngx_ERR, _log_prefix, "unable to establish WebSocket connection with client: ", err)
    return ngx_exit(ngx.HTTP_CLOSE)
  end

  -- if timeout (default is 5s) we will close the connection
  local node_id, err = self:_handle_meta_call(wb, cert)
  if not node_id then
    ngx_log(ngx_ERR, _log_prefix, "unable to handshake with client: ", err)
    return ngx_exit(ngx.HTTP_CLOSE)
  end

  local s = socket.new(self, wb, node_id)
  self:_add_socket(s)

  s:start()
  local res, err = s:join()
  self:_remove_socket(s)

  -- tell outside that rpc disconnected
  do
    local worker_events = assert(kong.worker_events)

    -- notify this worker
    local ok, err = worker_events.post_local("clustering:jsonrpc", "disconnected")
    if not ok then
      ngx_log(ngx_ERR, _log_prefix, "unable to post rpc disconnected event: ", err)
    end
  end

  if not res then
    ngx_log(ngx_ERR, _log_prefix, "RPC connection broken: ", err, " node_id: ", node_id)
    return ngx_exit(ngx.ERROR)
  end

  return ngx_exit(ngx.OK)
end


function _M:try_connect(reconnection_delay)
  ngx.timer.at(reconnection_delay or 0, function(premature)
    self:connect(premature,
                 "control_plane", -- node_id
                 self.conf.cluster_control_plane, -- host
                 "/v2/outlet",  -- path
                 self.cluster_cert.cdata,
                 self.cluster_cert_key)
  end)
end


function _M:init_worker()
  if self.conf.role == "data_plane" then
    -- data_plane will try to connect to cp
    self:try_connect()

  else
    -- control_plane
    self.concentrator:start()
  end
end


function _M:connect(premature, node_id, host, path, cert, key)
  if premature then
    return
  end

  local uri = "wss://" .. host .. path

  local opts = {
    ssl_verify = true,
    client_cert = cert,
    client_priv_key = key,
    protocols = RPC_MATA_V1,
  }

  if self.conf.cluster_mtls == "shared" then
    opts.server_name = "kong_clustering"

  else
    -- server_name will be set to the host if it is not explicitly defined here
    if self.conf.cluster_server_name ~= "" then
      opts.server_name = self.conf.cluster_server_name
    end
  end

  local reconnection_delay = math.random(5, 10)

  local c = assert(client:new(WS_OPTS))

  if self.conf.cluster_use_proxy then
    local proxy_opts = parse_proxy_url(self.conf.proxy_server)
    opts.proxy_opts = {
      wss_proxy = proxy_opts.proxy_url,
      wss_proxy_authorization = proxy_opts.proxy_authorization,
    }

    ngx_log(ngx_DEBUG, "[rpc] using proxy ", proxy_opts.proxy_url,
                       " to connect control plane")
  end

  local ok, err = c:connect(uri, opts)
  if not ok then
    ngx_log(ngx_ERR, _log_prefix, "unable to connect to peer: ", err)
    goto err
  end

  do
    local resp_headers = c:get_resp_headers()
    -- FIXME: resp_headers should not be case sensitive

    if not resp_headers or not resp_headers["sec_websocket_protocol"] then
      ngx_log(ngx_ERR, _log_prefix, "peer did not provide sec_websocket_protocol, node_id: ", node_id)
      c:send_close() -- can't do much if this fails
      goto err
    end

    -- should like "kong.meta.v1"
    local meta_cap = resp_headers["sec_websocket_protocol"]

    if meta_cap ~= RPC_MATA_V1 then
      ngx_log(ngx_ERR, _log_prefix, "did not support protocol : ", meta_cap)
      c:send_close() -- can't do much if this fails
      goto err
    end

    -- if timeout (default is 5s) we will close the connection
    local ok, err = self:_meta_call(c, meta_cap, node_id)
    if not ok then
      ngx_log(ngx_ERR, _log_prefix, "unable to handshake with server, node_id: ", node_id,
                       " err: ", err)
      c:send_close() -- can't do much if this fails
      goto err
    end

    local s = socket.new(self, c, node_id)
    s:start()
    self:_add_socket(s)

    ok, err = s:join() -- main event loop

    self:_remove_socket(s)

    if not ok then
      ngx_log(ngx_ERR, _log_prefix, "connection to node_id: ", node_id, " broken, err: ",
              err, ", reconnecting in ", reconnection_delay, " seconds")
    end
  end

  ::err::

  if not exiting() then
    c:close()
    self:try_connect(reconnection_delay)
  end
end


function _M:get_peers()
  local res = {}

  for node_id, cap in pairs(self.client_capabilities) do
    res[node_id] = cap.list
  end

  return res
end


function _M:get_peer_info(node_id)
  return self.client_info[node_id]
end


function _M:set_batch(n)
  assert(type(n) == "number" and n >= 0)
  self.batch_size = n
end


return _M
