local rep = string.rep
local isempty = require("table.isempty")


local RpcSyncV2GetDeltaTestHandler = {
  VERSION = "1.0",
  PRIORITY = 1000,
}


function RpcSyncV2GetDeltaTestHandler:init_worker()
  local worker_events = assert(kong.worker_events)

  -- if rpc is ready we will send test calls
  -- cp's version now is "v02_00000"
  worker_events.register(function(capabilities_list)
    local node_id = "control_plane"
    local method = "kong.sync.v2.get_delta"

    -- no field `default` for kong.sync.v2.get_delta
    local msg = {}
    local res, err = kong.rpc:call(node_id, method, msg)

    assert(not res)
    assert(err == "default namespace does not exist inside params")

    -- version is invalid
    local msg = { default = { version = rep("A", 32), }, }
    local res, err = kong.rpc:call(node_id, method, msg)

    assert(type(res) == "table")
    assert(not isempty(res.default.deltas))
    assert(res.default.full_sync == true)
    assert(not err)

    -- dp's version is greater than cp's version
    local msg = { default = { version = "v02_" .. rep("A", 28), }, }
    local res, err = kong.rpc:call(node_id, method, msg)

    assert(type(res) == "table")
    assert(not isempty(res.default.deltas))
    assert(res.default.full_sync == true)
    assert(not err)

    -- dp's version is equal to cp's version
    local msg = { default = { version = "v02_" .. rep("0", 28), }, }
    local res, err = kong.rpc:call(node_id, method, msg)

    assert(type(res) == "table")
    assert(isempty(res.default.deltas))
    assert(res.default.full_sync == false)
    assert(not err)

    ngx.log(ngx.DEBUG, "kong.sync.v2.get_delta ok")

  end, "clustering:jsonrpc", "connected")
end


return RpcSyncV2GetDeltaTestHandler
