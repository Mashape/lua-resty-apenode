local RpcBatchTestHandler = {
  VERSION = "1.0",
  PRIORITY = 1000,
}


function RpcBatchTestHandler:init_worker()
  kong.rpc.callbacks:register("kong.test.batch", function(node_id, greeting)
    ngx.log(ngx.DEBUG, "kong.test.batch called: ", greeting)
    return "hello ".. greeting
  end)

  local worker_events = assert(kong.worker_events)

  -- if rpc is ready we will start to batch call
  worker_events.register(function(capabilities_list)
    kong.rpc:set_batch(1)

    local res = kong.rpc:call("control_plane", "kong.test.batch", "world")
    if not res then
      return
    end

    ngx.log(ngx.DEBUG, "kong.test.batch called: ", res)

    kong.rpc:set_batch(2)
    kong.rpc:notify("control_plane", "kong.test.batch", "kong")
    kong.rpc:notify("control_plane", "kong.test.batch", "gateway")

  end, "clustering:jsonrpc", "connected")
end


return RpcBatchTestHandler
