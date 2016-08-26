local nginx_signals = require "kong.cmd.utils.nginx_signals"
local serf_signals = require "kong.cmd.utils.serf_signals"
local conf_loader = require "kong.conf_loader"
local DAOFactory = require "kong.dao.factory"
local pl_path = require "pl.path"
local kill = require "kong.cmd.utils.kill"
local log = require "kong.cmd.utils.log"

local function execute(args)
  log.disable()
  -- retrieve default prefix or use given one
  local default_conf = assert(conf_loader(nil, {
    prefix = args.prefix
  }))
  log.enable()
  assert(pl_path.exists(default_conf.prefix),
         "no such prefix: "..default_conf.prefix)

  -- load <PREFIX>/kong.conf containing running node's config
  local conf = assert(conf_loader(default_conf.kong_conf))

  -- try graceful shutdown (QUIT)
  assert(nginx_signals.quit(conf))

  log.verbose("waiting for nginx to finish processing requests")

  local tstart = ngx.time()
  local texp, running = tstart + math.max(args.timeout, 1) -- min 1s timeout
  repeat
    ngx.sleep(0.2)
    running = kill.is_running(conf.nginx_pid)
  until not running or ngx.time() >= texp

  if running then
    log.verbose("nginx is still running at %s, forcing shutdown", conf.prefix)
    assert(nginx_signals.stop(conf))
  end

  assert(serf_signals.stop(conf, DAOFactory(conf)))

  log("Kong stopped (gracefully)")
end

local lapp = [[
Usage: kong quit [OPTIONS]

Gracefully quit a running Kong node (Nginx and other
configured services) in given prefix directory.

This command sends a SIGQUIT signal to Nginx, meaning all
requests will finish processing before shutting down.
If the timeout delay is reached, the node will be forcefully
stopped (SIGTERM).

Options:
 -p,--prefix  (optional string) prefix Kong is running at
 -t,--timeout (default 10) timeout before forced shutdown
]]

return {
  lapp = lapp,
  execute = execute
}
