local lpack = require "lua_pack"
local protoc = require "protoc"
local pb = require "pb"
local pl_path = require "pl.path"
local date = require "date"

local bpack = lpack.pack
local bunpack = lpack.unpack

local type = type
local pcall = pcall
local error = error
local tostring = tostring
local ipairs = ipairs
local string_format = string.format
local splitpath = pl_path.splitpath
local abspath = pl_path.abspath
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG

local epoch = date.epoch()

local _M = {}
local _MT = { __index = _M, }


local function safe_set_type_hook(typ, dec, enc)
  if not pcall(pb.hook, typ) then
    ngx_log(ngx_DEBUG, "no type '", typ, "' defined")
    return
  end

  if not pb.hook(typ) then
    pb.hook(typ, dec)
  end

  if not pb.encode_hook(typ) then
    pb.encode_hook(typ, enc)
  end
end

local function set_hooks()
  pb.option("enable_hooks")
  pb.option("enable_enchooks")

  safe_set_type_hook(".google.protobuf.Timestamp", function (t)
    if type(t) ~= "table" then
      error(string_format("expected table, got (%s)%q", type(t), tostring(t)))
    end

    return date(t.seconds):fmt("${iso}")
  end,
  function (t)
    if type(t) ~= "string" then
      error(string_format(
        "expected time string, got (%s)%q", type(t), tostring(t)))
    end

    local ds = date(t) - epoch
    return {
      seconds = ds:spanseconds(),
      nanos = ds:getticks() * 1000,
    }
  end)
end

function _M.new()
  local protoc_instance = protoc.new()
  -- order by priority
  for _, v in ipairs {
    "/usr/local/kong/include",
    "/usr/local/opt/protobuf/include/", -- homebrew
    "/usr/include",
    "kong/include",
    "spec/fixtures/grpc/proto",
  } do
    protoc_instance:addpath(v)
  end
  protoc_instance.include_imports = true

  return setmetatable({
    protoc_instance = protoc_instance,
  }, _MT)
end

function _M:addpath(path)
  local protoc_instance = self.protoc_instance
  if type(path) == "table" then
    for _, v in ipairs(path) do
      protoc_instance:addpath(v)
    end

  else
    protoc_instance:addpath(path)
  end
end

function _M:get_proto_file(name)
  for _, path in ipairs(self.protoc_instance.paths) do
    local fn = path ~= "" and path .. "/" .. name or name
    local fh, _ = io.open(fn)
    if fh then
      return fh
    end
  end
  return nil
end

local function each_method_recur(protoc_instance, fname, f, recurse)
  local parsed = protoc_instance:parsefile(fname)
  if f then
    if recurse and parsed.dependency then
      if parsed.public_dependency then
        for _, dependency_index in ipairs(parsed.public_dependency) do
          local sub = parsed.dependency[dependency_index + 1]
          each_method_recur(protoc_instance, sub, f, true)
        end
      end
    end

    for _, srvc in ipairs(parsed.service or {}) do
      for _, mthd in ipairs(srvc.method or {}) do
        f(parsed, srvc, mthd)
      end
    end
  end

  return parsed
end

--- loads a .proto file optionally applies a function on each defined method.
function _M:each_method(fname, f, recurse)
  local protoc_instance = self.protoc_instance
  local dir = splitpath(abspath(fname))
  protoc_instance:addpath(dir)
  protoc_instance:loadfile(fname)
  set_hooks()

  return each_method_recur(protoc_instance, fname, f, recurse)
end

--- wraps a binary payload into a grpc stream frame.
function _M.frame(ftype, msg)
  -- byte 0: frame type
  -- byte 1-4: frame size in big endian (could be zero)
  -- byte 5-: frame content
  return bpack("C>I", ftype, #msg) .. msg
end

--- unwraps one frame from a grpc stream.
--- If success, returns `content, rest`.
--- If heading frame isn't complete, returns `nil, body`,
--- try again with more data.
function _M.unframe(body)
  -- must be at least 5 bytes(frame header)
  if not body or #body < 5 then
    return nil, body
  end

  local pos, ftype, sz = bunpack(body, "C>I") -- luacheck: ignore ftype
  local frame_end = pos + sz - 1
  if frame_end > #body then
    return nil, body
  end

  return body:sub(pos, frame_end), body:sub(frame_end + 1)
end

return _M
