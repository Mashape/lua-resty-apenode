local pkey = require("resty.openssl.pkey")
local fmt = string.format
local type = type

local keys = {}


function keys:truncate()
  return self.super.truncate(self)
end

function keys:select(primary_key, options)
  return self.super.select(self, primary_key, options)
end

function keys:page(size, offset, options)
  return self.super.page(self, size, offset, options)
end

function keys:each(size, options)
  return self.super.each(self, size, options)
end

function keys:insert(entity, options)
  return self.super.insert(self, entity, options)
end

function keys:update(primary_key, entity, options)
  return self.super.update(self, primary_key, entity, options)
end

function keys:upsert(primary_key, entity, options)
  return self.super.upsert(self, primary_key, entity, options)
end

function keys:delete(primary_key, options)
  return self.super.delete(self, primary_key, options)
end

function keys:select_by_cache_key(cache_key, options)
  return self.super.select_by_cache_key(self, cache_key, options)
end

function keys:page_for_set(foreign_key, size, offset, options)
  return self.super.page_for_set(self, foreign_key, size, offset, options)
end

function keys:each_for_set(foreign_key, size, options)
  return self.super.each_for_set(self, foreign_key, size, options)
end

---Keys cache_key function
---@param key table
---@return string
function keys:cache_key(key)
  assert(type(key), "table")
  local kid, set_id
  kid = key.kid
  if type(key.set) == "table" then
    set_id = key.set.id
  end
  if not set_id then
    set_id = ""
  end
  -- ignore ws_id, kid+set is unique
  return fmt("keys:%s:%s", tostring(kid), set_id)
end

-- load to lua-resty-openssl pkey module
local function _load_pkey(key, part)
  local pk, err
  if part == "public" then part = "public_key" end
  if part == "private" then part = "private_key" end

  if key.jwk then
    pk, err = pkey.new(key.jwk, { format = "JWK" })
  end
  if key.pem then
    -- public key can be derived from private key, but not vice versa
    if part == "private_key" and not key.pem[part] then
      return nil, "could not load a private key from public key material"
    end
    pk, err = pkey.new(key.pem[part], { format = "PEM" })
  end
  if not pk then
    return nil, "could not load pkey. " .. err
  end

  if part == "private_key" and not pk:is_private() then
    return nil, "could not load a private key from public key material"
  end

  return pk
end

local function _key_format(key)
  -- no nil checks needed. schema validation ensures on of these
  -- entries to be present.
  if key.jwk then
    return "JWK"
  end
  if key.pem then
    return "PEM"
  end
end

local function _get_key(key, part)
  if part ~= "public" and part ~= "private" then
    return nil, "part needs to be public or private"
  end
  -- pkey expects uppercase formats
  local k_fmt = _key_format(key)

  local pk, err = _load_pkey(key, part)
  if not pk or err then
    return nil, err
  end
  return pk:tostring(part, k_fmt)
end

-- getter for public key
function keys:get_pubkey(key)
  return _get_key(key, "public")
end

-- getter for private key
function keys:get_privkey(key)
  return _get_key(key, "private")
end

-- @x5t: the x5t of key to be searched
-- @set_id: the id of the set the searched key belongs to
-- @return the key entity
function keys:select_by_x5t_set_id(x5t, set_id)
  local x5t_type = type(x5t)
  local set_id_type = type(set_id)
  if x5t_type ~= "string" then
    return nil, "parameter `x5t` must be of type string"
  end
  if set_id_type ~= "string" and set_id_type ~= "nil" then
    return nil, "parameter `set_id` must be of type string or nil"
  end

  local key, err = self.strategy:select_by_x5t_set_id(x5t, set_id)
  if not key then
    return nil, err
  end

  return self:row_to_entity(key), nil
end


return keys
