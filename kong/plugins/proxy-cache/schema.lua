local strategies = require "kong.plugins.proxy-cache.strategies"
local typedefs = require "kong.db.schema.typedefs"


local ngx = ngx


local function check_shdict(name)
  if not ngx.shared[name] then
    return false, "missing shared dict '" .. name .. "'"
  end

  return true
end


return {
  name = "proxy-cache",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { response_code = { description = "Upstream response status code considered cacheable.", type = "array",
            default = { 200, 301, 404 },
            elements = { type = "integer", between = {100, 900} },
            len_min = 1,
            required = true,
          }},
          { request_method = { description = "Downstream request methods considered cacheable.", type = "array",
            default = { "GET", "HEAD" },
            elements = {
              type = "string",
              one_of = { "HEAD", "GET", "POST", "PATCH", "PUT" },
            },
            required = true
          }},
          { content_type = { description = "Upstream response content types considered cacheable. The plugin performs an **exact match** against each specified value.", type = "array",
            default = { "text/plain","application/json" },
            elements = { type = "string" },
            required = true,
          }},
          { cache_ttl = { description = "TTL, in seconds, of cache entities.", type = "integer",
            default = 300,
            gt = 0,
          }},
          { strategy = { description = "The backing data store in which to hold cache entities.", type = "string",
            one_of = strategies.STRATEGY_TYPES,
            required = true,
          }},
          { cache_control = { description = "When enabled, respect the Cache-Control behaviors defined in RFC7234.", type = "boolean",
            default = false,
            required = true,
          }},
          { ignore_uri_case = {
            type = "boolean",
            default = false,
            required = false,
          }},
          { storage_ttl = { description = "Number of seconds to keep resources in the storage backend. This value is independent of `cache_ttl` or resource TTLs defined by Cache-Control behaviors.", type = "integer",
          }},
          { memory = {
            type = "record",
            fields = {
              { dictionary_name = { description = "The name of the shared dictionary in which to hold cache entities when the memory strategy is selected. Note that this dictionary currently must be defined manually in the Kong Nginx template.", type = "string",
                required = true,
                default = "kong_db_cache",
              }},
            },
          }},
          { vary_query_params = { description = "Relevant query parameters considered for the cache key. If undefined, all params are taken into consideration. By default, the max number of params accepted is 100. You can change this value via the `lua_max_post_args` in `kong.conf`.", type = "array",
            elements = { type = "string" },
          }},
          { vary_headers = { description = "Relevant headers considered for the cache key. If undefined, none of the headers are taken into consideration.", type = "array",
            elements = { type = "string" },
          }},
          { response_headers = {
            description = "Caching related diagnostic headers that should be included in cached responses",
            type = "record",
            fields = {
              { age  = {type = "boolean",  default = true} },
              { ["X-Cache-Status"]  = {type = "boolean",  default = true} },
              { ["X-Cache-Key"]  = {type = "boolean",  default = true} },
            },
          }},


        },
      }
    },
  },

  entity_checks = {
    { custom_entity_check = {
      field_sources = { "config" },
      fn = function(entity)
        local config = entity.config

        if config.strategy == "memory" then
          local ok, err = check_shdict(config.memory.dictionary_name)
          if not ok then
            return nil, err
          end

        end

        return true
      end
    }},
  },
}
