local cjson = require "cjson.safe"
local raw_log = require "ngx.errlog".raw_log
local worker_id = ngx.worker.id
local native_timer_at = _G.native_timer_at or ngx.timer.at
local _, ngx_pipe = pcall(require, "ngx.pipe")

local kong = kong
local ngx_INFO = ngx.INFO
local cjson_decode = cjson.decode
local SIGTERM = 15


local server_rt = {} -- store runtime of plugin server like proc
local _M = {}


--[[
Plugin info requests

Disclaimer:  The best way to do it is to have "ListPlugins()" and "GetInfo(plugin)"
RPC methods; but Kong would like to have all the plugin schemas at initialization time,
before full cosocket is available.  At one time, we used blocking I/O to do RPC at
non-yielding phases, but was considered dangerous.  The alternative is to use
`io.popen(cmd)` to ask fot that info.

The pluginserver_XXX_query_cmd contains a string to be executed as a command line.
The output should be a JSON string that decodes as an array of objects, each
defining the name, priority, version,  schema and phases of one plugin.

    [{
      "name": ... ,
      "priority": ... ,
      "version": ... ,
      "schema": ... ,
      "phases": [ phase_names ... ],
    },
    {
      ...
    },
    ...
    ]

This array should describe all plugins currently available through this server,
no matter if actually enabled in Kong's configuration or not.
--]]

local function query_external_plugin_info(server_def)
  if not server_def.query_command then
    return nil, "no info query for " .. server_def.name
  end

  local fd, err = io.popen(server_def.query_command)
  if not fd then
    return nil, string.format("error loading plugins info from [%s]: %s", server_def.name, err)
  end

  local infos_dump = fd:read("*a")
  fd:close()
  local dump, err = cjson_decode(infos_dump)
  if err then
    return nil, "failed decoding plugin info: " .. err
  end

  if type(dump) ~= "table" then
    return nil, string.format("not a plugin info table: \n%s\n%s", server_def.query_command, infos_dump)
  end

  server_def.protocol = dump.Protocol or "MsgPack:1"
  local info = (dump.Plugins or dump)[1] -- XXX can a pluginserver (in the embedded plugin server world
                                        -- have more than one plugin? only a single
                                        -- configuration is initialized currently, so this
                                        -- seems to be legacy code)

  -- in remote times, a plugin server could serve more than one plugin
  -- nowadays (2.8+), external plugins use an "embedded pluginserver" model, where
  -- each plugin acts as an independent plugin server
  return {
    server_def = server_def,
    name = info.Name,
    PRIORITY = info.Priority,
    VERSION = info.Version,
    schema = info.Schema,
    phases = info.Phases,
  }
end


function _M.load_external_plugins_info(kong_conf)
  local available_external_plugins = {}

  kong.log.notice("[pluginserver] loading external plugins info")

  for _, pluginserver in ipairs(kong_conf.pluginservers) do
    local plugin_info, err = query_external_plugin_info(pluginserver)
    if not plugin_info then
      return nil, err
    end

    available_external_plugins[plugin_info.name] = plugin_info
  end

  kong.log.notice("[pluginserver] loaded #", #kong_conf.pluginservers, " external plugins info")

  return available_external_plugins
end


--[[

Process management

Pluginservers with a corresponding `pluginserver_XXX_start_cmd` field are managed
by Kong.  Stdout and stderr are joined and logged, if it dies, Kong logs the
event and respawns the server.

If the `_start_cmd` is unset (and the default doesn't exist in the filesystem)
it's assumed the process is managed externally.
--]]

local function grab_logs(proc, name)
  local prefix = string.format("[%s:%d] ", name, proc:pid())

  while true do
    local data, err, partial = proc:stdout_read_line()
    local line = data or partial
    if line and line ~= "" then
      raw_log(ngx_INFO, prefix .. line)
    end

    if not data and (err == "closed" or ngx.worker.exiting()) then
      return
    end
  end
end


local function pluginserver_timer(premature, server_def)
  if premature then
    return
  end

  if ngx.config.subsystem ~= "http" then
    return
  end

  local next_spawn = 0

  while not ngx.worker.exiting() do
    if ngx.now() < next_spawn then
      ngx.sleep(next_spawn - ngx.now())
    end

    kong.log.notice("[pluginserver] starting pluginserver process for ", server_def.name or "")
    local proc = assert(ngx_pipe.spawn("exec " .. server_def.start_command, {
      merge_stderr = true,
    }))
    server_rt[server_def.name] = {
      proc = proc,
    }
    next_spawn = ngx.now() + 1
    proc:set_timeouts(nil, nil, nil, 0)     -- block until something actually happens
    kong.log.notice("[pluginserver] started, pid ", proc:pid())

    while true do
      grab_logs(proc, server_def.name)
      local ok, reason, status = proc:wait()

      -- exited with a non 0 status
      if ok == false and reason == "exit" and status == 127 then
        kong.log.err(string.format(
                "[pluginserver] external pluginserver %q start command %q exited with \"command not found\"",
                server_def.name, server_def.start_command))
        break

      -- waited on an exited thread
      elseif ok ~= nil or reason == "exited" or ngx.worker.exiting() then
        kong.log.notice("external pluginserver '", server_def.name, "' terminated: ", tostring(reason), " ", tostring(status))
        break
      end

      -- XXX what happens if the process stops with a 0 status code?
    end
  end

  kong.log.notice("[pluginserver] exiting: pluginserver '", server_def.name, "' not respawned.")
end


function _M.start_pluginservers()
  local kong_config = kong.configuration

  -- only worker 0 manages plugin server processes
  if worker_id() == 0 then -- TODO move to privileged worker?
    local pluginserver_timer = pluginserver_timer

    for _, server_def in ipairs(kong_config.pluginservers) do
      if server_def.start_command then -- if not defined, we assume it's managed externally
        native_timer_at(0, pluginserver_timer, server_def)
      end
    end
  end

  return true
end

function _M.stop_pluginservers()
  local kong_config = kong.configuration

  -- only worker 0 manages plugin server processes
  if worker_id() == 0 then -- TODO move to privileged worker?
    for _, server_def in ipairs(kong_config.pluginservers) do
      local server = server_rt[server_def.name]
      if server and server.proc then
        local ok, err = server.proc:kill(SIGTERM)
        if not ok then
          kong.log.error("[pluginserver] failed to stop pluginserver '", server_def.name, ": ", err)
        end
        kong.log.notice("[pluginserver] successfully stopped pluginserver '", server_def.name, "', pid ", server.proc:pid())
      end
    end
  end

  return true
end

return _M
