local _M = {}
local _MT = { __index = _M }


local sub = string.sub
local fmt = string.format
local ngx_null = ngx.null


-- version string should look like: "v02_0000"
local VER_PREFIX = "v02_"
local VERSION_FMT = VER_PREFIX .. "%028x"


function _M.new(db)
  local self = {
    connector = db.connector,
  }

  return setmetatable(self, _MT)
end


-- reserved for future
function _M:init_worker()
end


local NEW_VERSION_QUERY = [[
  DO $$
  DECLARE
    new_version integer;
  BEGIN
    INSERT INTO clustering_sync_version DEFAULT VALUES RETURNING version INTO new_version;
  END $$;
]]


function _M:insert_delta()
  return self.connector:query(NEW_VERSION_QUERY)
end


function _M:get_latest_version()
  local sql = "SELECT MAX(version) FROM clustering_sync_version"

  local res, err = self.connector:query(sql, "read")
  if not res then
    return nil, err
  end

  local ver = res[1] and res[1].max
  if ver == ngx_null then
    return fmt(VERSION_FMT, 0)
  end

  return fmt(VERSION_FMT, ver)
end


function _M:is_valid_version(str)
  return sub(str, 1, 4) == VER_PREFIX
end


function _M:begin_txn()
  return self.connector:query("BEGIN;")
end


function _M:commit_txn()
  return self.connector:query("COMMIT;")
end


function _M:cancel_txn()
  -- we will close the connection, not execute 'ROLLBACK'
  return self.connector:close()
end


return _M
