-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local jwks = {}


function jwks:truncate()
  return self.super.truncate(self)
end


function jwks:select(primary_key, options)
  return self.super.select(self, primary_key, options)
end


function jwks:page(size, offset, options)
  return self.super.page(self, size, offset, options)
end


function jwks:each(size, options)
  return self.super.each(self, size, options)
end


function jwks:insert(entity, options)
  return self.super.insert(self, entity, options)
end


function jwks:update(primary_key, entity, options)
  return self.super.update(self, primary_key, entity, options)
end


function jwks:upsert(primary_key, entity, options)
  return self.super.upsert(self, primary_key, entity, options)
end


function jwks:delete(primary_key, options)
  return self.super.delete(self, primary_key, options)
end


function jwks:select_by_cache_key(cache_key, options)
  return self.super.select_by_cache_key(self, cache_key, options)
end


function jwks:select_by_kid(unique_value, options)
  return self.super.select_by_kid(self, unique_value, options)
end


function jwks:update_by_kid(unique_value, entity, options)
  return self.super.update_by_kid(self, unique_value, entity, options)
end


function jwks:upsert_by_kid(unique_value, entity, options)
  return self.super.upsert_by_kid(self, unique_value, entity, options)
end


function jwks:delete_by_kid(unique_value, options)
  return self.super.delete_by_kid(self, unique_value, options)
end

function jwks:page_for_set(foreign_key, size, offset, options)
  return self.super.page_for_set(self, foreign_key, size, offset, options)
end


function jwks:each_for_set(foreign_key, size, options)
  return self.super.each_for_set(self, foreign_key, size, options)
end


return jwks
