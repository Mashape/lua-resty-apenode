local blueprints = require "spec.fixtures.blueprints"
local assert = require "luassert"
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy


local dc_blueprints = {}


local null = ngx.null


local function new_config()
  return {
    _format_version = "3.0"
  }
end


local function remove_nulls(tbl)
  for k,v in pairs(tbl) do
    if v == null then
      tbl[k] = nil
    elseif type(v) == "table" then
      tbl[k] = remove_nulls(v)
    end
  end
  return tbl
end


local function wrap_db(db, expand_foreigns)
  local dc_as_db = {}

  local config = new_config()

  for name, _ in pairs(db.daos) do
    dc_as_db[name] = {
      insert = function(_, tbl)
        tbl = cycle_aware_deep_copy(tbl)
        if not config[name] then
          config[name] = {}
        end
        local schema = db.daos[name].schema
        tbl = schema:process_auto_fields(tbl, "insert")
        for fname, field in schema:each_field() do
          if not expand_foreigns and field.type == "foreign" then
            tbl[fname] = type(tbl[fname]) == "table"
                         and tbl[fname].id
                         or nil
          end
        end
        table.insert(config[name], remove_nulls(tbl))
        return cycle_aware_deep_copy(tbl)
      end,
      update = function(_, id, tbl)
        if not config[name] then
          return nil, "not found"
        end
        tbl = cycle_aware_deep_copy(tbl)
        local element
        for _, e in ipairs(config[name]) do
          if e.id == id then
            element = e
            break
          end
        end
        if not element then
          return nil, "not found"
        end
        for k,v in pairs(tbl) do
          element[k] = v
        end
        return element
      end,
      remove = function(_, id)
        assert(id, "id is required")
        if type(id) == "table" then
          id = assert(type(id.id) == "string" and id.id)
        end

        if not config[name] then
          return nil, "not found"
        end

        for idx, entity in ipairs(config[name]) do
          if entity.id == id then
            table.remove(config[name], idx)
            return entity
          end
        end

        return nil, "not found"
      end,
    }
  end

  dc_as_db.export = function()
    return cycle_aware_deep_copy(config)
  end

  dc_as_db.import = function(input)
    config = cycle_aware_deep_copy(input)
  end

  dc_as_db.reset = function()
    config = new_config()
  end

  return dc_as_db
end


function dc_blueprints.new(db, expand_foreigns)
  local dc_as_db = wrap_db(db, expand_foreigns)

  local save_dc = new_config()

  local bp = blueprints.new(dc_as_db)

  bp.done = function()
    local ret = dc_as_db.export()
    save_dc = ret
    dc_as_db.reset()
    return ret
  end

  bp.reset_back = function()
    dc_as_db.import(save_dc)
  end

  return bp
end


function dc_blueprints.admin_api(db, forced_port)
  -- lazy import to avoid cyclical dependency
  local helpers = require "spec.helpers"

  db = db or helpers.db

  local dc_as_db = wrap_db(db)
  local api = {}

  local function update_config()
    local client = helpers.admin_client(nil, forced_port)

    local res = client:post("/config", {
      headers = {
        ["Content-Type"] = "application/json",
      },
      body = dc_as_db.export(),
    })

    assert.response(res).has.status(201)
    client:close()
    return assert.response(res).has.jsonbody()
  end

  for name in pairs(db.daos) do
    local dao = dc_as_db[name]

    api[name] = {
      insert = function(_, entity)
        local res, err = dao:insert(entity)

        if not res then
          return nil, err
        end

        update_config()

        return res
      end,

      update = function(_, id, updates)
        local res, err = dao:update(id, updates)
        if not res then
          return nil, err
        end

        update_config()

        return res
      end,

      remove = function(_, id)
        local res, err = dao:remove(id)
        if not res then
          return nil, err
        end

        update_config()

        return res
      end,

      truncate = function()
        local config = dc_as_db.export()
        config[name] = {}

        dc_as_db.import(config)
        update_config()

        return true
      end,
    }
  end

  return blueprints.new(api)
end

return dc_blueprints
