local errors = require("kong.db.errors")
local declarative_config = require("kong.db.schema.others.declarative_config")

local validate = declarative_config.validate
local pk_string = declarative_config.pk_string
local validate_references_full = declarative_config.validate_references_full
local validate_references_sync = declarative_config.validate_references_sync


local function validate_deltas(deltas, is_full_sync)

  -- genearte deltas table mapping primary key string to entity item
  local deltas_map = {}

  -- generate declarative config table
  local dc_table = { _format_version = "3.0", }

  for _, delta in ipairs(deltas) do
    local delta_type = delta.type
    local delta_entity = delta.entity

    if delta_entity ~= nil and delta_entity ~= ngx.null then
      dc_table[delta_type] = dc_table[delta_type] or {}

      table.insert(dc_table[delta_type], delta_entity)

      -- table: primary key string -> entity
      if not is_full_sync then
        local schema = kong.db[delta_type].schema
        local pk = schema:extract_pk_values(delta_entity)
        local pks = pk_string(schema, pk)

        deltas_map[pks] = delta_entity
      end
    end
  end

  -- validate schema
  local dc_schema = kong.db.declarative_config.schema

  local ok, err_t = validate(dc_schema, dc_table)
  if not ok then
    return nil, errors:schema_violation(err_t)
  end

  -- validate references for full sync
  if is_full_sync then
    local ok, err_t = validate_references_full(dc_schema, dc_table)
    if not ok then
      return nil, errors:schema_violation(err_t)
    end
    return true
  end

  -- validate references for non full sync
  local ok, err_t = validate_references_sync(deltas, deltas_map)
  if not ok then
    return nil, errors:schema_violation(err_t)
  end

  return true
end


return {
  validate_deltas = validate_deltas,
}
