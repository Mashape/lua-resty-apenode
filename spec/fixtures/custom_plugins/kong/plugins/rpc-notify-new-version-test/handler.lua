local fmt = string.format
local rep = string.rep


local RpcSyncV2NotifyNewVersioinTestHandler = {
  VERSION = "1.0",
  PRIORITY = 1000,
}


function RpcSyncV2NotifyNewVersioinTestHandler:init_worker()
  local counter = 0

  -- mock function on cp side
  kong.rpc.callbacks:register("kong.sync.v2.get_delta", function(node_id, current_versions)
    local latest_version = fmt("v02_%028x", 10)

    local fake_uuid = "00000000-0000-0000-0000-111111111111"

    -- a basic config data
    local deltas = {
      {
        entity = {
          id = fake_uuid,
          name = "default",
        },
        type = "workspaces",
        version = latest_version,
        ws_id = fake_uuid,
      },
    }

    ngx.log(ngx.DEBUG, "kong.sync.v2.get_delta ok: ", counter)
    counter = counter + 1

    return { default = { deltas = deltas, full_sync = true, }, }
  end)

  -- test dp's sync.v2.notify_new_version on cp side
  kong.rpc.callbacks:register("kong.test.notify_new_version", function(node_id)
    local dp_node_id = next(kong.rpc.clients)
    local method = "kong.sync.v2.notify_new_version"

    -- no default
    local msg = {}
    local res, err = kong.rpc:call(dp_node_id, method, msg)
    assert(not res)
    assert(err == "default namespace does not exist inside params")

    -- no default.new_version
    local msg = { default = {}, }
    local res, err = kong.rpc:call(dp_node_id, method, msg)
    assert(not res)
    assert(err == "'new_version' key does not exist")

    -- less version string
    -- "....." < "00000" < "v02_xx"
    local msg = { default = { new_version = rep(".", 32), }, }
    local res, err = kong.rpc:call(dp_node_id, method, msg)
    assert(res)
    assert(not err)

    -- less or equal version string
    -- "00000" < "v02_xx"
    local msg = { default = { new_version = rep("0", 32), }, }
    local res, err = kong.rpc:call(dp_node_id, method, msg)
    assert(res)
    assert(not err)

    -- greater version string
    local msg = { default = { new_version = fmt("v02_%028x", 20), }, }
    local res, err = kong.rpc:call(dp_node_id, method, msg)
    assert(res)
    assert(not err)

    ngx.log(ngx.DEBUG, "kong.test.notify_new_version ok")

    return true
  end)

  local worker_events = assert(kong.worker_events)

  -- if rpc is ready we will send test calls
  worker_events.register(function(capabilities_list)
    local node_id = "control_plane"

    -- trigger cp's test
    local res, err = kong.rpc:call(node_id, "kong.test.notify_new_version")
    assert(res == true)
    assert(not err)

    ngx.log(ngx.DEBUG, "kong.test.notify_new_version ok")

  end, "clustering:jsonrpc", "connected")
end


return RpcSyncV2NotifyNewVersioinTestHandler
