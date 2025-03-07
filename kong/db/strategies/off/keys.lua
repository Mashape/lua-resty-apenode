local Keys = {}

function Keys:select_by_x5t_set_id(x5t, set_id)
  local PAGE_SIZE = 100
  local next_offset = nil
  local rows, err

  repeat
    rows, err, next_offset = self:page(PAGE_SIZE, next_offset)
    if err then
      return nil, err
    end
    for _, row in ipairs(rows) do
      if row.x5t == x5t and row.set.id == set_id then
        return row
      end
    end

  until next_offset == nil

  return nil
end

return Keys
