local tablex       = require "pl.tablex"
local pretty       = require "pl.pretty"
local table_tools  = require "kong.tools.table"
local cjson        = require "cjson"
local new_tab      = require "table.new"
local nkeys        = require "table.nkeys"
local is_reference = require "kong.pdk.vault".is_reference
local json         = require "kong.db.schema.json"
local cjson_safe   = require "cjson.safe"
local deprecation  = require "kong.deprecation"
local deepcompare  = require "pl.tablex".deepcompare


local setmetatable = setmetatable
local getmetatable = getmetatable
local re_match     = ngx.re.match
local re_find      = ngx.re.find
local tostring     = tostring
local concat       = table.concat
local insert       = table.insert
local format       = string.format
local unpack       = unpack
local assert       = assert
local yield        = require("kong.tools.yield").yield
local pairs        = pairs
local pcall        = pcall
local floor        = math.floor
local type         = type
local next         = next
local update_time  = ngx.update_time
local ngx_time     = ngx.time
local ngx_now      = ngx.now
local find         = string.find
local null         = ngx.null
local max          = math.max
local sub          = string.sub
local safe_decode  = cjson_safe.decode


local random_string = require("kong.tools.rand").random_string
local uuid = require("kong.tools.uuid").uuid
local json_validate = json.validate


local Schema       = {}
Schema.__index     = Schema


local _cache = {}
local _workspaceable = {}


local validation_errors = {
  -- general message
  ERROR                     = "Validation error: %s",
  -- types
  ARRAY                     = "expected an array",
  SET                       = "expected a set",
  MAP                       = "expected a map",
  RECORD                    = "expected a record",
  STRING                    = "expected a string",
  NUMBER                    = "expected a number",
  BOOLEAN                   = "expected a boolean",
  INTEGER                   = "expected an integer",
  FUNCTION                  = "expected a function",
  -- validations
  EQ                        = "value must be %s",
  NE                        = "value must not be %s",
  GT                        = "value must be greater than %s",
  BETWEEN                   = "value should be between %d and %d",
  LEN_EQ                    = "length must be %d",
  LEN_MIN                   = "length must be at least %d",
  LEN_MAX                   = "length must be at most %d",
  MATCH                     = "invalid value: %s",
  NOT_MATCH                 = "invalid value: %s",
  MATCH_ALL                 = "invalid value: %s",
  MATCH_NONE                = "invalid value: %s",
  MATCH_ANY                 = "invalid value: %s",
  STARTS_WITH               = "should start with: %s",
  CONTAINS                  = "expected to contain: %s",
  ONE_OF                    = "expected one of: %s",
  NOT_ONE_OF                = "must not be one of: %s",
  IS_REGEX                  = "not a valid regex: %s",
  TIMESTAMP                 = "expected a valid timestamp",
  UUID                      = "expected a valid UUID",
  VALIDATION                = "failed validating: %s",
  -- field presence
  BAD_INPUT                 = "expected an input table",
  REQUIRED                  = "required field missing",
  NO_FOREIGN_DEFAULT        = "will not generate a default value for a foreign field",
  UNKNOWN                   = "unknown field",
  IMMUTABLE                 = "immutable field cannot be updated",
  -- entity checks
  REQUIRED_FOR_ENTITY_CHECK = "field required for entity check",
  ENTITY_CHECK              = "failed entity check: %s(%s)",
  ENTITY_CHECK_N_FIELDS     = "entity check requires %d fields",
  CHECK                     = "entity check failed",
  CONDITIONAL               = "failed conditional validation given value of field '%s'",
  AT_LEAST_ONE_OF           = "at least one of these fields must be non-empty: %s",
  CONDITIONAL_AT_LEAST_ONE_OF = "at least one of these fields must be non-empty: %s",
  ONLY_ONE_OF               = "exactly one of these fields must be non-empty: %s",
  DISTINCT                  = "values of these fields must be distinct: %s",
  MUTUALLY_REQUIRED         = "all or none of these fields must be set: %s",
  MUTUALLY_EXCLUSIVE        = "only one or none of these fields must be set: %s",
  MUTUALLY_EXCLUSIVE_SETS   = "these sets are mutually exclusive: %s",
  -- schema error
  SCHEMA_NO_DEFINITION      = "expected a definition table",
  SCHEMA_NO_FIELDS          = "error in schema definition: no 'fields' table",
  SCHEMA_BAD_REFERENCE      = "schema refers to an invalid foreign entity: %s",
  SCHEMA_CANNOT_VALIDATE    = "error in schema prevents from validating this field",
  SCHEMA_TYPE               = "invalid type: %s",
  -- primary key errors
  NOT_PK                    = "not a primary key",
  MISSING_PK                = "missing primary key",
  -- subschemas
  SUBSCHEMA_UNKNOWN         = "unknown type: %s",
  SUBSCHEMA_BAD_PARENT      = "error in definition of '%s': entities of type '%s' cannot have subschemas",
  SUBSCHEMA_UNDEFINED_FIELD = "error in definition of '%s': %s: abstract field was not specialized",
  SUBSCHEMA_BAD_TYPE        = "error in definition of '%s': %s: cannot change type in a specialized field",
  SUBSCHEMA_BAD_FIELD       = "error in definition of '%s': %s: cannot create a new field",
  SUBSCHEMA_ABSTRACT_FIELD  = "error in schema definition: abstract field was not specialized",
  -- transformations
  TRANSFORMATION_ERROR      = "transformation failed: %s",
  -- json
  JSON_ENCODE_ERROR         = "value could not be JSON-encoded: %s",
  JSON_DECODE_ERROR         = "value could not be JSON-decoded: %s",
  JSON_SCHEMA_ERROR         = "value failed JSON-schema validation: %s",
  JSON_PARENT_KEY_MISSING   = "validation of %s depends on the parent attribute %s, but it is not set",
  JSON_SCHEMA_NOT_FOUND     = "mandatory json schema for field (%s) not found"
}


Schema.valid_types = {
  array        = true,
  set          = true,
  string       = true,
  number       = true,
  boolean      = true,
  integer      = true,
  foreign      = true,
  map          = true,
  record       = true,
  ["function"] = true,
  json         = true,
}


local uuid_regex = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"


local function make_length_validator(err, fn)
  return function(value, n, field)
    local len = #value
    if field.type == "map" then
      for _ in pairs(value) do
        len = len + 1
      end
    end
    if fn(len, n) then
      return true
    end
    return nil, validation_errors[err]:format(n)
  end
end


--- Produce a nicely quoted list:
-- Given `{"foo", "bar", "baz"}` and `"or"`, produces
-- `"'foo', 'bar', 'baz'"`.
-- Given an array of arrays (e.g., `{{"f1", "f2"}, {"f3", "f4"}}`), produces
-- `"('f1', 'f2'), ('f3', 'f4')"`.
-- @param words an array of strings and/or arrays of strings.
-- @return The string of quoted words and/or arrays.
local function quoted_list(words)
  local msg = {}
  for i = 1, #words do
    local word = words[i]
    if type(word) == "table" then
      insert(msg, ("(%s)"):format(quoted_list(word)))
    else
      insert(msg, ("'%s'"):format(word))
    end
  end
  return concat(msg, ", ")
end


--- Validator functions available for schemas.
-- A validator can only affect one field.
-- Each validation is registered in a schema field definition as
-- a key-value pair. The key is the validation name and the value
-- is an optional argument (by convention, `true` if the argument
-- is to be ignored). Each validation function takes as inputs
-- the value to be validated and the argument given in the schema
-- definition. The function should return true or nil,
-- optionally followed by an error message. If the error message
-- is not given, the validation name (in uppercase) is used as
-- a key in `validation_errors` to get a message. If it was not
-- registered, a generic fallback error message is produced with
-- `validation_errors.VALIDATION`.
Schema.validators = {

  between = function(value, limits)
    if value < limits[1] or value > limits[2] then
      return nil, validation_errors.BETWEEN:format(limits[1], limits[2])
    end
    return true
  end,

  eq = function(value, wanted)
    if value == wanted then
      return true
    end
    local str = (wanted == null) and "null" or tostring(wanted)
    return nil, validation_errors.EQ:format(str)
  end,

  ne = function(value, wanted)
    if value ~= wanted then
      return true
    end
    local str = (wanted == null) and "null" or tostring(value)
    return nil, validation_errors.NE:format(str)
  end,

  gt = function(value, limit)
    if value > limit then
      return true
    end
    return nil, validation_errors.GT:format(tostring(limit))
  end,

  len_eq = make_length_validator("LEN_EQ", function(len, n)
    return len == n
  end),

  len_min = make_length_validator("LEN_MIN", function(len, n)
    return len >= n
  end),

  len_max = make_length_validator("LEN_MAX", function(len, n)
    return len <= n
  end),

  match = function(value, pattern)
    local m = value:match(pattern)
    if not m then
      return nil, validation_errors.MATCH:format(value)
    end
    return true
  end,

  is_regex = function(value)
    local _, err = re_match("any string", value)
    return err == nil
  end,

  not_match = function(value, pattern)
    local m = value:match(pattern)
    if m then
      return nil, validation_errors.NOT_MATCH:format(value)
    end
    return true
  end,

  match_all = function(value, list)
    for i = 1, #list do
      local m = value:match(list[i].pattern)
      if not m then
        return nil, list[i].err
      end
    end
    return true
  end,

  match_none = function(value, list)
    for i = 1, #list do
      local m = value:match(list[i].pattern)
      if m then
        return nil, list[i].err
      end
    end
    return true
  end,

  match_any = function(value, arg)
    local patterns = arg.patterns
    for i = 1, #patterns do
      local m = value:match(patterns[i])
      if m then
        return true
      end
    end
    return nil, arg.err
  end,

  starts_with = function(value, expected)
    -- produces simpler error messages than 'match'
    if sub(value, 1, #expected) ~= expected then
      return nil, validation_errors.STARTS_WITH:format(expected)
    end
    return true
  end,

  one_of = function(value, options)
    for i = 1, #options do
      if value == options[i] then
        return true
      end
    end
    return nil, validation_errors.ONE_OF:format(concat(options, ", "))
  end,

  not_one_of = function(value, options)
    for i = 1, #options do
      if value == options[i] then
        return nil, validation_errors.NOT_ONE_OF:format(concat(options, ", "))
      end
    end
    return true
  end,

  timestamp = function(value)
    return value > 0 or nil
  end,

  uuid = function(value)
    if #value ~= 36 then
      return nil
    end
    return re_find(value, uuid_regex, "ioj") and true or nil
  end,

  contains = function(array, wanted)
    for i = 1, #array do
      if array[i] == wanted then
        return true
      end
    end

    return nil, validation_errors.CONTAINS:format(wanted)
  end,

  mutually_exclusive_subsets = function(value, subsets)
    local subset_union = {} -- union of all subsets; key is an element, value is the
    for i = 1, #subsets do -- the subset the element is part of
      local subset = subsets[i]
      for j = 1, #subset do
        subset_union[subset[j]] = subset
      end
    end

    local member_of = {}

    for i = 1, #value do -- for each value, add the set it's part of
      local val = value[i]
      if subset_union[val] and not member_of[subset_union[val]] then -- to member_of, iff it hasn't already
        member_of[subset_union[val]] = true
        member_of[#member_of+1] = subset_union[val]
      end
    end

    if #member_of <= 1 then
      return true
    else
      return nil, validation_errors.MUTUALLY_EXCLUSIVE_SETS:format(quoted_list(member_of))
    end
  end,

  custom_validator = function(value, fn)
    return fn(value)
  end

}


Schema.validators_order = {
  "eq",
  "ne",
  "not_one_of",
  "one_of",

  -- type-dependent
  "gt",
  "timestamp",
  "uuid",
  "is_regex",
  "between",

  -- strings (1/2)
  "len_eq",
  "len_min",
  "len_max",

  -- strings (2/2)
  "starts_with",
  "not_match",
  "match_none",
  "match",
  "match_all",
  "match_any",

  -- arrays
  "contains",

  -- other
  "custom_validator",
  "mutually_exclusive_subsets",
}


--- Returns true if a field is non-empty (with emptiness defined
-- for strings and aggregate values).
-- This function is defined as `is_nonempty` rather than the more intuitive
-- `is_empty` because the former has a less fuzzy definition:
-- being non-empty clearly excludes null and nil values.
-- @param value a value, which may be `ngx.null` or `nil`.
local function is_nonempty(value)
  if value == nil
     or value == null
     or (type(value) == "table" and not next(value))
     or (type(value) == "string" and value == "") then
    return false
  end

  return true
end


--- Returns true if a table is a sequence
-- @param t a table to be checked
-- @return `true` if `t` is a sequence, otherwise returns false.
local function is_sequence(t)
  if type(t) ~= "table" then
    return false
  end

  local m, c = 0, 0

  for k, _ in pairs(t) do
    c = c + 1

    if t[c] == nil then
      return false
    end

    if type(k) ~= "number" or k < 0 or floor(k) ~= k then
      return false
    end

    m = max(m, k)
  end

  return c == m
end


-- Get a field from a possibly-nested table using a string key
-- such as "x.y.z", such that `get_field(t, "x.y.z")` is the
-- same as `t.x.y.z`.
local function get_field(tbl, name)
  if tbl == nil or tbl == null then
    return nil
  end
  local dot = find(name, ".", 1, true)
  if not dot then
    return tbl[name]
  end
  local hd, tl = sub(name, 1, dot - 1), sub(name, dot + 1)
  return get_field(tbl[hd], tl)
end


-- Set a field from a possibly-nested table using a string key
-- such as "x.y.z", such that `set_field(t, "x.y.z", v)` is the
-- same as `t.x.y.z = v`.
local function set_field(tbl, name, value)
  local dot = find(name, ".", 1, true)
  if not dot then
    tbl[name] = value
    return
  end
  local hd, tl = sub(name, 1, dot - 1), sub(name, dot + 1)
  local subtbl = tbl[hd]
  if subtbl == nil then
    subtbl = {}
    tbl[hd] = subtbl
  end
  set_field(subtbl, tl, value)
end


-- Get a field definition from a possibly-nested schema using a string key
-- such as "x.y.z", such that `get_field(t, "x.y.z")` is the
-- same as `t.x.y.z`.
local function get_schema_field(schema, name)
  if schema == nil then
    return nil
  end
  local dot = find(name, ".", 1, true)
  if not dot then
    return schema.fields[name]
  end
  local hd, tl = sub(name, 1, dot - 1), sub(name, dot + 1)
  return get_schema_field(schema.fields[hd], tl)
end


local function mutually_required(entity, field_names)
  local nonempty = {}

  for i = 1, #field_names do
    local name = field_names[i]
    if is_nonempty(get_field(entity, name)) then
      insert(nonempty, name)
    end
  end

  if #nonempty == 0 or #nonempty == #field_names then
    return true
  end

  return nil, quoted_list(field_names)
end


local function mutually_exclusive(entity, field_names)
  local nonempty = {}

  for i = 1, #field_names do
    local name = field_names[i]
    if is_nonempty(get_field(entity, name)) then
      insert(nonempty, name)
    end
  end

  if #nonempty == 0 or #nonempty == 1 then
    return true
  end

  return nil, quoted_list(field_names)
end


--- Entity checkers are cross-field validation rules.
-- An entity checker is implemented as an entry in this table,
-- containing a mandatory field `fn`, the checker function,
-- and an optional field `field_sources`.
--
-- An entity checker is used in a schema by adding an entry to
-- the `entity_checks` array of a schema table. Entries
-- in `entity_checks` are tables with a single key, named
-- after the entity checker; its value is the "entity check
-- argument". For example:
--
--     entity_checks = {
--        { only_one_of = { "field_a", "field_b" } },
--     },
--
-- The `fn` function which implements an entity checker receives
-- three arguments: a projection of the entity containing only
-- the relevant fields to this checker, the entity check argument,
-- and the schema table. This ensures that the entity checker
-- does _not_ have access by default to the entire entity being
-- checked. This allows us to enable/disable entity checkers on
-- partial updates.
--
-- To specify which fields are relevant to this checker, one
-- uses the `field_sources`. It is an array of strings, which
-- are key names to the entity check argument (see the `conditional`
-- entity checker for an example of its use).
-- If `field_sources` is not present, it is assumed that the
-- entity check argument is an array of field names, and that
-- all of them need to be present for the entity checker to run.
-- (this is the case, for example, of `only_one_of` in the example
-- above: this checker forces both fields to be given, and the
-- implementation of the checker will demand that only one is
-- non-empty).
Schema.entity_checkers = {

  at_least_one_of = {
    run_with_missing_fields = true,
    run_with_invalid_fields = true,
    fn = function(entity, field_names)
      for i = 1, #field_names do
        local name = field_names[i]
        if is_nonempty(get_field(entity, name)) then
          return true
        end
      end

      return nil, quoted_list(field_names)
    end,
  },

  conditional_at_least_one_of = {
    run_with_missing_fields = true,
    run_with_invalid_fields = true,
    field_sources = {
      "if_field",
      "then_at_least_one_of",
      "else_then_at_least_one_of",
    },
    required_fields = { "if_field" },
    fn = function(entity, arg, schema)
      local if_value = get_field(entity, arg.if_field)
      if if_value == nil then
        return true
      end

      local arg_mt = {
        __index = get_schema_field(schema, arg.if_field),
      }

      setmetatable(arg.if_match, arg_mt)
      local ok, _ = Schema.validate_field(schema, arg.if_match, if_value)
      if not ok then
        if arg.else_match == nil then
          return true
        end

        -- run 'else'
        setmetatable(arg.else_match, arg_mt)
        local ok, _ = Schema.validate_field(schema, arg.else_match, if_value)
        if not ok then
          return true
        end

        local names = arg.else_then_at_least_one_of
        for i = 1, #names do
          if is_nonempty(get_field(entity, names[i])) then
            return true
          end
        end

        local list = quoted_list(arg.else_then_at_least_one_of)
        local else_then_err
        if arg.else_then_err then
          else_then_err = arg.else_then_err:format(list)
        end

        return nil, list, else_then_err
      end

      -- run 'if'
      local names = arg.then_at_least_one_of
      for i = 1, #names do
        if is_nonempty(get_field(entity, names[i])) then
          return true
        end
      end

      local list = quoted_list(arg.then_at_least_one_of)
      local then_err
      if arg.then_err then
        then_err = arg.then_err:format(list)
      end

      return nil, list, then_err
    end,
  },

  only_one_of = {
    run_with_missing_fields = false,
    run_with_invalid_fields = true,
    fn = function(entity, field_names)
      local found = false
      local ok = false
      for i = 1, #field_names do
        if is_nonempty(get_field(entity, field_names[i])) then
          if not found then
            found = true
            ok = true
          else
            ok = false
          end
        end
      end

      if ok then
        return true
      end
      return nil, quoted_list(field_names)
    end,
  },

  distinct = {
    run_with_missing_fields = false,
    run_with_invalid_fields = true,
    fn = function(entity, field_names)
      local seen = {}
      for i = 1, #field_names do
        local value = get_field(entity, field_names[i])
        if is_nonempty(value) then
          if seen[value] then
            return nil, quoted_list(field_names)
          end
          seen[value] = true
        end
      end
      return true
    end,
  },

  --- Conditional validation: if the first field passes the given validator,
  -- then run the validator against the second field.
  -- Example:
  -- ```
  -- conditional = { if_field = "policy",
  --                 if_match = { match = "^redis$" },
  --                 then_field = "redis_host",
  --                 then_match = { required = true } }
  -- ```
  conditional = {
    run_with_missing_fields = false,
    run_with_invalid_fields = true,
    field_sources = { "if_field", "then_field" },
    required_fields = { ["if_field"] = true },
    fn = function(entity, arg, schema, errors)
      local if_value = get_field(entity, arg.if_field)
      local then_value = get_field(entity, arg.then_field)
      if then_value == nil then
        then_value = null
      end

      setmetatable(arg.if_match, {
        __index = get_schema_field(schema, arg.if_field)
      })
      local ok, _ = Schema.validate_field(schema, arg.if_match, if_value)
      if not ok then
        return true
      end

      -- Handle `required`
      if arg.then_match.required == true and then_value == null then
        set_field(errors, arg.then_field, validation_errors.REQUIRED)
        return nil, arg.if_field
      end

      setmetatable(arg.then_match, {
        __index = get_schema_field(schema, arg.then_field)
      })
      local err
      ok, err = Schema.validate_field(schema, arg.then_match, then_value)
      if not ok then
        set_field(errors, arg.then_field, err)

        local then_err
        if arg.then_err then
          then_err = arg.then_err:format(arg.if_field)
        end

        return nil, arg.if_field, then_err
      end

      return true
    end,
  },

  custom_entity_check = {
    run_with_missing_fields = false,
    run_with_invalid_fields = false,
    field_sources = { "field_sources" },
    required_fields = { ["field_sources"] = true },
    fn = function(entity, arg)
      return arg.fn(entity)
    end,
  },

  mutually_required = {
    run_with_missing_fields = true,
    fn = mutually_required,
  },

  mutually_exclusive = {
    run_with_missing_fields = true,
    fn = mutually_exclusive,
  },

  mutually_exclusive_sets = {
    run_with_missing_fields = true,
    field_sources = { "set1", "set2" },
    required_fields = { "set1", "set2" },

    fn = function(entity, args)
      local nonempty1 = {}
      local nonempty2 = {}

      for i = 1, #args.set1 do
        local name = args.set1[i]
        if is_nonempty(get_field(entity, name)) then
          insert(nonempty1, name)
        end
      end

      for i = 1, #args.set2 do
        local name = args.set2[i]
        if is_nonempty(get_field(entity, name)) then
          insert(nonempty2, name)
        end
      end

      if #nonempty1 > 0 and #nonempty2 > 0 then
        return nil, format("(%s), (%s)", quoted_list(nonempty1),
                                         quoted_list(nonempty2))
      end

      return true
    end
  },
}


local function memoize(fn)
  local cache = setmetatable({}, { __mode = "k" })
  return function(k)
    if cache[k] then
      return cache[k]
    end
    local v = fn(k)
    cache[k] = v
    return v
  end
end


local function validate_elements(self, field, value)
  field.elements.required = true
  local errs = {}
  local all_ok = true
  for i = 1, #value do
    local ok, err = self:validate_field(field.elements, value[i])
    if not ok then
      errs[i] = err
      all_ok = false
    end
  end

  if all_ok then
    return true
  else
    return nil, errs
  end
end


local get_field_schema = memoize(function(field)
  return Schema.new(field)
end)


-- Forward declaration
local validate_fields


--- Validate the field according to the schema.
-- For aggregate values, validate each field recursively.
-- @param self The complete schema object.
-- @param field The schema definition for the field.
-- @param value The value to be checked (may be ngx.null).
-- @return true if the field validates correctly;
-- nil and an error message on failure.
function Schema:validate_field(field, value)
  yield(true)

  if value == null then
    if field.ne == null then
      return nil, field.err or validation_errors.NE:format("null")
    end
    if field.eq ~= nil and field.eq ~= null then
      return nil, validation_errors.EQ:format(tostring(field.eq))
    end
    if field.required then
      return nil, validation_errors.REQUIRED
    end
    return true
  end

  if field.eq == null then
    return nil, field.err or validation_errors.EQ:format("null")
  end

  if field.abstract then
    return nil, validation_errors.SUBSCHEMA_ABSTRACT_FIELD
  end

  if field.deprecation then
    local old_default = field.deprecation.old_default
    local should_warn = kong.configuration.role ~= "data_plane" and
                          (old_default == nil
                            or not deepcompare(value, old_default))
    if should_warn then
      deprecation(field.deprecation.message,
          { after = field.deprecation.removal_in_version, })
    end
  end

  if field.type == "array" then
    if not is_sequence(value) then
      return nil, validation_errors.ARRAY
    end

    local ok, err = validate_elements(self, field, value)
    if not ok then
      return nil, err
    end

  elseif field.type == "set" then
    if not is_sequence(value) then
      return nil, validation_errors.SET
    end

    field.elements.required = true
    local ok, err = validate_elements(self, field, value)
    if not ok then
      return nil, err
    end

  elseif field.type == "map" then
    if type(value) ~= "table" then
      return nil, validation_errors.MAP
    end

    field.keys.required = true
    field.values.required = true
    for k, v in pairs(value) do
      local ok, err
      ok, err = self:validate_field(field.keys, k)
      if not ok then
        return nil, err
      end
      ok, err = self:validate_field(field.values, v)
      if not ok then
        return nil, err
      end
    end

  elseif field.type == "record" then
    if type(value) ~= "table" then
      return nil, validation_errors.RECORD
    end

    local field_schema = get_field_schema(field)
    -- TODO return nested table or string?
    local copy = field_schema:process_auto_fields(value, "insert")
    -- TODO: explain why we need to make a copy?
    local ok, err = field_schema:validate(copy)
    if not ok then
      return nil, err
    end

  elseif field.type == "foreign" then
    if field.schema and field.schema.validate_primary_key then
      local ok, errs = field.schema:validate_primary_key(value, true)
      if not ok then
        if type(value) == "table" and field.schema.validate then
          local foreign_ok, foreign_errs = field.schema:validate(value, false)
          if not foreign_ok then
            return nil, foreign_errs
          end
        end

        return ok, errs
      end
    end

  elseif field.type == "integer" then
    if not (type(value) == "number"
       and value == floor(value)
       and value ~= 1/0
       and value ~= -1/0) then
      return nil, validation_errors.INTEGER
    end

  elseif field.type == "string" then
    if type(value) ~= "string" then
      return nil, validation_errors.STRING
    end
    -- empty strings are not accepted by default
    if not field.len_min then
      field.len_min = 1
    end

    if field.referenceable and is_reference(value) then
      return true
    end

  elseif field.type == "function" then
    if type(value) ~= "function" then
      return nil, validation_errors.FUNCTION
    end

  elseif self.valid_types[field.type] then
    if type(value) ~= field.type then
      return nil, validation_errors[field.type:upper()]
    end

  -- if type is "any" (an internal marker), run validators only
  elseif field.type ~= "any" then
    return nil, validation_errors.SCHEMA_TYPE:format(field.type)
  end

  local validators = Schema.validators_order
  for i = 1, #validators do
    local k = validators[i]
    if field[k] ~= nil then
      local ok, err = self.validators[k](value, field[k], field)
      if not ok then
        if not err then
          err = (validation_errors[k:upper()]
                 or validation_errors.VALIDATION):format(value)
        end
        return nil, field.err or err
      end
    end
  end

  return true
end


--- Given missing field named `k`, with definition `field`,
-- fill its slot in `entity` with an appropriate default value,
-- if possible.
-- @param field The field definition table.
local function handle_missing_field(field, value, opts)
  local no_defaults = opts and opts.no_defaults
  if field.default ~= nil and not no_defaults then
    local copy = table_tools.cycle_aware_deep_copy(field.default)
    if (field.type == "array" or field.type == "set")
      and type(copy) == "table"
      and not getmetatable(copy)
    then
      setmetatable(copy, cjson.array_mt)
    end
    return copy
  end

  -- If `nilable` (metaschema only), a default value is not necessary.
  if field.nilable then
    return value
  end

  -- If not `required`, it is nullable.
  if field.required ~= true then
    return null
  end

  if field.abstract then
    return nil
  end

  -- if the missing field is a record, expand its structure
  -- to obtain any nested defaults
  if field.type == "record" then
    local field_schema = get_field_schema(field)
    return field_schema:process_auto_fields({}, "insert")
  end

  -- If `required`, it will fail later.
  return nil
end


--- Check if subschema field is compatible with the abstract field it replaces.
-- @return true if compatible, false otherwise.
local function compatible_fields(f1, f2)
  local t1, t2 = f1.type, f2.type
  if t1 ~= t2 then
    return false
  end
  if t1 == "record" then
    return true
  end
  if t1 == "array" or t1 == "set" then
    return f1.elements.type == f2.elements.type
  end
  if t1 == "map" then
    return f1.keys.type == f2.keys.type and f1.values.type == f2.values.type
  end
  return true
end


local function get_subschema(self, input)
  if self.subschemas and self.subschema_key then
    local input_key = input[self.subschema_key]

    if type(input_key) == "string" then
      return self.subschemas[input_key]
    end

    if type(input_key) == "table" then  -- if subschema key is a set, return
      for i = 1, #input_key do  -- subschema for first key
        local subschema = self.subschemas[input_key[i]]
        if subschema then
          return subschema
        end
      end
    end
  end
  return nil
end


local function resolve_field(self, k, field, subschema)
  field = field or self.fields[tostring(k)]
  if not field then
    return nil, validation_errors.UNKNOWN
  end
  if subschema then
    local ss_field = subschema.fields[k]
    if ss_field then
      field = ss_field
    end
  end
  return field
end


--- Validate fields of a table, individually, against the schema.
-- @param self The schema
-- @param input The input table.
-- @return Two arguments: the first is true on success and nil on failure.
-- The second is a table containing all errors, indexed numerically for
-- general errors, and by field name for field errors.
-- In all cases, the input table is untouched.
validate_fields = function(self, input)
  assert(type(input) == "table", validation_errors.BAD_INPUT)

  local errors, _ = {}

  local subschema = get_subschema(self, input)

  for k, v in pairs(input) do
    local err
    local field = self.fields[tostring(k)]

    if field and field.type == "json" then
      local json_schema = field.json_schema
      local inline_schema = json_schema.inline

      if inline_schema then
        _, errors[k] = json_validate(v, inline_schema)

      else
        local parent_key = json_schema.parent_subschema_key
        local json_subschema_key = input[parent_key]

        if json_subschema_key then
          local schema_name = json_schema.namespace .. "/" .. json_subschema_key
          inline_schema = json.get_schema(schema_name) or json_schema.default

          if inline_schema then
            _, errors[k] = json_validate(v, inline_schema)

          elseif not json_schema.optional then
            errors[k] = validation_errors.JSON_SCHEMA_NOT_FOUND:format(schema_name)
          end

        elseif not json_schema.optional then
          errors[k] = validation_errors.JSON_PARENT_KEY_MISSING:format(k, parent_key)
        end
      end

    elseif field and field.type == "self" then
      local pok
      pok, err, errors[k] = pcall(self.validate_field, self, input, v)
      if not pok then
        errors[k] = validation_errors.SCHEMA_CANNOT_VALIDATE
        kong.log.debug(errors[k], ": ", err)
      end

    elseif not self.unvalidated_fields[k]() then
      field, err = resolve_field(self, k, field, subschema)
      if field then
        _, errors[k] = self:validate_field(field, v)
      elseif err == validation_errors.UNKNOWN and v == null and
            kong and kong.configuration and
            kong.configuration.role == "data_plane" then -- luacheck: ignore
        -- extra fields with value of null in the input config are ignored
        -- otherwise record the error
      else
        errors[k] = err
      end
    end
  end

  if next(errors) then
    return nil, errors
  end
  return true, errors
end


local function insert_entity_error(errors, err)
  if not errors["@entity"] then
    errors["@entity"] = {}
  end
  insert(errors["@entity"], err)
end


--- Runs an entity check, making sure it has access to all fields it asked for,
-- and that it only has access to the fields it asked for.
-- It will call `self.entity_checkers[name]` giving it a subset of `input`,
-- based on the list of fields given at `schema.entity_checks[name].fields`.
-- @param self The schema table
-- @param name The name of the entity check
-- @param input The whole input entity.
-- @param arg The argument table of the entity check declaration
-- @param errors The table where errors are accumulated.
-- @return Nothing; the side-effect of this function is to add entries to
-- `errors` if any errors occur.
local function run_entity_check(self, name, input, arg, full_check, errors)
  local check_input = {}
  local checker = self.entity_checkers[name]
  local fields_to_check = {}

  local required_fields = {}
  if checker.field_sources then
    for i = 1, #checker.field_sources do
      local source = checker.field_sources[i]
      local v = arg[source]
      if type(v) == "string" then
        insert(fields_to_check, v)
        if checker.required_fields[source] then
          required_fields[v] = true
        end
      elseif type(v) == "table" then
        for j = 1, #v do
          local fname = v[j]
          insert(fields_to_check, fname)
          if checker.required_fields[source] then
            required_fields[fname] = true
          end
        end
      end
    end
  else
    fields_to_check = arg
    for i = 1, #arg do
      required_fields[arg[i]] = true
    end
  end

  local missing
  local all_nil = true
  local all_ok = true
  for i = 1, #fields_to_check do
    local fname = fields_to_check[i]
    local value = get_field(input, fname)
    if value == nil then
      if (not checker.run_with_missing_fields) and
         (not arg.run_with_missing_fields) and
         (required_fields and required_fields[fname]) and
         (not get_schema_field(self, fname).nilable) then
        missing = missing or {}
        insert(missing, fname)
      end
    else
      all_nil = false

      -- Don't run if any of the values is a reference in a referenceable field
      local field = get_schema_field(self, fname)
      if field.type == "string" and field.referenceable and is_reference(value) then
        return
      end
    end
    if errors[fname] then
      all_ok = false
    end
    set_field(check_input, fname, value)
  end

  -- Don't run check if any of its fields has errors
  if not all_ok
     and not checker.run_with_invalid_fields
     and not arg.run_with_invalid_fields
  then
    return
  end

  -- Don't run check if none of the fields are present (update)
  if all_nil and not (checker.run_with_missing_fields and full_check) then
    return
  end

  -- Don't run check if a required field is missing
  if missing then
    for i = 1, #missing do
      set_field(errors, missing[i], validation_errors.REQUIRED_FOR_ENTITY_CHECK)
    end
    return
  end

  local ok, err, err2 = checker.fn(check_input, arg, self, errors)
  if ok then
    return
  end

  if err2 then
    -- user provided custom error for this entity checker
    insert_entity_error(errors, err2)

  else
    local error_fmt = validation_errors[name:upper()]
    err = error_fmt and error_fmt:format(err) or err
    if not err then
      local data = pretty.write({ name = arg }):gsub("%s+", " ")
      err = validation_errors.ENTITY_CHECK:format(name, data)
    end

    insert_entity_error(errors, err)
  end
end


--- Runs the schema's custom `self.check()` function.
-- It requires the full entity to be present.
-- TODO hopefully deprecate this function.
-- @param self The schema table
-- @param name The name of the entity check
-- @param errors The current table of accumulated field errors.
local function run_self_check(self, input, errors)
  local ok = true
  for fname, field in self:each_field() do
    if input[fname] == nil and not field.nilable then
      local err = validation_errors.REQUIRED_FOR_ENTITY_CHECK:format(fname)
      errors[fname] = err
      ok = false
    end
  end

  if not ok then
    return
  end

  local err
  ok, err = self.check(input)
  if ok then
    return
  end

  if type(err) == "string" then
    insert_entity_error(errors, err)

  elseif type(err) == "table" then
    for k, v in pairs(err) do
      if type(k) == "number" then
        insert_entity_error(errors, v)
      else
        errors[k] = v
      end
    end

  else
    insert_entity_error(errors, validation_errors.CHECK)
  end
end


local run_entity_checks
do
  local function run_checks(self, input, full_check, checks, errors)
    if not checks then
      return
    end
    for i = 1, #checks do
      local check = checks[i]
      local check_name = next(check)
      local arg = check[check_name]
      if arg and arg ~= null then
        run_entity_check(self, check_name, input, arg, full_check, errors)
      end
    end
  end

  --- Run entity checks over the whole table.
  -- This includes the custom `check` function.
  -- In case of any errors, add them to the errors table.
  -- @param self The schema
  -- @param input The input table.
  -- @param full_check If true, demands entity table to be complete.
  -- @param errors The table where errors are accumulated.
  -- @return Nothing; the side-effect of this function is to add entries to
  -- `errors` if any errors occur.
  run_entity_checks = function(self, input, full_check, errors)

    run_checks(self, input, full_check, self.entity_checks, errors)

    local subschema = get_subschema(self, input)
    if subschema then
      local fields_proxy = setmetatable({}, {
        __index = function(_, k)
          return subschema.fields[k] or self.fields[k]
        end
      })
      local self_proxy = setmetatable({}, {
        __index = function(_, k)
          if k == "fields" then
            return fields_proxy
          else
            return self[k]
          end
        end
      })
      run_checks(self_proxy, input, full_check, subschema.entity_checks, errors)
    end

    if self.check and full_check then
      run_self_check(self, input, errors)
    end
  end
end


local function run_transformation_checks(schema_or_subschema, input, original_input, rbw_entity, errors)
  local transformations = schema_or_subschema.transformations
  if transformations then
    for i = 1, #transformations do
      local transformation = transformations[i]
      if transformation.input or transformation.needs then
        local args = {}
        local argc = 0
        local none_set = true
        if transformation.input then
          for j = 1, #transformation.input do
            local input_field_name = transformation.input[j]
            if is_nonempty(get_field(original_input or input, input_field_name)) then
              none_set = false
            end

            argc = argc + 1
            args[argc] = input_field_name
          end
        end

        local needs_changed = false
        if transformation.needs then
          for j = 1, #transformation.needs do
            local input_field_name = transformation.needs[j]
            if rbw_entity and not needs_changed then
              local value = get_field(original_input or input, input_field_name)
              local rbw_value = get_field(rbw_entity, input_field_name)
              if value ~= rbw_value then
                needs_changed = true
              end
            end

            argc = argc + 1
            args[argc] = input_field_name
          end
        end

        if needs_changed or (not none_set) then
          local ok, err = mutually_required(needs_changed and original_input or input, args)
          if not ok then
            insert_entity_error(errors, validation_errors.MUTUALLY_REQUIRED:format(err))

          else
            ok, err = mutually_required(original_input or input, transformation.input)
            if not ok then
              insert_entity_error(errors, validation_errors.MUTUALLY_REQUIRED:format(err))
            end
          end
        end
      end
    end
  end

  local subschema = get_subschema(schema_or_subschema, input)
  if subschema then
    run_transformation_checks(subschema, input, original_input, rbw_entity, errors)
  end
end


--- Ensure that a given table contains only the primary-key
-- fields of the entity and that their fields validate.
-- @param pk A table with primary-key fields only.
-- @param ignore_others If true, the function will ignore non-primary key
-- entries.
-- @return True on success; nil, error message and error table otherwise.
function Schema:validate_primary_key(pk, ignore_others)
  local pk_set = {}
  local errors = {}

  local primary_key = self.primary_key
  for i = 1, #primary_key do
    local k = primary_key[i]
    pk_set[k] = true
    local field = self.fields[k]
    local v = pk[k]

    if not v then
      errors[k] = validation_errors.MISSING_PK

    elseif (field.required or field.auto) and v == null then
      errors[k] = validation_errors.REQUIRED

    else
      local _
      _, errors[k] = self:validate_field(field, v)
    end
  end

  if not ignore_others then
    for k, _ in pairs(pk) do
      if not pk_set[k] then
        errors[k] = validation_errors.NOT_PK
      end
    end
  end

  if next(errors) then
    return nil, errors
  end
  return true
end


local as_set = setmetatable({}, { __mode = "k" })


local Set_mt = {
  __index = function(t, key)
    local set = as_set[t]
    if set then
      return set[key]
    end
  end
}


--- Sets (or replaces) metatable of an array:
-- 1. array is a proper sequence, `cjson.array_mt`
--    will be used as a metatable of the returned array.
-- 2. otherwise no modifications are made to input parameter.
-- @param array The table containing an array for which to apply the metatable.
-- @return input table (with metatable, see above)
local function make_array(array)
  if is_sequence(array) then
    return setmetatable(array, cjson.array_mt)
  end

  return array
end


--- Sets (or replaces) metatable of a set and removes duplicates:
-- 1. set is a proper sequence, but empty, `cjson.array_mt`
--    will be used as a metatable of the returned set.
-- 2. set a proper sequence, and has values, `Set_mt`
--    will be used as a metatable of the returned set.
-- 3. otherwise no modifications are made to input parameter.
-- @param set The table containing a set for which to apply the metatable.
-- @return input table (with metatable, see above)
local function make_set(set)
  if not is_sequence(set) then
    return set
  end

  local count = #set

  if count == 0 then
    return setmetatable(set, cjson.array_mt)
  end

  local o = {}
  local s = {}
  local j = 0

  for i = 1, count do
    local v = set[i]
    if not s[v] then
      j = j + 1
      o[j] = v
      s[v] = true
    end
  end

  as_set[o] = s

  return setmetatable(o, Set_mt)
end


local function should_recurse_record(context, value, field)
  if context == "update" then
    return value ~= null and value ~= nil
  else
    return value ~= null and (value ~= nil or field.required == true)
  end
end


local function adjust_field_for_context(field, value, context, nulls, opts)
  if context == "select" and value == null and field.required == true then
    return handle_missing_field(field, value, opts)
  end

  if field.abstract then
    return value
  end

  if field.type == "record" then
    if should_recurse_record(context, value, field) then
      value = value or handle_missing_field(field, value, opts)
      if type(value) == "table" then
        local field_schema = get_field_schema(field)
        return field_schema:process_auto_fields(value, context, nulls, opts)
      end
    end

  elseif type(value) == "table" then
    local subfield
    if field.type == "array" then
      value = make_array(value)
      subfield = field.elements

    elseif field.type == "set" then
      value = make_set(value)
      subfield = field.elements

    elseif field.type == "map" then
      subfield = field.values
    end

    if subfield then
      -- uses pairs also for arrays and sets as well as maps, as there can be holes
      for k, v in pairs(value) do
        value[k] = adjust_field_for_context(subfield, v, context, nulls, opts)
      end
    end
  end

  if value == nil and context ~= "update" then
    return handle_missing_field(field, value, opts)
  end

  return value
end


--- Given a table, update its fields whose schema
-- definition declares them as `auto = true`,
-- based on its CRUD operation context, and set
-- defaults for missing values when the CRUD context
-- is "insert".
-- This function encapsulates various "smart behaviors"
-- for value creation and update.
-- @param data The table containing data to be processed.
-- @param context a string describing the CRUD context:
-- valid values are: "insert", "update", "upsert", "select"
-- @param nulls boolean: return nulls as explicit ngx.null values
-- @return A new table, with the auto fields containing
-- appropriate updated values (except for "select" context
-- it does it in place by modifying the data directly).
function Schema:process_auto_fields(data, context, nulls, opts)
  yield(true)

  local check_immutable_fields = false

  local is_select = context == "select"
  if not is_select then
    data = table_tools.cycle_aware_deep_copy(data)
  end

  local shorthand_fields = self.shorthand_fields
  if shorthand_fields then
    local errs = {}
    local has_errs
    for i = 1, #shorthand_fields do
      local sname, sdata = next(shorthand_fields[i])
      local value = data[sname]
      if value ~= nil then
        local _, err = self:validate_field(sdata, value)
        if err then
          errs[sname] = err
          has_errs = true
        else
          data[sname] = nil
          local new_values = sdata.func(value)
          if new_values then
            for k, v in pairs(new_values) do
              if type(v) == "table" then
                data[k] = tablex.merge(data[k] or {}, v, true)
              else
                data[k] = v
              end
            end
          end
        end
      end

      if is_select and sdata.translate_backwards and not(opts and opts.hide_shorthands) then
        data[sname] = table_tools.table_path(data, sdata.translate_backwards)
      end
    end
    if has_errs then
      return nil, errs
    end
  end

  local now_s
  local now_ms

  -- We don't want to resolve references on control planes
  -- and admin api requests, admin api request could be
  -- detected with ngx.ctx.KONG_PHASE, but to limit context
  -- access we use nulls that admin api sets to true.
  local kong = kong
  local resolve_references
  if is_select and not nulls then
    if kong and kong.configuration then
      resolve_references = kong.configuration.role ~= "control_plane"
    else
      resolve_references = true
    end
  end

  local refs
  local prev_refs = resolve_references and data["$refs"]

  for key, field in self:each_field(data) do
    local ftype = field.type
    local value = data[key]
    if not is_select and field.auto then
      local is_insert_or_upsert = context == "insert" or context == "upsert"
      if field.uuid then
        if is_insert_or_upsert and value == nil then
          value = uuid()
        end

      elseif ftype == "string" then
        if is_insert_or_upsert and value == nil then
          value = random_string()
        end

      elseif (key == "created_at" and is_insert_or_upsert and (value == null or
                                                               value == nil))
      or
             (key == "updated_at" and (is_insert_or_upsert or context == "update"))
      then
        if ftype == "number" then
          if not now_ms then
            update_time()
            now_ms = ngx_now()
          end
          value = now_ms

        elseif ftype == "integer" then
          if not now_s then
            update_time()
            now_s = ngx_time()
          end
          value = now_s
        end
      end
    end

    local err
    value, err = adjust_field_for_context(field, value, context, nulls, opts)
    if err then
      return nil, err
    end

    if is_select then
      local vtype = type(value)
      if value == null and not nulls then
        value = nil
      elseif ftype == "integer" and vtype == "number" then
        value = floor(value)
      end

      if resolve_references then
        if ftype == "string" and field.referenceable then
          if is_reference(value) then
            if refs then
              refs[key] = value
            else
              refs = { [key] = value }
            end

            local deref, err = kong.vault.get(value)
            if deref then
              value = deref

            else
              if err then
                kong.log.warn("unable to resolve reference ", value, " (", err, ")")
              else
                kong.log.notice("unable to resolve reference ", value)
              end

              value = ""
            end

          elseif prev_refs and prev_refs[key] then
            if refs then
              refs[key] = prev_refs[key]
            else
              refs = { [key] = prev_refs[key] }
            end
          end

        elseif vtype == "table" and (ftype == "array" or ftype == "set") then
          local subfield = field.elements
          if subfield.type == "string" and subfield.referenceable then
            local count = #value
            if count > 0 then
              for i = 1, count do
                if is_reference(value[i]) then
                  if not refs then
                    refs = {}
                  end

                  if not refs[key] then
                    refs[key] = new_tab(count, 0)
                  end

                  refs[key][i] = value[i]

                  local deref, err = kong.vault.get(value[i])
                  if deref then
                    value[i] = deref

                  else
                    if err then
                      kong.log.warn("unable to resolve reference ", value[i], " (", err, ")")
                    else
                      kong.log.notice("unable to resolve reference ", value[i])
                    end

                    value[i] = ""
                  end
                end
              end
            end

            if prev_refs and prev_refs[key] then
              if refs then
                if not refs[key] then
                  refs[key] = prev_refs[key]
                end

              else
                refs = { [key] = prev_refs[key] }
              end
            end
          end

        elseif vtype == "table" and ftype == "map" then
          local subfield = field.values
          if subfield.type == "string" and subfield.referenceable then
            local count = nkeys(value)
            if count > 0 then
              for k, v in pairs(value) do
                if is_reference(v) then
                  if not refs then
                    refs = {}
                  end

                  if not refs[key] then
                    refs[key] = new_tab(0, count)
                  end

                  refs[key][k] = v

                  local deref, err = kong.vault.get(v)
                  if deref then
                    value[k] = deref

                  else
                    if err then
                      kong.log.warn("unable to resolve reference ", v, " (", err, ")")
                    else
                      kong.log.notice("unable to resolve reference ", v)
                    end

                    value[k] = ""
                  end
                end
              end
            end

            if prev_refs and prev_refs[key] then
              if refs then
                if not refs[key] then
                  refs[key] = prev_refs[key]
                end

              else
                refs = { [key] = prev_refs[key] }
              end
            end
          end
        end
      end

    elseif context == "update" and field.immutable then
      check_immutable_fields = true
    end

    data[key] = value
  end

  if not is_select then
    return data, nil, check_immutable_fields
  end

  if self.ttl and data.ttl == null and not nulls then
    data.ttl = nil
  end

  local show_ws = opts and opts.show_ws_id
  for key in pairs(data) do
    local field = self.fields[key]
    if field then
      if field.type == "string" and (field.len_min or 1) > 0 and data[key] == "" and not (refs and refs[key])
      then
        data[key] = nulls and null or nil
      end

    elseif not ((key == "ttl"   and self.ttl) or
                (key == "ws_id" and show_ws)) then

      local should_be_in_ouput = false

      if self.shorthand_fields then
        for _, shorthand_field in ipairs(self.shorthand_fields) do
          if shorthand_field[key] and shorthand_field[key].translate_backwards then
            should_be_in_ouput = is_select
          end
        end
      end

      if not should_be_in_ouput then
        data[key] = nil
      end
    end
  end

  data["$refs"] = refs

  return data
end


--- Schema-aware deep-merge of two entities.
-- Uses schema knowledge to merge two records field-by-field,
-- but not merge the content of two arrays.
-- @param top the entity whose values take precedence
-- @param bottom the entity whose values are the fallback
-- @return the merged entity
function Schema:merge_values(top, bottom)
  local output = {}
  bottom = (bottom ~= nil and bottom ~= null) and bottom or {}
  for k,v in pairs(bottom) do
    output[k] = v
  end
  for k,v in pairs(top) do
    output[k] = v
  end
  for key, field in self:each_field(bottom) do
    local top_v = top[key]

    if top_v == nil then
      output[key] = bottom[key]

    else
      if field.type == "record" and not field.abstract and type(top_v) == "table" then
        output[key] = get_field_schema(field):merge_values(top_v, bottom[key])
      else
        output[key] = top_v
      end
    end
  end
  return output
end


--[[
function Schema:load_translations(translation)
  if not self.translations then
    self.translations = {}
  end

  for i = 1, #self.translations do
    if self.translations[i] == translation then
      return
    end
  end

  insert(self.translations, translation)
end
--]]


--- Validate a table against the schema, ensuring that the entity is complete.
-- It validates fields for their attributes,
-- and runs the global entity checks against the entire table.
-- @param input The input table.
-- @param full_check If true, demands entity table to be complete.
-- If false, accepts missing `required` fields when those are not
-- needed for global checks.
-- @param original_input The original input for transformation validations.
-- @param rbw_entity The read-before-write entity, if any.
-- @return True on success.
-- On failure, it returns nil and a table containing all errors,
-- indexed by field name for field errors, plus an "@entity" key
-- containing entity-checker and self-check errors.
-- This is an example of what an error table looks like:
--  {
--     ["name"] = "...error message...",
--     ["service"] = {
--        ["id"] = "...error message...",
--     }
--     ["@entity"] = {
--       "error message from at_least_one_of",
--       "error message from other entity validators",
--       "first error message from self-check function",
--       "second error message from self-check function",
--     }
--  }
-- In all cases, the input table is untouched.
function Schema:validate(input, full_check, original_input, rbw_entity)
  if full_check == nil then
    full_check = true
  end

  if self.subschema_key then
    -- If we can't determine the subschema, do not validate any further
    local key = input[self.subschema_key]
    if key == null or key == nil then
      return nil, {
        [self.subschema_key] = validation_errors.REQUIRED
      }
    end

    if not get_subschema(self, input) then
      local errmsg = self.subschema_error or validation_errors.SUBSCHEMA_UNKNOWN
      return nil, {
        [self.subschema_key] = errmsg:format(type(key) == "string" and key or key[1])
      }
    end
  end

  local _, errors = validate_fields(self, input)

  for name, field in self:each_field() do
    if field.required
       and (input[name] == null
            or (full_check and input[name] == nil)) then
      errors[name] = validation_errors.REQUIRED
    end
  end

  run_entity_checks(self, input, full_check, errors)
  run_transformation_checks(self, input, original_input, rbw_entity, errors)

  if next(errors) then
    return nil, errors
  end
  return true
end


-- Iterate through input fields on update and check against schema for
-- immutable attribute. If immutable attribute is set, compare input values
-- against entity values to determine whether input is valid.
-- @param input The input table.
-- @param entity The entity update will be performed on.
-- @return True on success.
-- On failure, it returns nil and a table containing all errors by field name.
-- In all cases, the input table is untouched.
function Schema:validate_immutable_fields(input, entity)
  local errors = {}

  for key, field in self:each_field(input) do
    local compare = table_tools.is_array(input[key]) and tablex.compare_no_order or tablex.deepcompare

    if field.immutable and entity[key] ~= nil and not compare(input[key], entity[key]) then
      errors[key] = validation_errors.IMMUTABLE
    end
  end

  if next(errors) then
    return nil, errors
  end

  return true, errors
end


--- Validate a table against the schema, ensuring that the entity is complete.
-- It validates fields for their attributes,
-- and runs the global entity checks against the entire table.
-- @param input The input table.
-- @param original_input The original input for transformation validations.
-- @return True on success.
-- On failure, it returns nil and a table containing all errors,
-- indexed numerically for general errors, and by field name for field errors.
-- In all cases, the input table is untouched.
function Schema:validate_insert(input, original_input)
  return self:validate(input, true, original_input)
end


-- Validate a table against the schema, accepting a partial entity.
-- It validates fields for their attributes, but accepts missing `required`
-- fields when those are not needed for global checks,
-- and runs the global checks against the entire table.
-- @param input The input table.
-- @param original_input The original input for transformation validations.
-- @param rbw_entity The read-before-write entity, if any.
-- @return True on success.
-- On failure, it returns nil and a table containing all errors,
-- indexed numerically for general errors, and by field name for field errors.
-- In all cases, the input table is untouched.
function Schema:validate_update(input, original_input, rbw_entity)

  -- Monkey-patch some error messages to make it clearer why they
  -- apply during an update. This avoids propagating update-awareness
  -- all the way down to the entity checkers (which would otherwise
  -- defeat the whole purpose of the mechanism).
  local rfec = validation_errors.REQUIRED_FOR_ENTITY_CHECK
  local aloo = validation_errors.AT_LEAST_ONE_OF
  local caloo = validation_errors.CONDITIONAL_AT_LEAST_ONE_OF
  validation_errors.REQUIRED_FOR_ENTITY_CHECK = rfec .. " when updating"
  validation_errors.AT_LEAST_ONE_OF = "when updating, " .. aloo
  validation_errors.CONDITIONAL_AT_LEAST_ONE_OF = "when updating, " .. caloo

  local ok, errors = self:validate(input, false, original_input, rbw_entity)

  -- Restore the original error messages
  validation_errors.REQUIRED_FOR_ENTITY_CHECK = rfec
  validation_errors.AT_LEAST_ONE_OF = aloo
  validation_errors.CONDITIONAL_AT_LEAST_ONE_OF = caloo

  return ok, errors
end


--- Validate a table against the schema, ensuring that the entity is complete.
-- It validates fields for their attributes,
-- and runs the global entity checks against the entire table.
-- @param input The input table.
-- @param original_input The original input for transformation validations.
-- @return True on success.
-- On failure, it returns nil and a table containing all errors,
-- indexed numerically for general errors, and by field name for field errors.
-- In all cases, the input table is untouched.
function Schema:validate_upsert(input, original_input)
  return self:validate(input, true, original_input)
end


--- An iterator for schema fields.
-- Returns a function to be used in `for` loops,
-- which produces the key and the field table,
-- as in `for field_name, field_data in self:each_field() do`
-- @param values An instance of the entity, which is used
-- only to determine which subschema to use.
-- @return the iteration function
function Schema:each_field(values)
  local i = 1

  local subschema
  if values then
    subschema = get_subschema(self, values)
  end

  return function()
    local item = self.fields[i]
    if not item then
      return nil
    end
    local key = next(item)
    local field = resolve_field(self, key, item[key], subschema)
    i = i + 1
    return key, field
  end
end


--- Produce a string error message based on the table of errors
-- produced by the `validate` function.
-- @param errors The table of errors.
-- @return A string representing the errors, or nil if there
-- were no errors or a table was not given.
function Schema:errors_to_string(errors)
  if not errors or type(errors) ~= "table" or not next(errors) then
    return nil
  end

  local msgs = {}

  -- General errors first
  if errors["@entity"] then
    for _, err in pairs(errors["@entity"]) do
      insert(msgs, err)
    end
  end

  for i = 1, #errors do
    insert(msgs, errors[i])
  end

  -- Field-specific errors
  for k, err in pairs(errors) do
    if k ~= "@entity" then
      if type(err) == "table" then
        err = self:errors_to_string(err)
      end
      if type(k) == "string" then
        insert(msgs, k..": "..err)
      end
    end
  end

  local summary = concat(msgs, "; ")
  return validation_errors.ERROR:format(summary)
end


--- Given an entity, return a table containing only its primary key entries
-- @param entity a table mapping field names to their values
-- @return a subset of the input table, containing only the keys that
-- are part of the primary key for this schema.
function Schema:extract_pk_values(entity)
  local pk_len = #self.primary_key
  local pk_values = new_tab(0, pk_len)

  for i = 1, pk_len do
    local pk_name = self.primary_key[i]
    pk_values[pk_name] = entity[pk_name]
  end

  return pk_values
end


--- Given a field of type `"foreign"`, returns the schema object for it.
-- @param field A field definition table
-- @return A schema object, or nil and an error message.
local function get_foreign_schema_for_field(field)
  local ref = field.reference

  local foreign_schema = _cache[ref] and _cache[ref].schema
  if not foreign_schema then
    return nil, validation_errors.SCHEMA_BAD_REFERENCE:format(ref)
  end

  return foreign_schema
end


function Schema:get_constraints()
  if self.name == "workspaces" then
    -- merge explicit and implicit constraints for workspaces
    for _, e in pairs(_cache["workspaces"].constraints) do
      local found = false
      for i = 1, #_workspaceable do
        if _workspaceable[i] == e then
          found = true
          break
        end
      end
      if not found then
        insert(_workspaceable, e)
      end
    end
    return _workspaceable
  end

  local constraints = {}
  for _, c in pairs(_cache[self.name].constraints) do
    insert(constraints, c)
  end
  return constraints
end


local function allow_record_fields_by_name(record, loop)
  loop = loop or {}
  if loop[record] then
    return
  end
  loop[record] = true
  for k, f in Schema.each_field(record) do
    record.fields[k] = f
    if f.type == "record" and f.fields then
      allow_record_fields_by_name(f, loop)
    end
  end
end


local function get_transform_args(input, original_input, output, transformation)
  local args = {}
  local argc = 0
  for i = 1, #transformation.input do
    local input_field_name = transformation.input[i]
    local value = get_field(output or original_input or input, input_field_name)
    if is_nonempty(value) then
      argc = argc + 1
      if original_input then
        args[argc] = get_field(output or input, input_field_name)
      else
        args[argc] = value
      end

    else
      return nil
    end
  end

  if transformation.needs then
    for i = 1, #transformation.needs do
      local need = transformation.needs[i]
      local value = get_field(output or input, need)
      if is_nonempty(value) then
        argc = argc + 1
        args[argc] = get_field(output or input, need)

      else
        return nil
      end
    end
  end
  return args
end


local function run_transformations(self, transformations, input, original_input, context)
  if self.type == "json" and context == "select" then
    local decoded, err = safe_decode(input)
    if err then
      return nil, validation_errors.JSON_DECODE_ERROR:format(err)
    end
    input = decoded
  end

  local output
  for i = 1, #transformations do
    local transformation = transformations[i]
    local transform
    if context == "select" then
      transform = transformation.on_read

    else
      transform = transformation.on_write
    end

    if transform then
      if transformation.input or transformation.needs then
        local args = get_transform_args(input, original_input, output, transformation)
        if args then
          local data, err = transform(unpack(args))
          if err then
            return nil, validation_errors.TRANSFORMATION_ERROR:format(err)
          end

          output = self:merge_values(data, output or input)
        end

      else
        local data, err = transform(output or input)
        if err then
          return nil, validation_errors.TRANSFORMATION_ERROR:format(err)
        end

        output = self:merge_values(data, output or input)
      end
    end
  end

  return output or input
end

--- Check if the schema has transformation definitions.
-- @param input a table holding entities
-- @return a boolean value: 'true' or 'false'
function Schema:has_transformations(input)
  if self.transformations then
    return true
  end

  local subschema = get_subschema(self, input)
  if subschema and subschema.transformations then
    return true
  end

  return false
end

--- Run transformations on fields.
-- @param input The input table.
-- @param original_input The original input for transformation detection.
-- @param context a string describing the CRUD context:
-- valid values are: "insert", "update", "upsert", "select"
-- @return the transformed entity
function Schema:transform(input, original_input, context)
  local output, err
  if self.transformations then
    output, err = run_transformations(self, self.transformations, input, original_input, context)
    if not output then
      return nil, err
    end
  end

  local subschema = get_subschema(self, input)
  if subschema and subschema.transformations then
    output, err = run_transformations(subschema, subschema.transformations, output or input, original_input, context)
    if not output then
      return nil, err
    end
  end

  return output or input
end

--- Instatiate a new schema from a definition.
-- @param definition A table with attributes describing
-- fields and other information about a schema.
-- @param is_subschema boolean, true if definition
-- is a subschema
-- @return The object implementing the schema matching
-- the given definition.
function Schema.new(definition, is_subschema)
  if not definition then
    return nil, validation_errors.SCHEMA_NO_DEFINITION
  end

  if not definition.fields then
    return nil, validation_errors.SCHEMA_NO_FIELDS
  end

  local self = table_tools.cycle_aware_deep_copy(definition)
  setmetatable(self, Schema)

  local cache_key = self.cache_key
  if cache_key then
    self.cache_key_set = {}
    for i = 1, #cache_key do
      self.cache_key_set[cache_key[i]] = true
    end
  end

  for key, field in self:each_field() do
    -- Also give access to fields by name
    self.fields[key] = field
    if field.type == "record" and field.fields then
      allow_record_fields_by_name(field)
    end

    if field.type == "foreign" then
      local err
      field.schema, err = get_foreign_schema_for_field(field)
      if not field.schema then
        return nil, err
      end

      if not is_subschema then
        -- Store the inverse relation for implementing constraints
        local constraints = assert(_cache[field.reference]).constraints
        -- Set logic to prevent duplicates when Schema is initialized multiple times
        if self.name then
          constraints[self.name] = {
            schema     = self,
            field_name = key,
            on_delete  = field.on_delete,
          }
        end
      end
    end
  end

  if self.workspaceable and self.name then
    if not _workspaceable[self.name] then
      _workspaceable[self.name] = true
      insert(_workspaceable, { schema = self })
    end
  end

  if self.name then
    -- do not reset the constraints list if a schema in reloaded
    if not _cache[self.name] then
      _cache[self.name] = {
        constraints = {},
      }
    end
    -- but always update the schema object in cache
    _cache[self.name].schema = self
  end

  -- timestamp-irrelevant fields should not be a critial factor on entities to
  -- be loaded or refreshed correctly. These fields, such as `ttl` and `updated_at`
  -- might be ignored during validation.
  -- unvalidated_fields is added for ignoring some fields, key in the table is the
  -- name of the field to be ignored, the value must be a function, when the field
  -- should be ignored, it returns true otherwise returns false.
  self.unvalidated_fields = {
    ["ttl"] = function ()
      return self.ttl
    end,
    ["updated_at"] = function()
      return true
    end
  }

  setmetatable(self.unvalidated_fields, {
    __index = function()
      return function() -- default option
        return false
      end
    end
  })


  return self
end


function Schema.new_subschema(self, key, definition)
  assert(type(key) == "string", "key must be a string")
  assert(type(definition) == "table", "definition must be a table")

  if not self.subschema_key then
    return nil, validation_errors.SUBSCHEMA_BAD_PARENT:format(key, self.name)
  end

  local subschema, err = Schema.new(definition, true)
  if not subschema then
    return nil, err
  end

  local parent_by_name = {}
  for i = 1, #self.fields do
    local fname, fdata = next(self.fields[i])
    parent_by_name[fname] = fdata
  end

  for fname, field in subschema:each_field() do
    local parent_field = parent_by_name[fname]
    if not parent_field then
      return nil, validation_errors.SUBSCHEMA_BAD_FIELD:format(key, fname)
    end
    if not compatible_fields(parent_field, field) then
      return nil, validation_errors.SUBSCHEMA_BAD_TYPE:format(key, fname)
    end
  end

  for fname, field in pairs(parent_by_name) do
    if field.abstract and field.required and not subschema.fields[fname] then
      return nil, validation_errors.SUBSCHEMA_UNDEFINED_FIELD:format(key, fname)
    end
  end

  if not self.subschemas then
    self.subschemas = {}
  end
  self.subschemas[key] = subschema

  return true
end


function Schema.define(tbl)
  return setmetatable(tbl, {
    __call = function(t, arg)
      arg = arg or {}
      for k,v in pairs(t) do
        if arg[k] == nil then
          arg[k] = v
        end
      end
      return arg
    end
  })
end


return Schema
