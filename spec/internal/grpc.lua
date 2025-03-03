local pl_path = require("pl.path")
local shell = require("resty.shell")
local resty_signal = require("resty.signal")


local CONSTANTS = require("spec.internal.constants")


local function isnewer(path_a, path_b)
  if not pl_path.exists(path_a) then
    return true
  end
  if not pl_path.exists(path_b) then
    return false
  end
  return assert(pl_path.getmtime(path_b)) > assert(pl_path.getmtime(path_a))
end


local function make(workdir, specs)
  workdir = pl_path.normpath(workdir or pl_path.currentdir())

  for _, spec in ipairs(specs) do
    local targetpath = pl_path.join(workdir, spec.target)
    for _, src in ipairs(spec.src) do
      local srcpath = pl_path.join(workdir, src)
      if isnewer(targetpath, srcpath) then
        local ok, _, stderr = shell.run(string.format("cd %s; %s", workdir, spec.cmd), nil, 0)
        assert(ok, stderr)
        if isnewer(targetpath, srcpath) then
          error(string.format("couldn't make %q newer than %q", targetpath, srcpath))
        end
        break
      end
    end
  end

  return true
end


local grpc_target_proc


local function start_grpc_target()
  local ngx_pipe = require("ngx.pipe")
  assert(make(CONSTANTS.GRPC_TARGET_SRC_PATH, {
    {
      target = "targetservice/targetservice.pb.go",
      src    = { "proto/targetservice.proto" },
      cmd    = "protoc --go_out=. --go-grpc_out=. -I proto/ proto/targetservice.proto",
    },
    {
      target = "targetservice/targetservice_grpc.pb.go",
      src    = { "proto/targetservice.proto" },
      cmd    = "protoc --go_out=. --go-grpc_out=. -I proto/ proto/targetservice.proto",
    },
    {
      target = "target",
      src    = { "target.go", "targetservice/targetservice.pb.go", "targetservice/targetservice_grpc.pb.go" },
      cmd    = "go mod tidy && go mod download all && go build -o target",
    },
  }))
  grpc_target_proc = assert(ngx_pipe.spawn({ CONSTANTS.GRPC_TARGET_SRC_PATH .. "/target" }, {
      merge_stderr = true,
  }))

  return true
end


local function stop_grpc_target()
  if grpc_target_proc then
    grpc_target_proc:kill(resty_signal.signum("QUIT"))
    grpc_target_proc = nil
  end
end


local function get_grpc_target_port()
  return 15010
end


return {
  start_grpc_target = start_grpc_target,
  stop_grpc_target = stop_grpc_target,
  get_grpc_target_port = get_grpc_target_port,
}

