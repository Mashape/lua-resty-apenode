---
-- Vault module
--
-- This module can be used to resolve, parse and verify vault references.
--
-- @module kong.vault


local require = require


local concurrency = require "kong.concurrency"
local constants = require "kong.constants"
local arguments = require "kong.api.arguments"
local lrucache = require "resty.lrucache"
local isempty = require "table.isempty"
local buffer = require "string.buffer"
local clone = require "table.clone"
local cjson = require("cjson.safe").new()


local yield = require("kong.tools.yield").yield
local get_updated_now_ms = require("kong.tools.time").get_updated_now_ms
local replace_dashes = require("kong.tools.string").replace_dashes


local ngx = ngx
local get_phase = ngx.get_phase
local max = math.max
local min = math.min
local fmt = string.format
local sub = string.sub
local byte = string.byte
local type = type
local sort = table.sort
local pcall = pcall
local lower = string.lower
local pairs = pairs
local ipairs = ipairs
local concat = table.concat
local md5_bin = ngx.md5_bin
local tostring = tostring
local tonumber = tonumber
local decode_args = ngx.decode_args
local unescape_uri = ngx.unescape_uri
local parse_url = require("socket.url").parse
local parse_path = require("socket.url").parse_path
local encode_base64url = require("ngx.base64").encode_base64url
local decode_json = cjson.decode


local NEGATIVELY_CACHED_VALUE = "\0"
local ROTATION_INTERVAL = tonumber(os.getenv("KONG_VAULT_ROTATION_INTERVAL"), 10) or 60
local DAO_MAX_TTL = constants.DATABASE.DAO_MAX_TTL


local BRACE_START = byte("{")
local BRACE_END = byte("}")
local COLON = byte(":")
local SLASH = byte("/")
local BYT_V = byte("v")
local BYT_A = byte("a")
local BYT_U = byte("u")
local BYT_L = byte("l")
local BYT_T = byte("t")


local VAULT_QUERY_OPTS = { workspace = ngx.null }


---
-- Checks if the passed in reference looks like a reference.
-- Valid references start with '{vault://' and end with '}'.
--
-- @local
-- @function is_reference
-- @tparam string reference reference to check
-- @treturn boolean `true` is the passed in reference looks like a reference, otherwise `false`
local function is_reference(reference)
  return type(reference)     == "string"
     and byte(reference, 1)  == BRACE_START
     and byte(reference, 2)  == BYT_V
     and byte(reference, 3)  == BYT_A
     and byte(reference, 4)  == BYT_U
     and byte(reference, 5)  == BYT_L
     and byte(reference, 6)  == BYT_T
     and byte(reference, 7)  == COLON
     and byte(reference, 8)  == SLASH
     and byte(reference, 9)  == SLASH
     and byte(reference, -1) == BRACE_END
end


---
-- Parses and decodes the passed in reference and returns a table
-- containing its components.
--
-- Given a following resource:
-- ```lua
-- "{vault://env/cert/key?prefix=SSL_#1}"
-- ```
--
-- This function will return following table:
--
-- ```lua
-- {
--   name     = "env",  -- name of the Vault entity or Vault strategy
--   resource = "cert", -- resource where secret is stored
--   key      = "key",  -- key to lookup if the resource is secret object
--   config   = {       -- if there are any config options specified
--     prefix = "SSL_"
--   },
--   version  = 1       -- if the version is specified
-- }
-- ```
--
-- @local
-- @function parse_reference
-- @tparam string reference reference to parse
-- @treturn table|nil a table containing each component of the reference, or `nil` on error
-- @treturn string|nil error message on failure, otherwise `nil`
local function parse_reference(reference)
  if not is_reference(reference) then
    return nil, fmt("not a reference [%s]", tostring(reference))
  end

  local url, err = parse_url(sub(reference, 2, -2))
  if not url then
    return nil, fmt("reference is not url (%s) [%s]", err, reference)
  end

  local name = url.host
  if not name then
    return nil, fmt("reference url is missing host [%s]", reference)
  end

  local path = url.path
  if not path then
    return nil, fmt("reference url is missing path [%s]", reference)
  end

  local resource = sub(path, 2)
  if resource == "" then
    return nil, fmt("reference url has empty path [%s]", reference)
  end

  local version = url.fragment
  if version then
    version = tonumber(version, 10)
    if not version then
      return nil, fmt("reference url has invalid version [%s]", reference)
    end
  end

  local key
  local parts = parse_path(resource)
  local count = #parts
  if count == 0 then
    return nil, fmt("reference url has invalid path [%s]", reference)
  elseif count == 1 then
    resource = unescape_uri(parts[1])
  elseif parts.is_directory then
    resource = unescape_uri(concat(parts, "/", 1, count))
  else
    resource = unescape_uri(concat(parts, "/", 1, count - 1))
    key = unescape_uri(parts[count])
  end

  local config
  local query = url.query
  if query and query ~= "" then
    config = decode_args(query)
  end

  return {
    name = url.host,
    resource = resource,
    key = key,
    config = config,
    version = version,
  }
end


---
-- Create a instance of PDK Vault module
--
-- @local
-- @function new
-- @tparam table self a PDK instance
-- @treturn table a new instance of Vault
local function new(self)
  -- Don't put this onto the top level of the file unless you're prepared for a surprise
  local Schema = require "kong.db.schema"

  local ROTATION_MUTEX_OPTS = {
    name = "vault-rotation",
    exptime = ROTATION_INTERVAL * 1.5, -- just in case the lock is not properly released
    timeout = 0, -- we don't want to wait for release as we run a recurring timer
  }

  local LRU = lrucache.new(1000)
  local RETRY_LRU = lrucache.new(1000)

  local SECRETS_CACHE = ngx.shared.kong_secrets
  local SECRETS_CACHE_MIN_TTL = ROTATION_INTERVAL * 2

  local INIT_SECRETS = {}
  local INIT_WORKER_SECRETS = {}
  local STRATEGIES = {}
  local SCHEMAS = {}
  local CONFIGS = {}

  local BUNDLED_VAULTS = constants.BUNDLED_VAULTS
  local VAULT_NAMES
  do
    local vaults = self and self.configuration and self.configuration.loaded_vaults
    if vaults then
      VAULT_NAMES = {}

      for name in pairs(vaults) do
        VAULT_NAMES[name] = true
      end

    else
      VAULT_NAMES = BUNDLED_VAULTS and clone(BUNDLED_VAULTS) or {}
    end
  end


  ---
  -- Calculates hash for a string.
  --
  -- @local
  -- @function calculate_hash
  -- @tparam string str a string to hash
  -- @treturn string md5 hash as base64url encoded string
  local function calculate_hash(str)
    return encode_base64url(md5_bin(str))
  end


  ---
  -- Builds cache key from reference and configuration hash.
  --
  -- @local
  -- @function build_cache_key
  -- @tparam string reference the vault reference string
  -- @tparam string config_hash the configuration hash
  -- @treturn string the cache key for shared dictionary cache
  local function build_cache_key(reference, config_hash)
    return config_hash .. "." .. reference
  end


  ---
  -- Parses cache key back to a reference and a configuration hash.
  --
  -- @local
  -- @function parse_cache_key
  -- @tparam string cache_key the cache key used for shared dictionary cache
  -- @treturn string|nil the vault reference string
  -- @treturn string|nil a string describing an error if there was one
  -- @treturn string the configuration hash
  local function parse_cache_key(cache_key)
    local buf = buffer.new():set(cache_key)
    local config_hash = buf:get(22)
    local divider = buf:get(1)
    local reference = buf:get()
    if divider ~= "." or not is_reference(reference) then
      return nil, "invalid cache key (" .. cache_key .. ")"
    end
    return reference, nil, config_hash
  end


  ---
  -- This function extracts a key and returns its value from a JSON object.
  --
  -- It first decodes the JSON string into a Lua table, then checks for the presence and type of a specific key.
  --
  -- @local
  -- @function extract_key_from_json_string
  -- @tparam string json_string the JSON string to be parsed and decoded
  -- @tparam string key the specific subfield to be searched for within the JSON object
  -- @treturn string|nil the value associated with the specified key in the JSON object
  -- @treturn string|nil a string describing an error if there was one
  local function extract_key_from_json_string(json_string, key)
    -- Note that this function will only find keys in flat maps.
    -- Deeper nested structures are not supported.
    local json, err = decode_json(json_string)
    if type(json) ~= "table" then
      return nil, fmt("unable to json decode value (%s): %s", json, err)
    end

    json_string = json[key]
    if json_string == nil then
      return nil, fmt("subfield %s not found in JSON secret", key)
    elseif type(json_string) ~= "string" then
      return nil, fmt("unexpected %s value in JSON secret for subfield %s", type(json_string), key)
    end

    return json_string
  end


  ---
  -- This function adjusts the 'time-to-live' (TTL) according to the configuration provided in 'vault_config'.
  --
  -- If the TTL is not a number or if it falls outside of the configured minimum or maximum TTL,
  -- it will be adjusted accordingly. The adjustment happens on Vault strategy returned TTL values only.
  --
  -- @local
  -- @function adjust_ttl
  -- @tparam number|nil ttl The time-to-live value to be adjusted.
  -- @tparam table|nil config the configuration table for the vault,
  -- which may contain 'ttl', 'min_ttl', and 'max_ttl' fields.
  -- @treturn number returns the adjusted TTL:
  -- * if the initial TTL is not a number, it returns the 'ttl' field from the 'vault_config' table or 0 if it doesn't exist.
  -- * if the initial TTL is greater than 'max_ttl' from 'vault_config', it returns 'max_ttl'.
  -- * if the initial TTL is less than 'min_ttl' from 'vault_config', it returns 'min_ttl'.
  -- * otherwise, it returns the given TTL.
  local function adjust_ttl(ttl, config)
    if type(ttl) ~= "number" then
      return config and config.ttl or DAO_MAX_TTL
    end

    if ttl <= 0 then
      -- for simplicity, we don't support never expiring keys
      return DAO_MAX_TTL
    end

    local max_ttl = config and config.max_ttl
    if max_ttl and max_ttl > 0 and ttl > max_ttl then
      return max_ttl
    end

    local min_ttl = config and config.min_ttl
    if min_ttl and ttl < min_ttl then
      return min_ttl
    end

    return ttl
  end


  ---
  -- Decorates normal strategy with a caching strategy when rotating secrets.
  --
  -- With vault strategies we support JSON string responses, that means that
  -- the vault can return n-number of related secrets, for example Postgres
  -- username and password. The references could look like:
  --
  -- - {vault://my-vault/postgres/username}
  -- - {vault://my-vault/postgres/password}
  --
  -- For LRU cache we use ´{vault://my-vault/postgres/username}` as a cache
  -- key and for SHM we use `<config-hash>.{vault://my-vault/postgres/username}`
  -- as a cache key. What we send to vault are:
  --
  -- 1. the config table
  -- 2. the resource to lookup
  -- 3. the version of secret
  --
  -- In the above references in both cases the `resource` is `postgres` and we
  -- never send `/username` or `/password` to vault strategy. Thus the proper
  -- cache key for vault strategy is: `<config-hash>.<resource>.<version>`.
  -- This means that we can call the vault strategy just once, and not twice
  -- to resolve both references. This also makes sure we get both secrets in
  -- atomic way.
  --
  -- The caching strategy wraps the strategy so that call to it can be cached
  -- when e.g. looping through secrets on rotation. Again that ensures atomicity,
  -- and reduces calls to actual vault.
  --
  -- @local
  -- @function get_caching_strategy
  -- @treturn function returns a function that takes `strategy` and `config_hash`
  -- as an argument, that returns a decorated strategy.
  --
  -- @usage
  -- local caching_strategy = get_caching_strategy()
  -- for _, reference in ipairs({ "{vault://my-vault/postgres/username}",
  --                              "{vault://my-vault/postgres/username}", })
  -- do
  --   local strategy, err, config, _, parsed_reference, config_hash = get_strategy(reference)
  --   strategy = caching_strategy(strategy, config_hash)
  --   local value, err, ttl = strategy.get(config, parsed_reference.resource, parsed_reference.version)
  -- end
  local function get_caching_strategy()
    local cache = {}
    return function(strategy, config_hash)
      return {
        get = function(config, resource, version)
          local cache_key = fmt("%s.%s.%s", config_hash, resource or "", version or "")
          local data = cache[cache_key]
          if data then
            return data[1], data[2], data[3]
          end

          local value, err, ttl = strategy.get(config, resource, version)

          cache[cache_key] = {
            value,
            err,
            ttl,
          }

          return value, err, ttl
        end
      }
    end
  end


  ---
  -- Build schema aware configuration out of base configuration and the configuration overrides
  -- (e.g. configuration parameters stored in a vault reference).
  --
  -- It infers and validates configuration fields, and only returns validated fields
  -- in the returned config. It also calculates a deterministic configuration hash
  -- that will can used to build  shared dictionary's cache key.
  --
  -- @local
  -- @function get_vault_config_and_hash
  -- @tparam string name the name of vault strategy
  -- @tparam table schema the scheme of vault strategy
  -- @tparam table base_config the base configuration
  -- @tparam table|nil config_overrides the configuration overrides
  -- @treturn table validated and merged configuration from base configuration and config overrides
  -- @treturn string calculated hash of the configuration
  --
  -- @usage
  -- local config, hash = get_vault_config_and_hash("env", schema, { prefix = "DEFAULT_" },
  --                                                               { prefix = "MY_PREFIX_" })
  local get_vault_config_and_hash do
    local CONFIG_HASH_BUFFER = buffer.new(100)
    get_vault_config_and_hash = function(name, schema, base_config, config_overrides)
      CONFIG_HASH_BUFFER:reset():putf("%s;", name)
      local config = {}
      config_overrides = config_overrides or config
      for k, f in schema:each_field() do
        local v = config_overrides[k] or base_config[k]
        v = arguments.infer_value(v, f)
        if v ~= nil and schema:validate_field(f, v) then
          config[k] = v
          CONFIG_HASH_BUFFER:putf("%s=%s;", k, v)
        end
      end
      return config, calculate_hash(CONFIG_HASH_BUFFER:get())
    end
  end


  ---
  -- Fetches the strategy and schema for a given vault.
  --
  -- This function fetches the associated strategy and schema from the `STRATEGIES` and `SCHEMAS` tables,
  -- respectively. If the strategy or schema isn't found in the tables, it attempts to initialize them
  -- from the Lua modules.
  --
  -- @local
  -- @function get_vault_strategy_and_schema
  -- @tparam string name the name of the vault to fetch the strategy and schema for
  -- @treturn table|nil the fetched or required strategy for the given vault
  -- @treturn string|nil an error message, if an error occurred while fetching or requiring the strategy or schema
  -- @treturn table|nil the vault strategy's configuration schema.
  local function get_vault_strategy_and_schema(name)
    local strategy = STRATEGIES[name]
    local schema = SCHEMAS[name]

    if strategy then
      return strategy, nil, schema
    end

    local vaults = self and (self.db and self.db.vaults)
    if vaults and vaults.strategies then
      strategy = vaults.strategies[name]
      if not strategy then
        return nil, fmt("could not find vault (%s)", name)
      end

      schema = vaults.schema.subschemas[name]
      if not schema then
        return nil, fmt("could not find vault schema (%s): %s", name, strategy)
      end

      schema = Schema.new(schema.fields.config)

    else
      local ok
      ok, strategy = pcall(require, fmt("kong.vaults.%s", name))
      if not ok then
        return nil, fmt("could not find vault (%s): %s", name, strategy)
      end

      local def
      ok, def = pcall(require, fmt("kong.vaults.%s.schema", name))
      if not ok then
        return nil, fmt("could not find vault schema (%s): %s", name, def)
      end

      schema = Schema.new(require("kong.db.schema.entities.vaults"))

      local err
      ok, err = schema:new_subschema(name, def)
      if not ok then
        return nil, fmt("could not load vault sub-schema (%s): %s", name, err)
      end

      schema = schema.subschemas[name]
      if not schema then
        return nil, fmt("could not find vault sub-schema (%s)", name)
      end

      if type(strategy.init) == "function" then
        strategy.init()
      end

      schema = Schema.new(schema.fields.config)
    end

    STRATEGIES[name] = strategy
    SCHEMAS[name] = schema

    return strategy, nil, schema
  end


  ---
  -- This function retrieves the base configuration for the default vault
  -- using the vault strategy name.
  --
  -- The vault configuration is stored in Kong configuration from which this
  -- function derives the default base configuration for the vault strategy.
  --
  -- @local
  -- @function get_vault_name_and_config_by_name
  -- @tparam string name The unique name of the vault strategy
  -- @treturn string name of the vault strategy (same as the input string)
  -- @treturn nil this never fails so it always returns `nil`
  -- @treturn table|nil the vault strategy's base config derived from Kong configuration
  --
  -- @usage
  -- local name, err, base_config = get_vault_name_and_config_by_name("env")
  local function get_vault_name_and_config_by_name(name)
    -- base config stays the same so we can cache it
    local base_config = CONFIGS[name]
    if not base_config then
      base_config = {}
      if self and self.configuration then
        local configuration = self.configuration
        local env_name = replace_dashes(name)
        local _, err, schema = get_vault_strategy_and_schema(name)
        if not schema then
          return nil, err
        end
        for k, f in schema:each_field() do
          -- n is the entry in the kong.configuration table, for example
          -- KONG_VAULT_ENV_PREFIX will be found in kong.configuration
          -- with a key "vault_env_prefix". Environment variables are
          -- thus turned to lowercase and we just treat any "-" in them
          -- as "_". For example if your custom vault was called "my-vault"
          -- then you would configure it with KONG_VAULT_MY_VAULT_<setting>
          -- or in kong.conf, where it would be called
          -- "vault_my_vault_<setting>".
          local n = lower(fmt("vault_%s_%s", env_name, replace_dashes(k)))
          local v = configuration[n]
          v = arguments.infer_value(v, f)
          -- TODO: should we be more visible with validation errors?
          -- In general it would be better to check the references
          -- and not just a format when they are stored with admin
          -- API, or in case of process secrets, when the kong is
          -- started. So this is a note to remind future us.
          -- Because current validations are less strict, it is fine
          -- to ignore it here.
          if v ~= nil and schema:validate_field(f, v) then
            base_config[k] = v
          elseif f.required and f.default ~= nil then
            base_config[k] = f.default
          end
        end
        CONFIGS[name] = base_config
      end
    end

    return name, nil, base_config
  end


  ---
  -- This function retrieves a vault entity by its prefix from configuration
  -- database, and returns the strategy name and the base configuration.
  --
  -- It either fetches the vault from a cache or directly from a configuration
  -- database. The vault entity is expected to be found in a database (db) or
  -- cache. If not found, an error message is returned.
  --
  -- @local
  -- @function get_vault_name_and_config_by_prefix
  -- @tparam string prefix the unique identifier of the vault entity to be retrieved
  -- @treturn string|nil name of the vault strategy
  -- @treturn string|nil a string describing an error if there was one
  -- @treturn table|nil the vault entity config
  --
  -- @usage
  -- local name, err, base_config = get_vault_name_and_config_by_prefix("my-vault")
  local function get_vault_name_and_config_by_prefix(prefix)
    if not (self and self.db) then
      return nil, "unable to retrieve config from db"
    end

    -- find a vault - it can be either a named vault that needs to be loaded from the cache, or the
    -- vault type accessed by name
    local cache = self.core_cache
    local vaults = self.db.vaults
    local vault, err

    if cache then
      local vault_cache_key = vaults:cache_key(prefix)
      vault, err = cache:get(vault_cache_key, nil, vaults.select_by_prefix, vaults, prefix, VAULT_QUERY_OPTS)

    else
      vault, err = vaults:select_by_prefix(prefix, VAULT_QUERY_OPTS)
    end

    if not vault then
      if err then
        return nil, fmt("could not find vault (%s): %s", prefix, err)
      end

      return nil, fmt("could not find vault (%s)", prefix)
    end

    return vault.name, nil, vault.config
  end


  ---
  -- Function `get_vault_name_and_base_config` retrieves name of the strategy
  -- and its base configuration using name (for default vaults) or prefix for
  -- database stored vault entities.
  --
  -- @local
  -- @function get_vault_name_and_base_config
  -- @tparam string name_or_prefix name of the vault strategy or prefix of the vault entity
  -- @treturn string|nil name of the vault strategy
  -- @treturn string|nil a string describing an error if there was one
  -- @treturn table|nil the base configuration
  --
  -- @usage
  -- local name, err, base_config = get_vault_name_and_base_config("env")
  local function get_vault_name_and_base_config(name_or_prefix)
    if VAULT_NAMES[name_or_prefix] then
      return get_vault_name_and_config_by_name(name_or_prefix)
    end

    return get_vault_name_and_config_by_prefix(name_or_prefix)
  end


  ---
  -- Function `get_strategy` processes a reference to retrieve a strategy and configuration settings.
  --
  -- The function first parses the reference. Then, it gets the strategy, the schema, and the base configuration
  -- settings for the vault based on the parsed reference. It checks the license type if required by the strategy.
  -- Finally, it gets the configuration and the cache key of the reference.
  --
  -- @local
  -- @function get_strategy
  -- @tparam string reference the reference to be used to load strategy and its settings.
  -- @tparam table|nil strategy the strategy used to fetch the secret
  -- @treturn string|nil a string describing an error if there was one
  -- @treturn table|nil the vault configuration for the reference
  -- @treturn string|nil the cache key for shared dictionary for the reference
  -- @treturn table|nil the parsed reference
  --
  -- @usage
  -- local strategy, err, config, cache_key, parsed_reference = get_strategy(reference)
  local function get_strategy(reference)
    local parsed_reference, err = parse_reference(reference)
    if not parsed_reference then
      return nil, err
    end

    local name, err, base_config = get_vault_name_and_base_config(parsed_reference.name)
    if not name then
      return nil, err
    end

    local strategy, err, schema = get_vault_strategy_and_schema(name)
    if not strategy then
      return nil, err
    end

    if strategy.license_required and self.licensing and self.licensing:license_type() == "free" then
      return nil, "vault " .. name .. " requires a license to be used"
    end

    local config, config_hash = get_vault_config_and_hash(name, schema, base_config, parsed_reference.config)
    local cache_key = build_cache_key(reference, config_hash)

    return strategy, nil, config, cache_key, parsed_reference, config_hash
  end


  ---
  -- Invokes a provided strategy to fetch a secret.
  --
  -- This function invokes a strategy provided to it to retrieve a secret from a vault.
  -- The secret returned by the strategy must be a string containing a string value,
  -- or JSON string containing the required key with a string value.
  --
  -- @local
  -- @function invoke_strategy
  -- @tparam table strategy the strategy used to fetch the secret
  -- @tparam config the configuration required by the strategy
  -- @tparam parsed_reference a table containing the resource name, the version of the secret
  -- to be fetched, and optionally a key to search on returned JSON string
  -- @treturn string|nil the value of the secret, or `nil`
  -- @treturn string|nil a string describing an error if there was one
  -- @treturn number|nil a ttl (time to live) of the fetched secret if there was one
  --
  -- @usage
  -- local value, err, ttl = invoke_strategy(strategy, config, parsed_reference)
  local function invoke_strategy(strategy, config, parsed_reference)
    local value, err, ttl = strategy.get(config, parsed_reference.resource, parsed_reference.version)
    if value == nil then
      if err then
        return nil, fmt("no value found (%s)", err)
      end

      return nil, "no value found"

    elseif type(value) ~= "string" then
      return nil, fmt("value returned from vault has invalid type (%s), string expected", type(value))
    end

    -- in vault reference, the secret can have multiple values, each stored under a key.
    -- The vault returns a JSON string that contains an object which can be indexed by the key.
    local key = parsed_reference.key
    if key then
      value, err = extract_key_from_json_string(value, key)
      if not value then
        return nil, fmt("could not get subfield value: %s", err)
      end
    end

    return value, nil, ttl
  end

  ---
  -- Function `get_cache_value_and_ttl` returns a value for caching and its ttl
  --
  -- @local
  -- @function get_cache_value_and_ttl
  -- @tparam string value the vault returned value for a reference
  -- @tparam table config the configuration settings to be used
  -- @tparam[opt] number ttl the possible vault returned ttl
  -- @treturn string value to be stored in shared dictionary
  -- @treturn number shared dictionary ttl
  -- @treturn number lru ttl
  -- @usage local cache_value, shdict_ttl, lru_ttl = get_cache_value_and_ttl(value, config, ttl)
  local function get_cache_value_and_ttl(value, config, ttl)
    local cache_value, shdict_ttl, lru_ttl
    if value then
      cache_value = value

      -- adjust ttl to the minimum and maximum values configured
      ttl = adjust_ttl(ttl, config)

      if config.resurrect_ttl then
        lru_ttl = min(ttl + config.resurrect_ttl, DAO_MAX_TTL)
        shdict_ttl = max(lru_ttl, SECRETS_CACHE_MIN_TTL)

      else
        lru_ttl = ttl
        -- shared dict ttl controls when the secret
        -- value will be refreshed by `rotate_secrets`
        -- timer. If a secret whose remaining time is less
        -- than `config.resurrect_ttl`(or DAO_MAX_TTL
        -- if not configured), it could possibly
        -- be updated in every cycle of `rotate_secrets`.
        --
        -- The shdict_ttl should be
        -- `config.ttl` + `config.resurrect_ttl`
        -- to make sure the secret value persists for
        -- at least `config.ttl` seconds.
        -- When `config.resurrect_ttl` is not set and
        -- `config.ttl` is not set, shdict_ttl will be
        -- DAO_MAX_TTL * 2; when `config.resurrect_ttl`
        -- is not set but `config.ttl` is set, shdict_ttl
        -- will be ttl + DAO_MAX_TTL
        shdict_ttl = ttl + DAO_MAX_TTL
      end

    else
      cache_value = NEGATIVELY_CACHED_VALUE

      -- negatively cached values will be rotated on each rotation interval
      shdict_ttl = max(config.neg_ttl or 0, SECRETS_CACHE_MIN_TTL)
    end

    return cache_value, shdict_ttl, lru_ttl
  end


  ---
  -- Function `get_from_vault` retrieves a value from the vault using the provided strategy.
  --
  -- The function first retrieves a value from the vault and its optionally returned ttl.
  -- It then adjusts the ttl within configured bounds, stores the value in the SHDICT cache
  -- with a ttl that includes a resurrection time, and stores the value in the LRU cache with
  -- the adjusted ttl.
  --
  -- @local
  -- @function get_from_vault
  -- @tparam string reference the vault reference string
  -- @tparam table strategy the strategy to be used to retrieve the value from the vault
  -- @tparam table config the configuration settings to be used
  -- @tparam string cache_key the cache key used for shared dictionary cache
  -- @tparam table parsed_reference the parsed reference
  -- @treturn string|nil the retrieved value from the vault, of `nil`
  -- @treturn string|nil a string describing an error if there was one
  -- @treturn boolean|nil whether to resurrect value in case vault errors or doesn't return value
  -- @usage local value, err = get_from_vault(reference, strategy, config, cache_key, parsed_reference)
  local function get_from_vault(reference, strategy, config, cache_key, parsed_reference, resurrect)
    local value, err, ttl = invoke_strategy(strategy, config, parsed_reference)
    if resurrect and value == nil then
      local resurrected_value = SECRETS_CACHE:get(cache_key)
      if resurrected_value then
        return resurrected_value

      else
        return nil, fmt("could not get value from external vault (%s)", err)
      end
    end

    local cache_value, shdict_ttl, lru_ttl = get_cache_value_and_ttl(value, config, ttl)
    local ok, cache_err = SECRETS_CACHE:safe_set(cache_key, cache_value, shdict_ttl)
    if not ok then
      return nil, cache_err
    end

    if cache_value == NEGATIVELY_CACHED_VALUE then
      return nil, fmt("could not get value from external vault (%s)", err)
    end

    LRU:set(reference, cache_value, lru_ttl)

    return cache_value
  end


  ---
  -- Function `get` retrieves a value from local (LRU), shared dictionary (SHDICT) cache.
  --
  -- If the value is not found in these caches and `cache_only` is not `truthy`,
  -- it attempts to retrieve the value from a vault.
  --
  -- On init worker phase the resolving of the secrets is postponed to a timer,
  -- and in this case the function returns `""` when it fails to find a value
  -- in a cache. This is because of current limitations in platform that disallows
  -- using cosockets/coroutines in that phase.
  --
  -- @local
  -- @function get
  -- @tparam string reference the reference key to lookup
  -- @tparam[opt] boolean cache_only optional boolean flag (if set to `true`,
  -- the function will not attempt to retrieve the value from the vault)
  -- @treturn string the retrieved value corresponding to the provided reference,
  -- or `nil` (when found negatively cached, or in case of an error)
  -- @treturn string a string describing an error if there was one
  --
  -- @usage
  -- local value, err = get(reference, cache_only)
  local function get(reference, cache_only)
    -- the LRU stale value is ignored
    local value = LRU:get(reference)
    if value then
      return value
    end

    local strategy, err, config, cache_key, parsed_reference = get_strategy(reference)
    if not strategy then
      -- this can fail on init as the lmdb cannot be accessed and secondly,
      -- because the data is not yet inserted into LMDB when using KONG_DECLARATIVE_CONFIG.
      if get_phase() == "init" then
        if not INIT_SECRETS[cache_key] then
          INIT_SECRETS[reference] = true
          INIT_SECRETS[#INIT_SECRETS + 1] = reference
        end

        return ""
      end

      return nil, err
    end

    value = SECRETS_CACHE:get(cache_key)
    if value == NEGATIVELY_CACHED_VALUE then
      return nil
    end

    if not value then
      if cache_only then
        return nil, "could not find cached value"
      end

      -- this can fail on init worker as there is no cosockets / coroutines available
      if  get_phase() == "init_worker" then
        if not INIT_WORKER_SECRETS[cache_key] then
          INIT_WORKER_SECRETS[cache_key] = true
          INIT_WORKER_SECRETS[#INIT_WORKER_SECRETS + 1] = cache_key
        end

        return ""
      end

      return get_from_vault(reference, strategy, config, cache_key, parsed_reference)
    end

    -- if we have something in the node-level cache, but not in the worker-level
    -- cache, we should update the worker-level cache. Use the remaining TTL from the SHDICT
    local lru_ttl = (SECRETS_CACHE:ttl(cache_key) or 0) - (config.resurrect_ttl or DAO_MAX_TTL)
    -- only do that when the TTL is greater than 0.
    if lru_ttl > 0 then
      LRU:set(reference, value, lru_ttl)
    end

    return value
  end


  ---
  -- In place updates record's field from a cached reference.
  --
  -- @local
  -- @function update_from_cache
  -- @tparam string reference reference to look from the caches
  -- @tparam table record record which field is updated from caches
  -- @tparam string field name of the field
  --
  -- @usage
  -- local record = { field = "old-value" }
  -- update_from_cache("{vault://env/example}", record, "field" })
  local function update_from_cache(reference, record, field)
    local value, err = get(reference, true)
    if err then
      self.log.warn("error updating secret reference ", reference, ": ", err)
    else
      record[field] = value or ""
    end
  end


  ---
  -- Recurse over config and calls the callback for each found reference.
  --
  -- @local
  -- @function recurse_config_refs
  -- @tparam table config config table to recurse.
  -- @tparam function callback callback to call on each reference.
  -- @treturn table config that might have been updated, depending on callback.
  local function recurse_config_refs(config, callback)
    -- silently ignores other than tables
    if type(config) ~= "table" then
      return config
    end

    for key, value in pairs(config) do
      if key ~= "$refs" and type(value) == "table" then
        recurse_config_refs(value, callback)
      end
    end

    local references = config["$refs"]
    if type(references) ~= "table" or isempty(references) then
      return config
    end

    for name, reference in pairs(references) do
      if type(reference) == "string" then -- a string reference
        callback(reference, config, name)

      elseif type(reference) == "table" then -- array, set or map of references
        for key, ref in pairs(reference) do
          callback(ref, config[name], key)
        end
      end
    end

    return config
  end


  ---
  -- Function `update` recursively updates a configuration table.
  --
  -- This function recursively in-place updates a configuration table by
  -- replacing reference fields with values fetched from a cache. The references
  -- are specified in a `$refs` field.
  --
  -- If a reference cannot be fetched from the cache, the corresponding field is
  -- not changed and an warning is logged.
  --
  -- @local
  -- @function update
  -- @tparam table config a table representing the configuration to update (if `config`
  -- is not a table, the function immediately returns it without any modifications)
  -- @treturn table the config table (with possibly updated values).
  --
  -- @usage
  -- local config = update(config)
  -- OR
  -- update(config)
  local function update(config)
    return recurse_config_refs(config, update_from_cache)
  end


  ---
  -- Function `get_references` recursively iterates over options and returns
  -- all the references in an array. The same reference is in array only once.
  --
  -- @local
  -- @function get_references
  -- @tparam table options the options to look for the references
  -- @tparam[opt] table references internal variable that is used for recursion
  -- @tparam[opt] collected references internal variable that is used for recursion
  -- @treturn table an array of collected references
  --
  -- @usage
  -- local references = get_references({
  --   username = "john",
  --   password = "doe",
  --   ["$refs"] = {
  --     username = "{vault://aws/database/username}",
  --     password = "{vault://aws/database/password}",
  --   }
  -- })
  local function get_references(options, references, collected)
    references = references or {}
    collected = collected or { n = 0 }

    if type(options) ~= "table" then
      return references
    end

    for key, value in pairs(options) do
      if key ~= "$refs" and type(value) == "table" then
        get_references(value, references, collected)
      end
    end

    local refs = options["$refs"]
    if type(refs) ~= "table" or isempty(refs) then
      return references
    end

    for _, reference in pairs(refs) do
      if type(reference) == "string" then -- a string reference
        if not collected[reference] then
          collected[reference] = true
          collected.n = collected.n + 1
          references[collected.n] = reference
        end

      elseif type(reference) == "table" then -- array, set or map of references
        for _, ref in pairs(reference) do
          if not collected[ref] then
            collected[ref] = true
            collected.n = collected.n + 1
            references[collected.n] = ref
          end
        end
      end
    end

    return references
  end


  ---
  -- Function `get_sorted_references` recursively iterates over options and returns
  -- all the references in an sorted array. The same reference is in array only once.
  --
  -- @local
  -- @function get_sorted_references
  -- @tparam table options the options to look for the references
  -- @treturn table|nil an sorted array of collected references, return `nil` in case no references were found.
  --
  -- @usage
  -- local references = get_sorted_references({
  --   username = "john",
  --   password = "doe",
  --   ["$refs"] = {
  --     username = "{vault://aws/database/username}",
  --     password = "{vault://aws/database/password}",
  --   }
  -- })
  local function get_sorted_references(options)
    local references = get_references(options)
    if isempty(references) then
      return
    end

    sort(references)

    return references
  end


  ---
  -- Function `rotate_reference` rotates a secret reference.
  --
  -- @local
  -- @function rotate_reference
  -- @tparam string reference the reference to rotate
  -- @tparam function the caching strategy created with `get_caching_strategy` function
  -- @treturn true|nil `true` after successfully rotating a secret, otherwise `nil`
  -- @treturn string|nil a string describing an error if there was one
  local function rotate_reference(reference, caching_strategy)
    local strategy, err, config, new_cache_key, parsed_reference, config_hash = get_strategy(reference)
    if not strategy then
      return nil, fmt("could not parse reference %s (%s)", reference, err)
    end

    strategy = caching_strategy(strategy, config_hash)

    local ok, err = get_from_vault(reference, strategy, config, new_cache_key, parsed_reference)
    if not ok then
      return nil, fmt("could not retrieve value for reference %s (%s)", reference, err)
    end

    return true
  end


  ---
  -- Function `rotate_references` rotates the references passed in as an array.
  --
  -- @local
  -- @function rotate_references
  -- @tparam table references an array of references to rotate
  -- @treturn boolean `true` after it has finished rotation over all the references
  local function rotate_references(references)
    local phase = get_phase()
    local caching_strategy = get_caching_strategy()
    for _, reference in ipairs(references) do
      yield(true, phase)

      local ok, err = rotate_reference(reference, caching_strategy)
      if not ok then
        self.log.warn(err)
      end
    end

    return true
  end


  ---
  -- Function `execute_callback` updates options and then executes the callback
  --
  -- @local
  -- @function execute_callback
  -- @tparam function callback the callback to execute
  -- @tparam table the callback options to be passed to callback (after updating them)
  -- @treturn any the callback return value
  -- @treturn string|nil a string describing an error if there was one
  local function execute_callback(callback, options)
    update(options)
    return callback(options)
  end


  ---
  -- Function `try` attempts to execute a provided callback function with the provided options.
  --
  -- If the callback function fails, the `try` function will attempt to resolve references and update
  -- the values in the options table before re-attempting the callback function.
  --
  -- @local
  -- @function try
  -- @tparam function callback the callback function to execute that takes options table as its argument
  -- @tparam table options the options table to provide to the callback function.
  -- @treturn any the result of the callback function if it succeeds, otherwise `nil`
  -- @treturn string|nil a string describing an error if there was one
  --
  -- @usage
  -- local function connect(options)
  --   return database_connect(options)
  -- end
  --
  -- local connection, err = try(connect, {
  --   username = "john",
  --   password = "doe",
  --   ["$refs"] = {
  --     username = "{vault://aws/database/username}",
  --     password = "{vault://aws/database/password}",
  --   }
  -- })
  local function try(callback, options)
    local references = get_sorted_references(options)
    if not references then
      -- We cannot retry, so let's just call the callback and return
      return callback(options)
    end

    local name = "vault.try:" .. calculate_hash(concat(references, "."))
    local old_updated_at = RETRY_LRU:get(name) or 0

    -- Try to execute the callback with the current options
    local res = execute_callback(callback, options)
    if res then
      return res -- If the callback succeeds, return the result
    end

    -- Check if options were updated while executing callback
    local new_updated_at = RETRY_LRU:get(name) or 0
    if old_updated_at ~= new_updated_at then
      return execute_callback(callback, options)
    end

    -- Is it worth to have node level mutex instead?
    -- If so, the RETRY_LRU also needs to be node level.
    concurrency.with_coroutine_mutex({
      name = name,
      timeout = ROTATION_INTERVAL,
    }, function()
      -- Check if references were updated while waiting for a lock
      new_updated_at = RETRY_LRU:get(name) or 0
      if old_updated_at ~= new_updated_at then
        return -- already updated
      end

      rotate_references(references)
      RETRY_LRU:set(name, get_updated_now_ms())
    end)

    -- Call the callback the second time
    -- (may be same options as before, but not worth to optimize)
    return execute_callback(callback, options)
  end


  ---
  -- Function `rotate_secret` rotates a secret reference.
  --
  -- @local
  -- @function rotate_secret
  -- @tparam string old_cache_key old cache key
  -- @tparam function the caching strategy created with `get_caching_strategy` function
  -- @treturn true|nil `true` after successfully rotating a secret, otherwise `nil`
  -- @treturn string|nil a string describing an error if there was one
  local function rotate_secret(old_cache_key, caching_strategy)
    local reference, err = parse_cache_key(old_cache_key)
    if not reference then
      -- invalid cache keys are removed (in general should never happen)
      SECRETS_CACHE:delete(old_cache_key)
      return nil, err
    end

    local strategy, err, config, new_cache_key, parsed_reference, config_hash = get_strategy(reference)
    if not strategy then
      -- invalid cache keys are removed (e.g. a vault entity could have been removed)
      SECRETS_CACHE:delete(old_cache_key)
      return nil, fmt("could not parse reference %s (%s)", reference, err)
    end

    if old_cache_key ~= new_cache_key then
      -- config has changed, thus the old cache key can be removed
      SECRETS_CACHE:delete(old_cache_key)
    end

    -- The ttl for this key, is the TTL + the resurrect time
    -- If the TTL is still greater than the resurrect time
    -- we don't have to rotate the secret, except it if it
    -- negatively cached.
    local resurrect
    local ttl = SECRETS_CACHE:ttl(new_cache_key)
    if ttl and SECRETS_CACHE:get(new_cache_key) ~= NEGATIVELY_CACHED_VALUE then
      local resurrect_ttl = max(config.resurrect_ttl or DAO_MAX_TTL, SECRETS_CACHE_MIN_TTL)
      -- the secret is still within ttl, no need to refresh
      if ttl > resurrect_ttl then
        return true
      end

      -- the secret is still within resurrect ttl time, so when we try to refresh the secret
      -- we do not forciblly override it with a negative value, so that the cached value
      -- can be resurrected
      resurrect = ttl > SECRETS_CACHE_MIN_TTL
    end

    strategy = caching_strategy(strategy, config_hash)

    -- try to refresh the secret, according to the remaining time the cached value may or may not be refreshed.
    local ok, err = get_from_vault(reference, strategy, config, new_cache_key, parsed_reference, resurrect)
    if not ok then
      return nil, fmt("could not retrieve value for reference %s (%s)", reference, err)
    end

    return true
  end


  ---
  -- Function `rotate_secrets` rotates the secrets.
  --
  -- It iterates over all keys in the secrets and, if a key corresponds to a reference and the
  -- ttl of the key is less than or equal to the resurrection period, it refreshes the value
  -- associated with the reference.
  --
  -- @local
  -- @function rotate_secrets
  -- @tparam table secrets the secrets to rotate
  -- @treturn boolean `true` after it has finished iterating over all keys in the secrets
  local function rotate_secrets(secrets)
    local phase = get_phase()
    local caching_strategy = get_caching_strategy()
    for _, cache_key in ipairs(secrets) do
      yield(true, phase)

      local ok, err = rotate_secret(cache_key, caching_strategy)
      if not ok then
        self.log.notice(err)
      end
    end

    return true
  end


  ---
  -- Function `rotate_secrets_cache` rotates the secrets in the shared dictionary cache.
  --
  -- @local
  -- @function rotate_secrets_cache
  -- @treturn boolean `true` after it has finished iterating over all keys in the shared dictionary cache
  local function rotate_secrets_cache()
    return rotate_secrets(SECRETS_CACHE:get_keys(0))
  end


  ---
  -- Function `rotate_secrets_init_worker` rotates the secrets in init worker cache
  --
  -- On init worker the secret resolving is postponed to a timer because init worker
  -- cannot cosockets / coroutines, and there is no other workaround currently.
  --
  -- @local
  -- @function rotate_secrets_init_worker
  -- @treturn boolean `true` after it has finished iterating over all keys in the init worker cache
  local function rotate_secrets_init_worker()
    local _, err, err2
    if INIT_SECRETS then
      _, err = rotate_references(INIT_SECRETS)
    end

    if INIT_WORKER_SECRETS then
      _, err2 = rotate_secrets(INIT_WORKER_SECRETS)
    end

    if err or err2 then
      return nil, err or err2
    end

    return true
  end


  ---
  -- A secrets rotation timer handler.
  --
  -- Uses a node-level mutex to prevent multiple threads/workers running it the same time.
  --
  -- @local
  -- @function rotate_secrets_timer
  -- @tparam boolean premature `true` if server is shutting down
  -- @tparam[opt] boolean init `true` when this is a one of init_worker timer run
  -- By default rotates the secrets in shared dictionary cache.
  local function rotate_secrets_timer(premature, init)
    if premature then
      return true
    end

    local ok, err = concurrency.with_worker_mutex(ROTATION_MUTEX_OPTS, init and rotate_secrets_init_worker or rotate_secrets_cache)
    if not ok and err ~= "timeout" then
      self.log.err("rotating secrets failed (", err, ")")
    end

    if init then
      INIT_SECRETS = nil
      INIT_WORKER_SECRETS = nil
    end

    return true
  end


  ---
  -- Flushes LRU caches and forcibly rotates the secrets.
  --
  -- This is only ever executed on traditional nodes.
  --
  -- @local
  -- @function handle_vault_crud_event
  -- @tparam table data event data
  local function handle_vault_crud_event(data)
    local cache = self.core_cache
    if cache then
      local vaults = self.db.vaults
      local old_entity = data.old_entity
      local old_prefix
      if old_entity then
        old_prefix = old_entity.prefix
        if old_prefix and old_prefix ~= ngx.null then
          cache:invalidate(vaults:cache_key(old_prefix))
        end
      end

      local entity = data.entity
      if entity then
        local prefix = entity.prefix
        if prefix and prefix ~= ngx.null and prefix ~= old_prefix then
          cache:invalidate(vaults:cache_key(prefix))
        end
      end
    end

    LRU:flush_all()

    -- refresh all the secrets
    local _, err = self.timer:named_at("secret-rotation-on-crud-event", 0, rotate_secrets_timer)
    if err then
      self.log.err("could not schedule timer to rotate vault secret references on crud event: ", err)
    end
  end


  local function should_register_crud_event()
    local conf = self.configuration

    local not_dbless = conf.database ~= "off"  -- postgres
    local dp_with_rpc_sync = conf.role == "data_plane" and
                             conf.cluster_rpc_sync

    return not_dbless or dp_with_rpc_sync
  end

  local initialized
  ---
  -- Initializes vault.
  --
  -- Registers event handlers and starts a recurring secrets
  -- rotation timer. It does nothing on control planes.
  --
  -- @local
  -- @function init_worker
  local function init_worker()
    if initialized then
      return
    end

    initialized = true

    if should_register_crud_event() then
      self.worker_events.register(handle_vault_crud_event, "crud", "vaults")
    end

    local _, err = self.timer:named_every("secret-rotation", ROTATION_INTERVAL, rotate_secrets_timer)
    if err then
      self.log.err("could not schedule timer to rotate vault secret references: ", err)
    end

    local _, err = self.timer:named_at("secret-rotation-on-init", 0, rotate_secrets_timer, true)
    if err then
      self.log.err("could not schedule timer to rotate vault secret references on init: ", err)
    end
  end


  ---
  -- Called on `init` phase, and stores value in secrets cache.
  --
  -- @local
  -- @function init_in_cache_from_value
  -- @tparam string reference a vault reference.
  -- @tparan value string value that is stored in secrets cache.
  local function init_in_cache_from_value(reference, value)
    local strategy, err, config, cache_key = get_strategy(reference)
    if not strategy then
      return nil, err
    end

    -- doesn't support vault returned ttl, but none of the vaults supports it,
    -- and the support for vault returned ttl might be removed later.
    local cache_value, shdict_ttl, lru_ttl = get_cache_value_and_ttl(value, config)

    local ok, cache_err = SECRETS_CACHE:safe_set(cache_key, cache_value, shdict_ttl)
    if not ok then
      return nil, cache_err
    end

    if cache_value ~= NEGATIVELY_CACHED_VALUE then
      LRU:set(reference, cache_value, lru_ttl)
    end

    return true
  end


  ---
  -- Called on `init` phase, and used to warmup secrets cache.
  --
  -- @local
  -- @function init_in_cache
  -- @tparam string reference a vault reference.
  -- @tparan table record a table that is a container for de-referenced value.
  -- @tparam field string field name in a record to which to store the de-referenced value.
  local function init_in_cache(reference, record, field)
    local value, err = init_in_cache_from_value(reference, record[field])
    if not value then
      self.log.warn("error caching secret reference ", reference, ": ", err)
    end
  end


  ---
  -- Called on `init` phase, and used to warmup secrets cache.
  -- @local
  -- @function init
  local function init()
    recurse_config_refs(self.configuration, init_in_cache)
  end


  local _VAULT = {} -- the public PDK interfaces


  ---
  -- Flush vault LRU cache and start a timer to rotate secrets.
  --
  -- @local
  -- @function kong.vault.flush
  --
  -- @usage
  -- kong.vault.flush()
  function _VAULT.flush()
    LRU:flush_all()

    -- refresh all the secrets
    local _, err = self.timer:named_at("secret-rotation-on-flush", 0, rotate_secrets_timer)
    if err then
      self.log.err("could not schedule timer to rotate vault secret references: ", err)
    end
  end


  ---
  -- Checks if the passed in reference looks like a reference.
  -- Valid references start with '{vault://' and end with '}'.
  --
  -- If you need more thorough validation,
  -- use `kong.vault.parse_reference`.
  --
  -- @function kong.vault.is_reference
  -- @tparam string reference reference to check
  -- @treturn boolean `true` is the passed in reference looks like a reference, otherwise `false`
  --
  -- @usage
  -- kong.vault.is_reference("{vault://env/key}") -- true
  -- kong.vault.is_reference("not a reference")   -- false
  function _VAULT.is_reference(reference)
    return is_reference(reference)
  end


  ---
  -- Parses and decodes the passed in reference and returns a table
  -- containing its components.
  --
  -- Given a following resource:
  -- ```lua
  -- "{vault://env/cert/key?prefix=SSL_#1}"
  -- ```
  --
  -- This function will return following table:
  --
  -- ```lua
  -- {
  --   name     = "env",  -- name of the Vault entity or Vault strategy
  --   resource = "cert", -- resource where secret is stored
  --   key      = "key",  -- key to lookup if the resource is secret object
  --   config   = {       -- if there are any config options specified
  --     prefix = "SSL_"
  --   },
  --   version  = 1       -- if the version is specified
  -- }
  -- ```
  --
  -- @function kong.vault.parse_reference
  -- @tparam string reference reference to parse
  -- @treturn table|nil a table containing each component of the reference, or `nil` on error
  -- @treturn string|nil error message on failure, otherwise `nil`
  --
  -- @usage
  -- local ref, err = kong.vault.parse_reference("{vault://env/cert/key?prefix=SSL_#1}") -- table
  function _VAULT.parse_reference(reference)
    return parse_reference(reference)
  end


  ---
  -- Resolves the passed in reference and returns the value of it.
  --
  -- @function kong.vault.get
  -- @tparam string reference  reference to resolve
  -- @treturn string|nil resolved value of the reference
  -- @treturn string|nil error message on failure, otherwise `nil`
  --
  -- @usage
  -- local value, err = kong.vault.get("{vault://env/cert/key}")
  function _VAULT.get(reference)
    return get(reference)
  end


  ---
  -- Helper function for secret rotation based on TTLs. Currently experimental.
  --
  -- @function kong.vault.update
  -- @tparam table options options containing secrets and references (this function modifies the input options)
  -- @treturn table options with updated secret values
  --
  -- @usage
  -- local options = kong.vault.update({
  --   cert = "-----BEGIN CERTIFICATE-----...",
  --   key = "-----BEGIN RSA PRIVATE KEY-----...",
  --   cert_alt = "-----BEGIN CERTIFICATE-----...",
  --   key_alt = "-----BEGIN EC PRIVATE KEY-----...",
  --   ["$refs"] = {
  --     cert = "{vault://aws/cert}",
  --     key = "{vault://aws/key}",
  --     cert_alt = "{vault://aws/cert-alt}",
  --     key_alt = "{vault://aws/key-alt}",
  --   }
  -- })
  --
  -- -- or
  --
  -- local options = {
  --   cert = "-----BEGIN CERTIFICATE-----...",
  --   key = "-----BEGIN RSA PRIVATE KEY-----...",
  --   cert_alt = "-----BEGIN CERTIFICATE-----...",
  --   key_alt = "-----BEGIN EC PRIVATE KEY-----...",
  --   ["$refs"] = {
  --     cert = "{vault://aws/cert}",
  --     key = "{vault://aws/key}",
  --     cert_alt = "{vault://aws/cert-alt}",
  --     key_alt = "{vault://aws/key-alt}",
  --   }
  -- }
  -- kong.vault.update(options)
  function _VAULT.update(options)
    return update(options)
  end


  ---
  -- Helper function for automatic secret rotation. Currently experimental.
  --
  -- @function kong.vault.try
  -- @tparam function callback callback function
  -- @tparam table options options containing credentials and references
  -- @treturn string|nil return value of the callback function
  -- @treturn string|nil error message on failure, otherwise `nil`
  --
  -- @usage
  -- local function connect(options)
  --   return database_connect(options)
  -- end
  --
  -- local connection, err = kong.vault.try(connect, {
  --   username = "john",
  --   password = "doe",
  --   ["$refs"] = {
  --     username = "{vault://aws/database-username}",
  --     password = "{vault://aws/database-password}",
  --   }
  -- })
  function _VAULT.try(callback, options)
    return try(callback, options)
  end


  ---
  -- Initializes vault.
  --
  -- Registers event handlers (on non-dbless nodes) and starts a recurring secrets
  -- rotation timer. Does nothing on control planes.
  --
  -- @local
  -- @function kong.vault.init_worker
  function _VAULT.init_worker()
    init_worker()
  end


  ---
  -- Warmups vault caches from config.
  --
  -- @local
  -- @function kong.vault.warmup
  function _VAULT.warmup(input)
    for k, v in pairs(input) do
      local kt = type(k)
      if kt == "table" then
        _VAULT.warmup(k)
      elseif kt == "string" and is_reference(k) then
        get(k)
      end
      local vt = type(v)
      if vt == "table" then
        _VAULT.warmup(v)
      elseif vt == "string" and is_reference(v) then
        get(v)
      end
    end
  end

  if get_phase() == "init" then
    init()
  end

  return _VAULT
end


return {
  new = new,
  is_reference = is_reference,
  parse_reference = parse_reference,
}
