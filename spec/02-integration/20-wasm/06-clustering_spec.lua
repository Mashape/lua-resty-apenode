local helpers = require "spec.helpers"
local cjson = require "cjson.safe"
local STATUS = require("kong.constants").CLUSTERING_SYNC_STATUS
local admin = require "spec.fixtures.admin_api"


local HEADER = "X-Proxy-Wasm"
local FILTER_SRC = "spec/fixtures/proxy_wasm_filters/build/response_transformer.wasm"

local json = cjson.encode
local file = helpers.file
local random_string = require("kong.tools.rand").random_string
local uuid = require("kong.tools.uuid").uuid


local function expect_status(id, exp)
  assert
    .eventually(function()
      local cp_client = helpers.admin_client()

      local res = cp_client:get("/clustering/data-planes/")
      res:read_body()

      cp_client:close()

      local body = assert.response(res).has.jsonbody()

      if res.status ~= 200 then
        return nil, {
          msg = "bad http status",
          exp = 200,
          got = res.status,
        }
      end

      assert.is_table(body.data)
      local found
      for _, dp in ipairs(body.data) do
        if dp.id == id then
          found = dp
          break
        end
      end

      if not found then
        return nil, {
          msg = "dp with id " .. id .. " not found in response",
          res = body,
        }

      elseif found.sync_status ~= exp then
        return nil, {
          msg = "unexpected sync_status",
          exp = exp,
          got = found.sync_status,
          dp  = found,
        }
      end

      return true
    end)
    .is_truthy("waiting for clustering sync status to equal "
           .. "'filter_set_incompatible' for data plane")
end

local function new_wasm_filter_directory()
  local dir = helpers.make_temp_dir()
  assert(file.copy(FILTER_SRC, dir .. "/response_transformer.wasm"))

  assert(file.copy(FILTER_SRC, dir .. "/response_transformer_with_schema.wasm"))
  return dir
end


-- XXX TODO: enable inc_sync = "on"
for _, inc_sync in ipairs { "off"  } do
describe("#wasm - hybrid mode #postgres" .. " inc_sync=" .. inc_sync, function()
  local cp_prefix = "cp"
  local cp_errlog = cp_prefix .. "/logs/error.log"
  local cp_filter_path

  local dp_prefix = "dp"
  local dp_errlog = dp_prefix .. "/logs/error.log"

  lazy_setup(function()
    helpers.clean_prefix(cp_prefix)
    helpers.clean_prefix(dp_prefix)

    local _, db = helpers.get_db_utils("postgres", {
      "services",
      "routes",
      "filter_chains",
      "clustering_data_planes",
    })

    db.clustering_data_planes:truncate()

    cp_filter_path = new_wasm_filter_directory()
    assert(file.write(cp_filter_path .. "/response_transformer_with_schema.meta.json", json {
      config_schema = {
        type = "object",
      },
    }))

    assert(helpers.start_kong({
      role                = "control_plane",
      database            = "postgres",
      prefix              = cp_prefix,
      cluster_cert        = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key    = "spec/fixtures/kong_clustering.key",
      db_update_frequency = 0.1,
      cluster_listen      = "127.0.0.1:9005",
      nginx_conf          = "spec/fixtures/custom_nginx.template",
      wasm                = true,
      wasm_filters        = "user", -- don't enable bundled filters for this test
      wasm_filters_path   = cp_filter_path,
      nginx_main_worker_processes = 2,
      cluster_incremental_sync = inc_sync,
    }))

    assert.logfile(cp_errlog).has.line([[successfully loaded "response_transformer" module]], true, 10)
    assert.logfile(cp_errlog).has.no.line("[error]", true, 0)
    assert.logfile(cp_errlog).has.no.line("[alert]", true, 0)
    assert.logfile(cp_errlog).has.no.line("[crit]",  true, 0)
    assert.logfile(cp_errlog).has.no.line("[emerg]", true, 0)
  end)

  lazy_teardown(function()
    helpers.stop_kong(cp_prefix)
    if cp_filter_path then
      helpers.dir.rmtree(cp_filter_path)
    end
  end)

  describe("[happy path]", function()
    local client
    local dp_filter_path
    local node_id

    lazy_setup(function()
      dp_filter_path = new_wasm_filter_directory()
      node_id = uuid()

      assert(helpers.start_kong({
        role                  = "data_plane",
        database              = "off",
        prefix                = dp_prefix,
        cluster_cert          = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key      = "spec/fixtures/kong_clustering.key",
        cluster_control_plane = "127.0.0.1:9005",
        admin_listen          = "off",
        nginx_conf            = "spec/fixtures/custom_nginx.template",
        wasm                  = true,
        wasm_filters          = "user", -- don't enable bundled filters for this test
        wasm_filters_path     = dp_filter_path,
        node_id               = node_id,
        nginx_main_worker_processes = 2,
        cluster_incremental_sync = inc_sync,
      }))

      assert.logfile(dp_errlog).has.line([[successfully loaded "response_transformer" module]], true, 10)
      assert.logfile(dp_errlog).has.no.line("[error]", true, 0)
      assert.logfile(dp_errlog).has.no.line("[alert]", true, 0)
      assert.logfile(dp_errlog).has.no.line("[crit]",  true, 0)
      assert.logfile(dp_errlog).has.no.line("[emerg]", true, 0)

      client = helpers.proxy_client()
    end)

    lazy_teardown(function()
      if client then client:close() end
      helpers.stop_kong(dp_prefix)
      if dp_filter_path then
        helpers.dir.rmtree(dp_filter_path)
      end
    end)

    it("syncs wasm filter chains to the data plane", function()
      local service = admin.services:insert({})
      local host = "wasm-" .. random_string() .. ".test"

      admin.routes:insert({
        service = service,
        hosts = { host },
      })

      local params = {
        headers = {
          host = host,
        }
      }

      assert
        .eventually(function()
          local res = client:get("/status/200", params)
          return res.status == 200, {
            exp = 200,
            got = res.status,
            res = res:read_body(),
          }
        end)
        .is_truthy("service/route are ready on the data plane")

      local value = random_string()

      local filter = admin.filter_chains:insert({
        service = { id = service.id },
        filters = {
          {
            name = "response_transformer",
            config = json {
              append = {
                headers = {
                  HEADER .. ":response_transformer",
                },
              },
            }
          },

          {
            name = "response_transformer_with_schema",
            config = {
              append = {
                headers = {
                  HEADER .. ":response_transformer_with_schema",
                },
              },
            }
          },

        }
      })

      assert
        .eventually(function()
          local res = client:get("/status/200", params)
          res:read_body()

          if res.status ~= 200 then
            return nil, {
              msg = "bad http status",
              exp = 200,
              got = res.status,
              res = res:read_body(),
            }
          end

          if res.headers[HEADER]
            and type(res.headers[HEADER]) == "table"
            and res.headers[HEADER][1] == "response_transformer"
            and res.headers[HEADER][2] == "response_transformer_with_schema"
          then
            return true
          end

          return nil, {
            msg = "missing/incorrect " .. HEADER .. " header",
            exp = value,
            got = res.headers[HEADER] or "<NIL>",
          }
        end)
        .is_truthy("wasm filter is configured on the data plane")

      admin.filter_chains:remove({ id = filter.id })

      assert
        .eventually(function()
          local res = client:get("/status/200", params)
          res:read_body()

          if res.status ~= 200 then
            return nil, {
              msg = "bad http status",
              exp = 200,
              got = res.status,
              res = res:read_body(),
            }
          end

          if res.headers[HEADER] ~= nil then
            return nil, {
              msg = "expected " .. HEADER .. " header to be absent",
              exp = "<NIL>",
              got = res.headers[HEADER],
            }
          end

          return true
        end)
        .is_truthy("wasm filter has been removed from the data plane")

      expect_status(node_id, STATUS.NORMAL)
    end)
  end)

  describe("data planes with wasm disabled", function()
    local node_id

    lazy_setup(function()
      helpers.clean_logfile(cp_errlog)
      node_id = uuid()

      assert(helpers.start_kong({
        role                  = "data_plane",
        database              = "off",
        prefix                = dp_prefix,
        cluster_cert          = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key      = "spec/fixtures/kong_clustering.key",
        cluster_control_plane = "127.0.0.1:9005",
        admin_listen          = "off",
        nginx_conf            = "spec/fixtures/custom_nginx.template",
        wasm                  = "off",
        node_id               = node_id,
        cluster_incremental_sync = inc_sync,
      }))
    end)


    lazy_teardown(function()
      helpers.stop_kong(dp_prefix)
    end)

    it("does not sync configuration", function()
      assert.logfile(cp_errlog).has.line(
        [[unable to send updated configuration to data plane: data plane is missing one or more wasm filters]],
        true, 5)

      expect_status(node_id, STATUS.FILTER_SET_INCOMPATIBLE)
    end)
  end)

  describe("data planes missing one or more wasm filter", function()
    local tmp_dir
    local node_id

    lazy_setup(function()
      helpers.clean_logfile(cp_errlog)
      tmp_dir = helpers.make_temp_dir()
      node_id = uuid()

      assert(helpers.start_kong({
        role                  = "data_plane",
        database              = "off",
        prefix                = dp_prefix,
        cluster_cert          = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key      = "spec/fixtures/kong_clustering.key",
        cluster_control_plane = "127.0.0.1:9005",
        admin_listen          = "off",
        nginx_conf            = "spec/fixtures/custom_nginx.template",
        wasm                  = true,
        wasm_filters          = "user", -- don't enable bundled filters for this test
        wasm_filters_path     = tmp_dir,
        node_id               = node_id,
        cluster_incremental_sync = inc_sync,
      }))
    end)


    lazy_teardown(function()
      helpers.stop_kong(dp_prefix)
      helpers.dir.rmtree(tmp_dir)
    end)

    it("does not sync configuration", function()
      assert.logfile(cp_errlog).has.line(
        [[unable to send updated configuration to data plane: data plane is missing one or more wasm filters]],
        true, 5)

      expect_status(node_id, STATUS.FILTER_SET_INCOMPATIBLE)
    end)
  end)
end)
end -- for inc_sync
