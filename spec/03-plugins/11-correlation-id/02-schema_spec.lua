local schema_def = require "kong.plugins.correlation-id.schema"
local v = require("spec.helpers").validate_plugin_config_schema
local helpers = require "spec.helpers"
local uuid = require "resty.jit-uuid"
local pgmoon_json = require("pgmoon.json")
local cjson = require "cjson"

describe("Schema: correlation-id", function ()
  it("requried field must be included", function()
    local ok, err = v({
      generator = ngx.null,
     }, schema_def)

    assert.falsy(ok)
    assert.is_not_nil(err)
    assert.equals("required field missing", err.config.generator)
  end)
end)

local strategy = "postgres"
describe("Plugin: correlation-id (schema) #a [#" .. strategy .."]", function()
  local admin_client, bp, db, plugin_id,ws
  local plugin_config = {
    generator = ngx.null,
    header_name = "Kong-Request-ID",
    echo_downstream = true,
  }

  local function render(template, keys)
    return (template:gsub("$%(([A-Z_]+)%)", keys))
  end

  lazy_setup(function()
    local plugin_name = "correlation-id"
    bp, db = helpers.get_db_utils(strategy, { "plugins", "workspaces", })
    ws = db.workspaces:select_by_name("default")
    assert.is_truthy(ws)
    plugin_id = uuid.generate_v4()
    local sql = render([[
      INSERT INTO plugins (id, name, config, enabled, ws_id) VALUES
        ('$(ID)', '$(PLUGIN_NAME)', $(CONFIG)::jsonb, TRUE, '$(WS_ID)');
      COMMIT;
    ]], {
      ID = plugin_id,
      PLUGIN_NAME = plugin_name,
      CONFIG = pgmoon_json.encode_json(plugin_config),
      WS_ID = ws.id,
    })

    local res, err = db.connector:query(sql)
    assert.is_nil(err)
    assert.is_not_nil(res)
  end)

  describe("in traditional mode", function()
    lazy_setup(function()
      assert(helpers.start_kong({
        database = strategy,
      }))
    end)

    before_each(function()
      admin_client = helpers.admin_client()
    end)

    after_each(function()
      admin_client:close()
    end)

    lazy_teardown(function()
      if admin_client then
        admin_client:close()
      end
      assert(helpers.stop_kong())
    end)

    it("auto-complete generator if it is `null` in database", function()
      local sql = 'SELECT config FROM plugins WHERE id=\''.. plugin_id ..'\';'
      local res, err = db.connector:query(sql)
      assert.is_nil(err)
      assert.is_nil(res[1].generator)

      res = admin_client:get("/plugins")
      res = cjson.decode(assert.res_status(200, res))
      assert.equals(res.data[1].config.generator, "uuid#counter")
    end)
  end)

  for _, rpc_sync in ipairs { "off", "on" } do
  describe("in hybrid mode" .. " rpc_sync=" .. rpc_sync, function()
    local route
    lazy_setup(function()
      route = bp.routes:insert({
        hosts = {"example.com"},
      })
      bp.plugins:insert {
        name    = "request-termination",
        route   = { id = route.id },
        config  = {
          status_code = 200,
        },
      }
      local sql = render([[
        UPDATE plugins SET route_id='$(ROUTE_ID)', 
        protocols=ARRAY['grpc','grpcs','http','https'], 
        cache_key='$(CACHE_KEY)' 
        WHERE id='$(ID)';
        COMMIT;
      ]], {
        ROUTE_ID = route.id,
        --CACHE_KEY = "plugins:correlation-id:"..route.id.."::::"..ws.id,
        CACHE_KEY = "plugins|"..ws.id.."|route|"..route.id.."|"..plugin_id,
        ID = plugin_id,
      })
      local _, err = db.connector:query(sql)
      assert.is_nil(err)

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        database = strategy,
        prefix = "servroot",
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        cluster_rpc_sync = rpc_sync,
      }))

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        status_listen = "127.0.0.1:9100",
        cluster_rpc_sync = rpc_sync,
      }))
    end)

    before_each(function()
      admin_client = helpers.admin_client()
    end)

    after_each(function()
      admin_client:close()
    end)

    lazy_teardown(function()
      if admin_client then
        admin_client:close()
      end
      helpers.stop_kong("servroot")
      helpers.stop_kong("servroot2")
    end)

    it("auto-complete generator if it is `null` in database", function()
      local sql = 'SELECT config FROM plugins WHERE id=\''.. plugin_id ..'\';'
      local res, err = db.connector:query(sql)
      assert.is_nil(err)
      assert.is_nil(res[1].generator)

      local status_client = helpers.http_client("127.0.0.1", 9100, 20000)
      helpers.wait_until(function()
        res = status_client:get("/status/ready")
        return pcall(assert.res_status, 200, res)
      end, 30)
      status_client:close()

      res = admin_client:get("/routes/".. route.id .. "/plugins/" .. plugin_id)
      res = cjson.decode(assert.res_status(200, res))
      assert.equals("uuid#counter", res.config.generator)

      local proxy_client = helpers.proxy_client(20000, 9002, "127.0.0.1")
      res = assert(proxy_client:send {
        method = "GET",
        path = "/",
        headers = {
          ["Host"] = "example.com",
        }
      })
      assert.res_status(200, res)
      assert.is_not_nil(res.headers["Kong-Request-ID"])
      proxy_client:close()
    end)
  end)
  end -- for rpc_sync
end)
