------------------------------------------------------------------
-- Collection of utilities to help testing Kong features and plugins.
--
-- @copyright Copyright 2016-2022 Kong Inc. All rights reserved.
-- @license [Apache 2.0](https://opensource.org/licenses/Apache-2.0)
-- @module spec.helpers


local lfs = require("lfs")
local version = require("version")
local pl_dir = require("pl.dir")
local pl_path = require("pl.path")
local pl_utils = require("pl.utils")
local constants = require("kong.constants")
local conf_loader = require("kong.conf_loader")
local kong_table = require("kong.tools.table")
local kill = require("kong.cmd.utils.kill")
local prefix_handler = require("kong.cmd.utils.prefix_handler")


local CONSTANTS = require("spec.internal.constants")
local conf = require("spec.internal.conf")
local shell = require("spec.internal.shell")
local DB
local pid = require("spec.internal.pid")
local dns_mock = require("spec.internal.dns")


-- initialized in start_kong()
local config_yml


--- Return the actual Kong version the tests are running against.
-- See [version.lua](https://github.com/kong/version.lua) for the format. This
-- is mostly useful for testing plugins that should work with multiple Kong versions.
-- @function get_version
-- @return a `version` object
-- @usage
-- local version = require 'version'
-- if helpers.get_version() < version("0.15.0") then
--   -- do something
-- end
local function get_version()
  return version(select(3, assert(shell.kong_exec("version"))))
end


local function build_go_plugins(path)
  if pl_path.exists(pl_path.join(path, "go.mod")) then
    local ok, _, stderr = shell.run(string.format(
            "cd %s; go mod tidy; go mod download", path), nil, 0)
    assert(ok, stderr)
  end
  for _, go_source in ipairs(pl_dir.getfiles(path, "*.go")) do
    local ok, _, stderr = shell.run(string.format(
            "cd %s; go build %s",
            path, pl_path.basename(go_source)
    ), nil, 0)
    assert(ok, stderr)
  end
end


--- Prepares the Kong environment.
-- Creates the working directory if it does not exist.
-- @param prefix (optional) path to the working directory, if omitted the test
-- configuration will be used
-- @function prepare_prefix
local function prepare_prefix(prefix)
  return pl_dir.makepath(prefix or conf.prefix)
end


--- Cleans the Kong environment.
-- Deletes the working directory if it exists.
-- @param prefix (optional) path to the working directory, if omitted the test
-- configuration will be used
-- @function clean_prefix
local function clean_prefix(prefix)

  -- like pl_dir.rmtree, but ignore mount points
  local function rmtree(fullpath)
    if pl_path.islink(fullpath) then return false,'will not follow symlink' end
    for root,dirs,files in pl_dir.walk(fullpath,true) do
      if pl_path.islink(root) then
        -- sub dir is a link, remove link, do not follow
        local res, err = os.remove(root)
        if not res then
          return nil, err .. ": " .. root
        end

      else
        for i,f in ipairs(files) do
          f = pl_path.join(root,f)
          local res, err = os.remove(f)
          if not res then
            return nil,err .. ": " .. f
          end
        end

        local res, err = pl_path.rmdir(root)
        -- skip errors when trying to remove mount points
        if not res and shell.run("findmnt " .. root .. " 2>&1 >/dev/null", nil, 0) == 0 then
          return nil, err .. ": " .. root
        end
      end
    end
    return true
  end

  prefix = prefix or conf.prefix
  if pl_path.exists(prefix) then
    local _, err = rmtree(prefix)
    if err then
      error(err)
    end
  end
end


local function render_fixtures(conf, env, prefix, fixtures)

  if fixtures and (fixtures.http_mock or fixtures.stream_mock) then
    -- prepare the prefix so we get the full config in the
    -- hidden `.kong_env` file, including test specified env vars etc
    assert(shell.kong_exec("prepare --conf " .. conf, env))
    local render_config = assert(conf_loader(prefix .. "/.kong_env", nil,
                                             { from_kong_env = true }))

    for _, mocktype in ipairs { "http_mock", "stream_mock" } do

      for filename, contents in pairs(fixtures[mocktype] or {}) do
        -- render the file using the full configuration
        contents = assert(prefix_handler.compile_conf(render_config, contents))

        -- write file to prefix
        filename = prefix .. "/" .. filename .. "." .. mocktype
        assert(pl_utils.writefile(filename, contents))
      end
    end
  end

  if fixtures and fixtures.dns_mock then
    -- write the mock records to the prefix
    assert(getmetatable(fixtures.dns_mock) == dns_mock,
           "expected dns_mock to be of a helpers.dns_mock class")
    assert(pl_utils.writefile(prefix .. "/dns_mock_records.json",
                              tostring(fixtures.dns_mock)))

    -- add the mock resolver to the path to ensure the records are loaded
    if env.lua_package_path then
      env.lua_package_path = CONSTANTS.DNS_MOCK_LUA_PATH .. ";" .. env.lua_package_path
    else
      env.lua_package_path = CONSTANTS.DNS_MOCK_LUA_PATH
    end
  else
    -- remove any old mocks if they exist
    os.remove(prefix .. "/dns_mock_records.json")
  end

  return true
end


--- Return the actual configuration running at the given prefix.
-- It may differ from the default, as it may have been modified
-- by the `env` table given to start_kong.
-- @function get_running_conf
-- @param prefix (optional) The prefix path where the kong instance is running,
-- defaults to the prefix in the default config.
-- @return The conf table of the running instance, or nil + error.
local function get_running_conf(prefix)
  local default_conf = conf_loader(nil, {prefix = prefix or conf.prefix})
  return conf_loader.load_config_file(default_conf.kong_env)
end


--- Clears the logfile. Will overwrite the logfile with an empty file.
-- @function clean_logfile
-- @param logfile (optional) filename to clear, defaults to the current
-- error-log file
-- @return nothing
-- @see line
local function clean_logfile(logfile)
  logfile = logfile or (get_running_conf() or conf).nginx_err_logs

  assert(type(logfile) == "string", "'logfile' must be a string")

  local fh, err, errno = io.open(logfile, "w+")

  if fh then
    fh:close()
    return

  elseif errno == 2 then -- ENOENT
    return
  end

  error("failed to truncate logfile: " .. tostring(err))
end


--- Start the Kong instance to test against.
-- The fixtures passed to this function can be 3 types:
--
-- * DNS mocks
--
-- * Nginx server blocks to be inserted in the http module
--
-- * Nginx server blocks to be inserted in the stream module
-- @function start_kong
-- @param env table with Kong configuration parameters (and values)
-- @param tables list of database tables to truncate before starting
-- @param preserve_prefix (boolean) if truthy, the prefix will not be cleaned
-- before starting
-- @param fixtures tables with fixtures, dns, http and stream mocks.
-- @return return values from `execute`
-- @usage
-- -- example mocks
-- -- Create a new DNS mock and add some DNS records
-- local fixtures = {
--   http_mock = {},
--   stream_mock = {},
--   dns_mock = helpers.dns_mock.new()
-- }
--
-- **DEPRECATED**: http_mock fixture is deprecated. Please use `spec.helpers.http_mock` instead.
--
-- fixtures.dns_mock:A {
--   name = "a.my.srv.test.com",
--   address = "127.0.0.1",
-- }
--
-- -- The blocks below will be rendered by the Kong template renderer, like other
-- -- custom Kong templates. Hence the `${{xxxx}}` values.
-- -- Multiple mocks can be added each under their own filename ("my_server_block" below)
-- fixtures.http_mock.my_server_block = [[
--      server {
--          server_name my_server;
--          listen 10001 ssl;
--
--          ssl_certificate ${{SSL_CERT}};
--          ssl_certificate_key ${{SSL_CERT_KEY}};
--          ssl_protocols TLSv1.2 TLSv1.3;
--
--          location ~ "/echobody" {
--            content_by_lua_block {
--              ngx.req.read_body()
--              local echo = ngx.req.get_body_data()
--              ngx.status = status
--              ngx.header["Content-Length"] = #echo + 1
--              ngx.say(echo)
--            }
--          }
--      }
--    ]]
--
-- fixtures.stream_mock.my_server_block = [[
--      server {
--        -- insert stream server config here
--      }
--    ]]
--
-- assert(helpers.start_kong( {database = "postgres"}, nil, nil, fixtures))
local function start_kong(env, tables, preserve_prefix, fixtures)
  if not DB then
    DB = require("spec.internal.db")
  end

  if tables ~= nil and type(tables) ~= "table" then
    error("arg #2 must be a list of tables to truncate")
  end
  env = env or {}
  local prefix = env.prefix or conf.prefix

  -- go plugins are enabled
  --  compile fixture go plugins if any setting mentions it
  for _,v in pairs(env) do
    if type(v) == "string" and v:find(CONSTANTS.EXTERNAL_PLUGINS_PATH .. "/go") then
      build_go_plugins(CONSTANTS.EXTERNAL_PLUGINS_PATH .. "/go")
      break
    end
  end

  -- note: set env var "KONG_TEST_DONT_CLEAN" !! the "_TEST" will be dropped
  if not (preserve_prefix or os.getenv("KONG_DONT_CLEAN")) then
    clean_prefix(prefix)
  end

  local ok, err = prepare_prefix(prefix)
  if not ok then return nil, err end

  DB.truncate_tables(DB.db, tables)

  local nginx_conf = ""
  local nginx_conf_flags = { "test" }
  if env.nginx_conf then
    nginx_conf = " --nginx-conf " .. env.nginx_conf
  end

  if CONSTANTS.TEST_COVERAGE_MODE == "true" then
    -- render `coverage` blocks in the templates
    nginx_conf_flags[#nginx_conf_flags + 1] = 'coverage'
  end

  if next(nginx_conf_flags) then
    nginx_conf_flags = " --nginx-conf-flags " .. table.concat(nginx_conf_flags, ",")
  else
    nginx_conf_flags = ""
  end

  local dcbp = DB.get_dcbp()
  if dcbp and not env.declarative_config and not env.declarative_config_string then
    if not config_yml then
      config_yml = prefix .. "/config.yml"
      local cfg = dcbp.done()
      local declarative = require "kong.db.declarative"
      local ok, err = declarative.to_yaml_file(cfg, config_yml)
      if not ok then
        return nil, err
      end
    end
    env = kong_table.cycle_aware_deep_copy(env)
    env.declarative_config = config_yml
  end

  assert(render_fixtures(CONSTANTS.TEST_CONF_PATH .. nginx_conf, env, prefix, fixtures))
  return shell.kong_exec("start --conf " .. CONSTANTS.TEST_CONF_PATH .. nginx_conf .. nginx_conf_flags, env)
end


-- Cleanup after kong test instance, should be called if start_kong was invoked with the nowait flag
-- @function cleanup_kong
-- @param prefix (optional) the prefix where the test instance runs, defaults to the test configuration.
-- @param preserve_prefix (boolean) if truthy, the prefix will not be deleted after stopping
-- @param preserve_dc ???
local function cleanup_kong(prefix, preserve_prefix, preserve_dc)
  -- remove socket files to ensure `pl.dir.rmtree()` ok
  prefix = prefix or conf.prefix
  local socket_path = pl_path.join(prefix, constants.SOCKET_DIRECTORY)
  for child in lfs.dir(socket_path) do
    local path = pl_path.join(socket_path, child)
    if lfs.attributes(path, "mode") == "socket" then
      os.remove(path)
    end
  end

  -- note: set env var "KONG_TEST_DONT_CLEAN" !! the "_TEST" will be dropped
  if not (preserve_prefix or os.getenv("KONG_DONT_CLEAN")) then
    clean_prefix(prefix)
  end

  if not preserve_dc then
    config_yml = nil
  end
  ngx.ctx.workspace = nil
end


-- Stop the Kong test instance.
-- @function stop_kong
-- @param prefix (optional) the prefix where the test instance runs, defaults to the test configuration.
-- @param preserve_prefix (boolean) if truthy, the prefix will not be deleted after stopping
-- @param preserve_dc ???
-- @param signal (optional string) signal name to send to kong, defaults to TERM
-- @param nowait (optional) if truthy, don't wait for kong to terminate.  caller needs to wait and call cleanup_kong
-- @return true or nil+err
local function stop_kong(prefix, preserve_prefix, preserve_dc, signal, nowait)
  prefix = prefix or conf.prefix
  signal = signal or "TERM"

  local running_conf, err = get_running_conf(prefix)
  if not running_conf then
    return nil, err
  end

  local id, err = pid.get_pid_from_file(running_conf.nginx_pid)
  if not id then
    return nil, err
  end

  local ok, _, err = shell.run(string.format("kill -%s %d", signal, id), nil, 0)
  if not ok then
    return nil, err
  end

  if nowait then
    return running_conf.nginx_pid
  end

  pid.wait_pid(running_conf.nginx_pid)

  cleanup_kong(prefix, preserve_prefix, preserve_dc)

  return true
end


--- Restart Kong. Reusing declarative config when using `database=off`.
-- @function restart_kong
-- @param env see `start_kong`
-- @param tables see `start_kong`
-- @param fixtures see `start_kong`
-- @return true or nil+err
local function restart_kong(env, tables, fixtures)
  stop_kong(env.prefix, true, true)
  return start_kong(env, tables, true, fixtures)
end


-- Only use in CLI tests from spec/02-integration/01-cmd
local function kill_all(prefix, timeout)
  local running_conf = get_running_conf(prefix)
  if not running_conf then return end

  -- kill kong_tests.conf service
  local pid_path = running_conf.nginx_pid
  if pl_path.exists(pid_path) then
    kill.kill(pid_path, "-TERM")
    pid.wait_pid(pid_path, timeout)
  end
end


local function signal(prefix, signal, pid_path)
  if not pid_path then
    local running_conf = get_running_conf(prefix)
    if not running_conf then
      error("no config file found at prefix: " .. prefix)
    end

    pid_path = running_conf.nginx_pid
  end

  return kill.kill(pid_path, signal)
end


-- send signal to all Nginx workers, not including the master
local function signal_workers(prefix, signal, pid_path)
  if not pid_path then
    local running_conf = get_running_conf(prefix)
    if not running_conf then
      error("no config file found at prefix: " .. prefix)
    end

    pid_path = running_conf.nginx_pid
  end

  local cmd = string.format("pkill %s -P `cat %s`", signal, pid_path)
  local _, _, _, _, code = shell.run(cmd)

  if not pid.pid_dead(pid_path) then
    return false
  end

  return code
end


return {
  get_version = get_version,

  start_kong = start_kong,
  cleanup_kong = cleanup_kong,
  stop_kong = stop_kong,
  restart_kong = restart_kong,

  prepare_prefix = prepare_prefix,
  clean_prefix = clean_prefix,

  get_running_conf = get_running_conf,
  clean_logfile = clean_logfile,

  kill_all = kill_all,
  signal = signal,
  signal_workers = signal_workers,

  build_go_plugins = build_go_plugins,
}

