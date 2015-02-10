-- Copyright (C) Mashape, Inc.

local stringy = require "stringy"
local Object = require "classic"
local cjson = require "cjson"
local json_params = require("lapis.application").json_params

local BaseController = Object:extend()

local function remove_private_properties(entity)
  for k,_ in pairs(entity) do
    if string.sub(k, 1, 1) == "_" then -- Remove private properties that start with "_"
      entity[k] = nil
    end
  end
  return entity
end

local function render_list_response(req, data)
  if data then
    for i,v in ipairs(data) do
      data[i] = remove_private_properties(v)
    end
  end

  local result = {
    data = data
  }

  return result
end

local function parse_params(dao_collection, params)
  for k,v in pairs(params) do
    if dao_collection._schema[k] and dao_collection._schema[k].type == "table" then
      if not v or stringy.strip(v) == "" then
        params[k] = nil
      else
        -- It can either be a JSON map or a string array separated by comma
        local status, res = pcall(cjson.decode, v)
        if status then
          params[k] = res
        else
          params[k] = stringy.split(v, ",")
        end
      end
    end
  end
  return params
end

function BaseController:new(dao_collection, collection)
  app:post("/"..collection.."/", function(self)
    local params = parse_params(dao_collection, self.params)
    local data, err = dao_collection:insert(params)
    if err then
      return utils.show_error(400, err)
    else
      return utils.created(data)
    end
  end)

  app:get("/"..collection.."/", function(self)
    local params = parse_params(dao_collection, self.params)
    local data, err
    if utils.table_size(params) == 0 then
      data, err = dao_collection:find()
    else
      data, err = dao_collection:find_by_keys(params)
    end
    if err then
      return utils.show_error(500, err)
    end
    return utils.success(render_list_response(self.req, data))
  end)

  app:get("/"..collection.."/:id", function(self)
    local data, err = dao_collection:find_one(self.params.id)
    if err then
      return utils.show_error(500, err)
    end
    if data then
      return utils.success(remove_private_properties(data))
    else
      return utils.not_found()
    end
  end)

  app:delete("/"..collection.."/:id", function(self)
    local ok, err = dao_collection:delete(self.params.id)
    if err then
      return utils.show_error(500, err)
    end
    if ok then
      return utils.no_content()
    else
      return utils.not_found()
    end
  end)

  app:put("/"..collection.."/:id", json_params(function(self)
    local params = parse_params(dao_collection, self.params)
    params.id = self.params.id

    local data, err = dao_collection:update(params)
    if err then
      return utils.show_error(500, err)
    end
    if data then
      return utils.success(remove_private_properties(data))
    else
      return utils.not_found()
    end
  end))

end

return BaseController
