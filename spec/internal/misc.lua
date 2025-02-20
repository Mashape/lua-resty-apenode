------------------------------------------------------------------
-- Collection of utilities to help testing Kong features and plugins.
--
-- @copyright Copyright 2016-2022 Kong Inc. All rights reserved.
-- @license [Apache 2.0](https://opensource.org/licenses/Apache-2.0)
-- @module spec.helpers


-- miscellaneous


local pl_path = require("pl.path")
local pl_dir = require("pl.dir")
local pkey = require("resty.openssl.pkey")
local nginx_signals = require("kong.cmd.utils.nginx_signals")
local shell = require("spec.internal.shell")


local CONSTANTS = require("spec.internal.constants")
local sys = require("spec.internal.sys")

local private_node = require "kong.pdk.private.node"


local pack = function(...) return { n = select("#", ...), ... } end
local unpack = function(t) return unpack(t, 1, t.n) end


--- Prints all returned parameters.
-- Simple debugging aid, it will pass all received parameters, hence will not
-- influence the flow of the code. See also `fail`.
-- @function intercept
-- @see fail
-- @usage -- modify
-- local a,b = some_func(c,d)
-- -- into
-- local a,b = intercept(some_func(c,d))
local function intercept(...)
  local args = pack(...)
  print(require("pl.pretty").write(args))
  return unpack(args)
end


--- Returns the OpenResty version.
-- Extract the current OpenResty version in use and returns
-- a numerical representation of it.
-- Ex: `1.11.2.2` -> `11122`
-- @function openresty_ver_num
local function openresty_ver_num()
  local nginx_bin = assert(nginx_signals.find_nginx_bin())
  local _, _, stderr = shell.run(string.format("%s -V", nginx_bin), nil, 0)

  local a, b, c, d = string.match(stderr or "", "openresty/(%d+)%.(%d+)%.(%d+)%.(%d+)")
  if not a then
    error("could not execute 'nginx -V': " .. stderr)
  end

  return tonumber(a .. b .. c .. d)
end


--- Unindent a multi-line string for proper indenting in
-- square brackets.
-- @function unindent
-- @usage
-- local u = helpers.unindent
--
-- u[[
--     hello world
--     foo bar
-- ]]
--
-- -- will return: "hello world\nfoo bar"
local function unindent(str, concat_newlines, spaced_newlines)
  str = string.match(str, "(.-%S*)%s*$")
  if not str then
    return ""
  end

  local level  = math.huge
  local prefix = ""
  local len

  str = str:match("^%s") and "\n" .. str or str
  for pref in str:gmatch("\n(%s+)") do
    len = #prefix

    if len < level then
      level  = len
      prefix = pref
    end
  end

  local repl = concat_newlines and "" or "\n"
  repl = spaced_newlines and " " or repl

  return (str:gsub("^\n%s*", ""):gsub("\n" .. prefix, repl):gsub("\n$", ""):gsub("\\r", "\r"))
end


--- Write a yaml file.
-- @function make_yaml_file
-- @param content (string) the yaml string to write to the file, if omitted the
-- current database contents will be written using `kong config db_export`.
-- @param filename (optional) if not provided, a temp name will be created
-- @return filename of the file written
local function make_yaml_file(content, filename)
  local filename = filename or pl_path.tmpname() .. ".yml"
  if content then
    local fd = assert(io.open(filename, "w"))
    assert(fd:write(unindent(content)))
    assert(fd:write("\n")) -- ensure last line ends in newline
    assert(fd:close())
  else
    assert(shell.kong_exec("config db_export --conf "..CONSTANTS.TEST_CONF_PATH.." "..filename))
  end
  return filename
end


local deep_sort
do
  local function deep_compare(a, b)
    if a == nil then
      a = ""
    end

    if b == nil then
      b = ""
    end

    deep_sort(a)
    deep_sort(b)

    if type(a) ~= type(b) then
      return type(a) < type(b)
    end

    if type(a) == "table" then
      return deep_compare(a[1], b[1])
    end

    -- compare cjson.null or ngx.null
    if type(a) == "userdata" and type(b) == "userdata" then
      return false
    end

    return a < b
  end

  deep_sort = function(t)
    if type(t) == "table" then
      for _, v in pairs(t) do
        deep_sort(v)
      end
      table.sort(t, deep_compare)
    end

    return t
  end
end


--- Generate asymmetric keys
-- @function generate_keys
-- @param fmt format to receive the public and private pair
-- @param typ (optional) the type of key to generate, default: RSA
-- @return `pub, priv` key tuple or `nil + err` on failure
local function generate_keys(fmt, typ)
  fmt = string.upper(fmt) or "JWK"
  typ = typ and string.upper(typ) or "RSA"
  local key, err
  -- only support RSA and EC for now
  if typ == "RSA" then
    key, err = pkey.new({
      type = 'RSA',
      bits = 2048,
      exp = 65537
    })

  elseif typ == "EC" then
    key, err = pkey.new({
      type = 'EC',
      curve = 'prime256v1',
    })

  else
    return nil, "unsupported key type"
  end
  assert(key)
  assert(err == nil, err)
  local pub = key:tostring("public", fmt)
  local priv = key:tostring("private", fmt)
  return pub, priv
end


-- Case insensitive lookup function, returns the value and the original key. Or
-- if not found nil and the search key
-- @usage -- sample usage
-- local test = { SoMeKeY = 10 }
-- print(lookup(test, "somekey"))  --> 10, "SoMeKeY"
-- print(lookup(test, "NotFound")) --> nil, "NotFound"
local function lookup(t, k)
  local ok = k
  if type(k) ~= "string" then
    return t[k], k
  else
    k = k:lower()
  end
  for key, value in pairs(t) do
    if tostring(key):lower() == k then
      return value, key
    end
  end
  return nil, ok
end


local function with_current_ws(ws,fn, db)
  local old_ws = ngx.ctx.workspace
  ngx.ctx.workspace = nil
  ws = ws or {db.workspaces:select_by_name("default")}
  ngx.ctx.workspace = ws[1] and ws[1].id
  local res = fn()
  ngx.ctx.workspace = old_ws
  return res
end


local make_temp_dir
do
  local seeded = false

  function make_temp_dir()
    if not seeded then
      ngx.update_time()
      math.randomseed(ngx.worker.pid() + ngx.now())
      seeded = true
    end

    local tmp
    local ok, err

    local tries = 1000
    for _ = 1, tries do
      local name = "/tmp/.kong-test" .. math.random()

      ok, err = pl_path.mkdir(name)

      if ok then
        tmp = name
        break
      end
    end

    assert(tmp ~= nil, "failed to create temporary directory " ..
                       "after " .. tostring(tries) .. " tries, " ..
                       "last error: " .. tostring(err))

    return tmp, function() pl_dir.rmtree(tmp) end
  end
end


-- This function is used for plugin compatibility test.
-- It will use the old version plugin by including the path of the old plugin
-- at the first of LUA_PATH.
-- The return value is a function which when called will recover the original
-- LUA_PATH and remove the temporary directory if it exists.
-- For an example of how to use it, please see:
-- plugins-ee/rate-limiting-advanced/spec/06-old-plugin-compatibility_spec.lua
-- spec/03-plugins/03-http-log/05-old-plugin-compatibility_spec.lua
local function use_old_plugin(name)
  assert(type(name) == "string", "must specify the plugin name")

  local old_plugin_path
  local temp_dir
  if pl_path.exists(CONSTANTS.OLD_VERSION_KONG_PATH .. "/kong/plugins/" .. name) then
    -- only include the path of the specified plugin into LUA_PATH
    -- and keep the directory structure 'kong/plugins/...'
    temp_dir = make_temp_dir()
    old_plugin_path = temp_dir
    local dest_dir = old_plugin_path .. "/kong/plugins"
    assert(pl_dir.makepath(dest_dir), "failed to makepath " .. dest_dir)
    assert(shell.run("cp -r " .. CONSTANTS.OLD_VERSION_KONG_PATH .. "/kong/plugins/" .. name .. " " .. dest_dir), "failed to copy the plugin directory")

  else
    error("the specified plugin " .. name .. " doesn't exist")
  end

  local origin_lua_path = os.getenv("LUA_PATH")
  -- put the old plugin path at first
  assert(sys.setenv("LUA_PATH", old_plugin_path .. "/?.lua;" .. old_plugin_path .. "/?/init.lua;" .. origin_lua_path), "failed to set LUA_PATH env")

  return function ()
    sys.setenv("LUA_PATH", origin_lua_path)
    if temp_dir then
      pl_dir.rmtree(temp_dir)
    end
  end
end


-- Timer repatching
-- this makes `kong` introduced by `spec.internal.db` visible to the timer
-- however it breaks some other tests, so you need to undo it after the test
local repatch_timer, unrepatch_timer do
  local original_at = ngx.timer.at
  local original_every = ngx.timer.every
  local original_timer = kong and kong.timer
  local repatched = false

  function repatch_timer()
    local _timerng

    _timerng = require("resty.timerng").new({
      min_threads = 16,
      max_threads = 32,
    })

    _timerng:start()

    _G.timerng = _timerng

    _G.ngx.timer.at = function (delay, callback, ...)
      return _timerng:at(delay, callback, ...)
    end

    _G.ngx.timer.every = function (interval, callback, ...)
      return _timerng:every(interval, callback, ...)
    end

    if kong then
      kong.timer = _timerng
    end

    repatched = true
  end

  function unrepatch_timer()
    if not repatched then
      return
    end

    _G.ngx.timer.at = original_at
    _G.ngx.timer.every = original_every

    if kong then
      kong.timer = original_timer
    end

    _G.timerng:destroy()
    _G.timerng = nil

    repatched = false
  end
end

local function patch_worker_events()
  if not kong then
    return
  end
  
  if kong.worker_events then
    return
  end

  kong.worker_events = require("resty.events.compat")
  kong.worker_events.configure({
    listening = "unix:",
    testing = true,
  })
end


return {
  pack = pack,
  unpack = unpack,

  intercept = intercept,
  openresty_ver_num = openresty_ver_num(),
  unindent = unindent,
  make_yaml_file = make_yaml_file,
  setenv = sys.setenv,
  unsetenv = sys.unsetenv,
  deep_sort = deep_sort,

  generate_keys = generate_keys,

  lookup = lookup,

  with_current_ws = with_current_ws,
  make_temp_dir = make_temp_dir,
  use_old_plugin = use_old_plugin,

  get_node_id = private_node.load_node_id,

  repatch_timer = repatch_timer,
  unrepatch_timer = unrepatch_timer,
  patch_worker_events = patch_worker_events,
}
