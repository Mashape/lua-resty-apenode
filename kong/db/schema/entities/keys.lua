local typedefs = require "kong.db.schema.typedefs"
local Schema = require "kong.db.schema"
local cjson = require "cjson.safe"
local supported_key_formats = require "kong.constants".KEY_FORMATS
local null = ngx.null

return {
  name          = "keys",
  dao           = "kong.db.dao.keys",
  primary_key   = { "id" },
  cache_key     = { "kid", "set" },
  endpoint_key  = "name",
  workspaceable = true,
  ttl           = false,
  fields        = {
    {
      id = typedefs.uuid,
    },
    {
      set = {
        type      = "foreign",
        description = "The id of the Key Set with which to associate the key.",
        required  = false,
        reference = "key_sets",
        on_delete = "cascade",
      },
    },
    {
      name = {
        type     = "string",
        description = "The name to associate with the given keys.",
        required = false,
        unique   = true,
      },
    },
    {
      kid = {
        type     = "string",
        description = "A unique identifier for a key.",
        required = true,
        unique   = false,
      },
    },
    {
      x5t = {
        type     = "string",
        description = "X.509 certificate SHA-1 thumbprint.",
        required = false,
        unique = false,
      },
    },
    {
      jwk = {
        -- type string but validate against typedefs.jwk
        type = "string",
        description = "A JSON Web Key represented as a string.",
        referenceable = true,
        encrypted = true
      }
    },
    {
      pem = typedefs.pem
    },
    {
      tags = typedefs.tags,
    },
    {
      created_at = typedefs.auto_timestamp_s,
    },
    {
      updated_at = typedefs.auto_timestamp_s,
    },
  },
  entity_checks = {
    -- XXX: add mutually exclusive to jwk and pem for now.
    -- to properly implement this we need to check that the keys are the same
    -- to avoid false assumptions for an object.
    {
      mutually_exclusive = supported_key_formats
    },
    {
      at_least_one_of = supported_key_formats
    },
    { custom_entity_check = {
      field_sources = { "jwk", "pem", "kid", "x5t" },
      fn = function(entity)
        -- JWK validation
        if type(entity.jwk) == "string" then
          if kong.vault.is_reference(entity.jwk) then
            -- can't validate a reference
            return true
          end
          -- validate against the typedef.jwk
          local schema = Schema.new(typedefs.jwk)
          if not schema then
            return nil, "could not load jwk schema"
          end

          -- it must json decode
          local json_jwk, decode_err = cjson.decode(entity.jwk)
          if decode_err then
            return nil, "could not json decode jwk string"
          end

          -- For JWK the `jwk.kid` must match the `kid` from the upper level
          if json_jwk.kid ~= entity.kid then
            return nil, "kid in jwk.kid must be equal to keys.kid"
          end

          -- For JWK the `jwk.x5t` must match the `x5t` from the upper level
          if entity.x5t and entity.x5t ~= null and json_jwk.x5t ~= entity.x5t then
            return nil, "x5t in jwk.x5t must be equal to keys.x5t"
          end

          -- running customer_validator
          local ok, val_err = typedefs.jwk.custom_validator(entity.jwk)
          if not ok or val_err then
            return nil, val_err or "could not load JWK"
          end
          -- FIXME: this does not execute the `custom_validator` part.
          --        how to do that without loading that manually as seen above
          local _, err = schema:validate(json_jwk, true)
          if err then
            local err_str = schema:errors_to_string(err)
            return nil, err_str
          end
        end

        -- PEM validation
        if type(entity.pem) == "table" and not
            (entity.pem.private_key or
             entity.pem.public_key) then
          return nil, "need to supply a PEM formatted public and/or private key."
        end
        return true
      end
    } }
  }
}
