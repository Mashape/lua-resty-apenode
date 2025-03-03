local kong = kong
local fmt  = string.format

local Keys = {}

function Keys:select_by_x5t_set_id(x5t, set_id)
  local qs
  if set_id then
    qs = fmt(
      "SELECT * FROM keys WHERE x5t = %s AND set_id = %s;",
      kong.db.connector:escape_literal(x5t),
      kong.db.connector:escape_literal(set_id))
  else
    qs = fmt(
      "SELECT * FROM keys WHERE x5t = %s AND set_id IS NULL;",
      kong.db.connector:escape_literal(x5t))
  end

  local res, err = kong.db.connector:query(qs, "read")
  if err then
    return nil, err
  end

  return res and res[1]
end

return Keys
