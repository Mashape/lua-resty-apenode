require("spec.helpers") -- for kong.log
local declarative = require "kong.db.declarative"
local conf_loader = require "kong.conf_loader"
local uuid = require "kong.tools.uuid"

local pl_file = require "pl.file"

local null = ngx.null


describe("declarative", function()
  describe("parse_string", function()
    it("converts lyaml.null to ngx.null", function()
      local dc = declarative.new_config(conf_loader())
      local entities, err = dc:parse_string [[
_format_version: "1.1"
routes:
  - name: null
    paths:
    - /
]]
      assert.equal(nil, err)
      local _, route = next(entities.routes)
      assert.equal(null,   route.name)
      assert.same({ "/" }, route.paths)
    end)
  end)

  it("ttl fields are accepted in DB-less schema validation", function()
    local dc = declarative.new_config(conf_loader())
    local entities, err = dc:parse_string([[
_format_version: '2.1'
consumers:
- custom_id: ~
  id: e150d090-4d53-4e55-bff8-efaaccd34ec4
  tags: ~
  username: bar@example.com
services:
keyauth_credentials:
- created_at: 1593624542
  id: 3f9066ef-b91b-4d1d-a05a-28619401c1ad
  tags: ~
  ttl: ~
  key: test
  consumer: e150d090-4d53-4e55-bff8-efaaccd34ec4
]])
    assert.equal(nil, err)

    assert.is_nil(entities.keyauth_credentials['3f9066ef-b91b-4d1d-a05a-28619401c1ad'].ttl)
  end)

  describe("unique_field_key()", function()
    local unique_field_key = declarative.unique_field_key
    local sha256_hex = require("kong.tools.sha256").sha256_hex

    it("utilizes the schema name, workspace id, field name, and checksum of the field value", function()
      local key = unique_field_key("services", "123", "fieldname", "test", false)
      assert.is_string(key)
      assert.equals("U|services|fieldname|123|" .. sha256_hex("test"), key)
    end)

    -- since rpc sync the param `unique_across_ws` is useless
    -- this test case is just for compatibility
    it("does not omits the workspace id when 'unique_across_ws' is 'true'", function()
      local key = unique_field_key("services", "123", "fieldname", "test", true)
      assert.equals("U|services|fieldname|123|" .. sha256_hex("test"), key)
    end)
  end)

  it("parse nested entities correctly", function ()
    -- This test case is to make sure that when a relatively
    -- "raw" input of declarative config is given, the dc parser
    -- can generate correct UUIDs for those nested entites.
    --
    -- See https://github.com/Kong/kong/pull/14082 for more details.
    local cluster_cert_content = assert(pl_file.read("spec/fixtures/kong_clustering.crt"))
    local cluster_key_content = assert(pl_file.read("spec/fixtures/kong_clustering.key"))
    local cert_id = uuid.uuid()
    local sni_id = uuid.uuid()
    local dc = declarative.new_config(conf_loader())
    local entities, err = dc:parse_table(
      {
        _format_version = "3.0",
        certificates = { {
            cert = cluster_cert_content,
            id = cert_id,
            key = cluster_key_content,
            snis = { {
                id = sni_id,
                name = "alpha.example"
              } }
          } },
        consumers = { {
            basicauth_credentials = { {
                password = "qwerty",
                username = "qwerty"
              } },
            username = "consumerA"
          } }
      }
    )

    assert.is_nil(err)
    assert.is_table(entities)
    assert.is_not_nil(entities.snis)
    assert.same('alpha.example', entities.certificates[cert_id].snis[1].name)
  end)

end)
