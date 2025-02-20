local helpers = require "spec.helpers"
local cjson = require "cjson.safe"
local _VERSION_TABLE = require "kong.meta" ._VERSION_TABLE
local MAJOR = _VERSION_TABLE.major
local MINOR = _VERSION_TABLE.minor
local PATCH = _VERSION_TABLE.patch
local CLUSTERING_SYNC_STATUS = require("kong.constants").CLUSTERING_SYNC_STATUS
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy
local uuid = require("kong.tools.uuid").uuid


local KEY_AUTH_PLUGIN


for _, v in ipairs({ {"off", "off"}, {"on", "off"}, {"on", "on"}, }) do
  local rpc, rpc_sync = v[1], v[2]

for _, strategy in helpers.each_strategy() do

describe("CP/DP communication #" .. strategy .. " rpc_sync=" .. rpc_sync, function()

  lazy_setup(function()
    helpers.get_db_utils(strategy) -- runs migrations

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      database = strategy,
      db_update_frequency = 0.1,
      cluster_listen = "127.0.0.1:9005",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      cluster_rpc = rpc,
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
      nginx_conf = "spec/fixtures/custom_nginx.template",
      cluster_rpc = rpc,
      cluster_rpc_sync = rpc_sync,
      worker_state_update_frequency = 1,
    }))

    if rpc_sync == "on" then
      assert.logfile("servroot2/logs/error.log").has.line("[kong.sync.v2] full sync ends", true, 10)
    end

    for _, plugin in ipairs(helpers.get_plugins_list()) do
      if plugin.name == "key-auth" then
        KEY_AUTH_PLUGIN = plugin
        break
      end
    end
  end)

  lazy_teardown(function()
    helpers.stop_kong("servroot2")
    helpers.stop_kong()
  end)

  describe("status API", function()
    it("shows DP status", function()
      helpers.wait_until(function()
        local admin_client = helpers.admin_client()
        finally(function()
          admin_client:close()
        end)

        local res = assert(admin_client:get("/clustering/data-planes"))
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        for _, v in pairs(json.data) do
          if v.ip == "127.0.0.1" then
            assert.near(14 * 86400, v.ttl, 3)
            assert.matches("^(%d+%.%d+)%.%d+", v.version)
            assert.equal(CLUSTERING_SYNC_STATUS.NORMAL, v.sync_status)
            return true
          end
        end
      end, 10)
    end)

    it("shows DP status (#deprecated)", function()
      helpers.wait_until(function()
        local admin_client = helpers.admin_client()
        finally(function()
          admin_client:close()
        end)

        local res = assert(admin_client:get("/clustering/status"))
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        for _, v in pairs(json) do
          if v.ip == "127.0.0.1" then
            return true
          end
        end
      end, 5)
    end)

    it("disallow updates on the status endpoint", function()
      helpers.wait_until(function()
        local admin_client = helpers.admin_client()
        finally(function()
          admin_client:close()
        end)

        local res = assert(admin_client:get("/clustering/data-planes"))
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        local id
        for _, v in pairs(json.data) do
          if v.ip == "127.0.0.1" then
            id = v.id
          end
        end

        if not id then
          return nil
        end

        res = assert(admin_client:delete("/clustering/data-planes/" .. id))
        assert.res_status(404, res)
        res = assert(admin_client:patch("/clustering/data-planes/" .. id))
        assert.res_status(404, res)

        return true
      end, 5)
    end)

    it("disables the auto-generated collection endpoints", function()
      local admin_client = helpers.admin_client(10000)
      finally(function()
        admin_client:close()
      end)

      local res = assert(admin_client:get("/clustering_data_planes"))
      assert.res_status(404, res)
    end)
  end)

  describe("sync works", function()
    local route_id

    it("proxy on DP follows CP config", function()
      local admin_client = helpers.admin_client(10000)
      finally(function()
        admin_client:close()
      end)

      local res = assert(admin_client:post("/services", {
        body = { name = "mockbin-service", url = "https://127.0.0.1:15556/request", },
        headers = {["Content-Type"] = "application/json"}
      }))
      assert.res_status(201, res)

      res = assert(admin_client:post("/services/mockbin-service/routes", {
        body = { paths = { "/" }, },
        headers = {["Content-Type"] = "application/json"}
      }))
      local body = assert.res_status(201, res)
      local json = cjson.decode(body)

      route_id = json.id
      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)

        res = proxy_client:send({
          method  = "GET",
          path    = "/",
        })

        local status = res and res.status
        proxy_client:close()
        if status == 200 then
          return true
        end
      end, 10)
    end)

    it("cache invalidation works on config change", function()
      local admin_client = helpers.admin_client()
      finally(function()
        admin_client:close()
      end)

      local res = assert(admin_client:send({
        method = "DELETE",
        path   = "/routes/" .. route_id,
      }))
      assert.res_status(204, res)

      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)

        res = proxy_client:send({
          method  = "GET",
          path    = "/",
        })

        -- should remove the route from DP
        local status = res and res.status
        proxy_client:close()
        if status == 404 then
          return true
        end
      end, 5)
    end)

    it('does not sync services where enabled == false', function()
      local admin_client = helpers.admin_client(10000)
      finally(function()
        admin_client:close()
      end)

      -- create service
      local res = assert(admin_client:post("/services", {
        body = { name = "mockbin-service2", url = "https://127.0.0.1:15556/request", },
        headers = {["Content-Type"] = "application/json"}
      }))
      local body = assert.res_status(201, res)
      local json = cjson.decode(body)
      local service_id = json.id

      -- -- create route
      res = assert(admin_client:post("/services/mockbin-service2/routes", {
        body = { paths = { "/soon-to-be-disabled" }, },
        headers = {["Content-Type"] = "application/json"}
      }))
      local body = assert.res_status(201, res)
      local json = cjson.decode(body)

      route_id = json.id

      -- test route
      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)

        res = proxy_client:send({
          method  = "GET",
          path    = "/soon-to-be-disabled",
        })

        local status = res and res.status
        proxy_client:close()
        if status == 200 then
          return true
        end
      end, 10)

      -- disable service
      local res = assert(admin_client:patch("/services/" .. service_id, {
        body = { enabled = false, },
        headers = {["Content-Type"] = "application/json"}
      }))
      assert.res_status(200, res)

      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)

        -- test route again
        res = assert(proxy_client:send({
          method  = "GET",
          path    = "/soon-to-be-disabled",
        }))

        local status = res and res.status
        proxy_client:close()
        if status == 404 then
          return true
        end
      end)
    end)

    it('does not sync plugins on a route attached to a disabled service', function()
      local admin_client = helpers.admin_client(10000)
      finally(function()
        admin_client:close()
      end)

      -- create service
      local res = assert(admin_client:post("/services", {
        body = { name = "mockbin-service3", url = "https://127.0.0.1:15556/request", },
        headers = {["Content-Type"] = "application/json"}
      }))
      local body = assert.res_status(201, res)
      local json = cjson.decode(body)
      local service_id = json.id

      -- create route
      res = assert(admin_client:post("/services/mockbin-service3/routes", {
        body = { paths = { "/soon-to-be-disabled-3" }, },
        headers = {["Content-Type"] = "application/json"}
      }))
      local body = assert.res_status(201, res)
      local json = cjson.decode(body)

      local route_id = json.id

      -- add a plugin for route
      res = assert(admin_client:post("/routes/" .. route_id .. "/plugins", {
        body = { name = "bot-detection" },
        headers = {["Content-Type"] = "application/json"}
      }))
      assert.res_status(201, res)

      -- test route
      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)

        res = proxy_client:send({
          method  = "GET",
          path    = "/soon-to-be-disabled-3",
        })

        local status = res and res.status
        proxy_client:close()
        return status == 200
      end, 10)

      -- disable service
      local res = assert(admin_client:patch("/services/" .. service_id, {
        body = { enabled = false, },
        headers = {["Content-Type"] = "application/json"}
      }))
      assert.res_status(200, res)

      -- test route again
      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)

        res = assert(proxy_client:send({
          method  = "GET",
          path    = "/soon-to-be-disabled-3",
        }))

        local status = res and res.status
        proxy_client:close()
        return status == 404
      end, 10)
    end)
  end)
end)

describe("CP/DP #version check #" .. strategy .. " rpc_sync=" .. rpc_sync, function()
  -- for these tests, we do not need a real DP, but rather use the fake DP
  -- client so we can mock various values (e.g. node_version)
  describe("relaxed compatibility check:", function()
    local bp = helpers.get_db_utils(strategy) -- runs migrations

    bp.plugins:insert {
      name = "key-auth",
    }
    lazy_setup(function()
      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        database = strategy,
        db_update_frequency = 3,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        cluster_version_check = "major_minor",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      for _, plugin in ipairs(helpers.get_plugins_list()) do
        if plugin.name == "key-auth" then
          KEY_AUTH_PLUGIN = plugin
          break
        end
      end
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    local plugins_map = {}
    -- generate a map of current plugins
    local plugin_list = cycle_aware_deep_copy(helpers.get_plugins_list())
    for _, plugin in pairs(plugin_list) do
      plugins_map[plugin.name] = plugin.version
    end

    -- STARTS allowed cases
    local allowed_cases = {
      ["CP and DP version and plugins matches"] = {},
      ["CP configured plugins list matches DP enabled plugins list"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        plugins_list = {
          {  name = "key-auth", version = plugins_map["key-auth"] }
        }
      },
      ["CP configured plugins list matches DP enabled plugins version"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        plugins_list = {
          {  name = "key-auth", version = plugins_map["key-auth"] }
        }
      },
      ["CP configured plugins list matches DP enabled plugins major version (older dp plugin)"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        plugins_list = {
          {  name = "key-auth", version = tonumber(plugins_map["key-auth"]:match("(%d+)")) .. ".0.0" }
        }
      },
      ["CP has configured plugin with older patch version than in DP enabled plugins"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        plugins_list = {
          {  name = "key-auth", version = plugins_map["key-auth"]:match("(%d+.%d+)") .. ".1000" }
        }
      },
      ["CP and DP minor version mismatches (older dp)"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, 0, PATCH),
      },
      ["CP and DP patch version mismatches (older dp)"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, 0),
      },
      ["CP and DP patch version mismatches (newer dp)"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, 1000),
      },
      ["CP and DP suffix mismatches"] = {
        dp_version = tostring(_VERSION_TABLE) .. "-enterprise-version",
      },
      ["DP sends labels"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        labels = { some_key = "some_value", b = "aA090).zZ", ["a-._123z"] = "Zz1.-_aA" }
      },
      ["DP sends process conf"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        process_conf = { foo = "bar" },
      },
    }

    local pl1 = cycle_aware_deep_copy(helpers.get_plugins_list())
    table.insert(pl1, 2, { name = "banana", version = "1.1.1" })
    table.insert(pl1, { name = "pineapple", version = "1.1.2" })
    allowed_cases["DP plugin set is a superset of CP"] = {
      plugins_list = pl1
    }


    allowed_cases["DP plugin set is a subset of CP"] = {
      plugins_list = { KEY_AUTH_PLUGIN }
    }

    local pl2 = cycle_aware_deep_copy(helpers.get_plugins_list())
    for i, _ in ipairs(pl2) do
      local v = pl2[i].version
      local minor = v and v:match("%d+%.(%d+)%.%d+")
      -- find a plugin that has minor version mismatch
      -- we hardcode `dummy` plugin to be 9.9.9 so there must be at least one
      if minor and tonumber(minor) and tonumber(minor) > 2 then
        pl2[i].version = string.format("%d.%d.%d",
                                      tonumber(v:match("(%d+)")),
                                      tonumber(minor - 2),
                                      tonumber(v:match("%d+%.%d+%.(%d+)"))

        )
        break
      end
    end
    allowed_cases["CP and DP plugin version matches to major"] = {
      plugins_list = pl2
    }

    local pl3 = cycle_aware_deep_copy(helpers.get_plugins_list())
    for i, _ in ipairs(pl3) do
      local v = pl3[i].version
      local patch = v and v:match("%d+%.%d+%.(%d+)")
      -- find a plugin that has patch version mismatch
      -- we hardcode `dummy` plugin to be 9.9.9 so there must be at least one
      if patch and tonumber(patch) and tonumber(patch) > 2 then
        pl3[i].version = string.format("%d.%d.%d",
                                      tonumber(v:match("(%d+)")),
                                      tonumber(v:match("%d+%.(%d+)")),
                                      tonumber(patch - 2)
        )
        break
      end
    end
    allowed_cases["CP and DP plugin version matches to major.minor"] = {
      plugins_list = pl3
    }

    for desc, harness in pairs(allowed_cases) do
      it(desc .. ", sync is allowed", function()
        local uuid = uuid()

        local res = assert(helpers.clustering_client({
          host = "127.0.0.1",
          port = 9005,
          cert = "spec/fixtures/kong_clustering.crt",
          cert_key = "spec/fixtures/kong_clustering.key",
          node_id = uuid,
          node_version = harness.dp_version,
          node_plugins_list = harness.plugins_list,
          node_labels = harness.labels,
          node_process_conf = harness.process_conf,
        }))

        assert.equals("reconfigure", res.type)
        assert.is_table(res.config_table)

        -- needs wait_until for C* convergence
        helpers.wait_until(function()
          local admin_client = helpers.admin_client()

          res = assert(admin_client:get("/clustering/data-planes"))
          local body = assert.res_status(200, res)

          admin_client:close()
          local json = cjson.decode(body)

          for _, v in pairs(json.data) do
            if v.id == uuid then
              local dp_version = harness.dp_version or tostring(_VERSION_TABLE)
              if dp_version == v.version and CLUSTERING_SYNC_STATUS.NORMAL == v.sync_status then
                return true
              end
            end
          end
        end, 500)
      end)
    end
    -- ENDS allowed cases

    -- STARTS blocked cases
    local blocked_cases = {
      ["CP configured plugin list mismatches DP enabled plugins list"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        expected = CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE,
        plugins_list = {
          {  name="banana-plugin", version="1.0.0" }
        }
      },
      ["CP has configured plugin with older major version than in DP enabled plugins"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        expected = CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE,
        plugins_list = {
          {  name="key-auth", version="1.0.0" }
        }
      },
      ["CP has configured plugin with newer minor version than in DP enabled plugins newer"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        expected = CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE,
        plugins_list = {
          {  name = "key-auth", version = "1000.0.0" }
        }
      },
      ["CP has configured plugin with older minor version than in DP enabled plugins"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, MINOR, PATCH),
        expected = CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE,
        plugins_list = {
          {  name = "key-auth", version = tonumber(plugins_map["key-auth"]:match("(%d+)")) .. ".1000.0" }
        }
      },
      ["CP and DP major version mismatches"] = {
        dp_version = "1.0.0",
        expected = CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE,
        -- KONG_VERSION_INCOMPATIBLE is send during first handshake, CP closes
        -- connection immediately if kong version mismatches.
        -- ignore_error is needed to ignore the `closed` error
        ignore_error = true,
      },
      ["CP and DP minor version mismatches (newer dp)"] = {
        dp_version = string.format("%d.%d.%d", MAJOR, 1000, PATCH),
        expected = CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE,
        ignore_error = true,
      },
    }

    for desc, harness in pairs(blocked_cases) do
      it(desc ..", sync is blocked", function()
        local uuid = uuid()

        local res, err = helpers.clustering_client({
          host = "127.0.0.1",
          port = 9005,
          cert = "spec/fixtures/kong_clustering.crt",
          cert_key = "spec/fixtures/kong_clustering.key",
          node_id = uuid,
          node_version = harness.dp_version,
          node_plugins_list = harness.plugins_list,
        })

        if not res then
          if not harness.ignore_error then
            error(err)
          end

        else
          assert.equals("PONG", res)
        end

        -- needs wait_until for c* convergence
        helpers.wait_until(function()
          local admin_client = helpers.admin_client()

          res = assert(admin_client:get("/clustering/data-planes"))
          local body = assert.res_status(200, res)

          admin_client:close()
          local json = cjson.decode(body)

          for _, v in pairs(json.data) do
            if v.id == uuid then
              local dp_version = harness.dp_version or tostring(_VERSION_TABLE)
              if dp_version == v.version and harness.expected == v.sync_status then
                return true
              end
            end
          end
        end, 5)
      end)
    end
    -- ENDS blocked cases
  end)
end)

describe("CP/DP config sync #" .. strategy .. " rpc_sync=" .. rpc_sync, function()
  lazy_setup(function()
    helpers.get_db_utils(strategy) -- runs migrations

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      database = strategy,
      db_update_frequency = 3,
      cluster_listen = "127.0.0.1:9005",
      cluster_rpc = rpc,
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
      cluster_rpc_sync = rpc_sync,
      cluster_rpc = rpc,
      worker_state_update_frequency = 1,
    }))

    if rpc_sync == "on" then
      assert.logfile("servroot2/logs/error.log").has.line("[kong.sync.v2] full sync ends", true, 10)
    end
  end)

  lazy_teardown(function()
    helpers.stop_kong("servroot2")
    helpers.stop_kong()
  end)

  describe("sync works", function()
    it("pushes first change asap and following changes in a batch", function()
      local admin_client = helpers.admin_client(10000)
      local proxy_client = helpers.http_client("127.0.0.1", 9002)
      finally(function()
        admin_client:close()
        proxy_client:close()
      end)

      local res = admin_client:put("/routes/1", {
        headers = {
          ["Content-Type"] = "application/json",
        },
        body = {
          paths = { "/1" },
        },
      })

      assert.res_status(200, res)

      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)
        -- serviceless route should return 503 instead of 404
        res = proxy_client:get("/1")
        proxy_client:close()
        if res and res.status == 503 then
          return true
        end
      end, 10)

      for i = 2, 5 do
        res = admin_client:put("/routes/" .. i, {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = {
            paths = { "/" .. i },
          },
        })

        assert.res_status(200, res)
      end

      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)
        -- serviceless route should return 503 instead of 404
        res = proxy_client:get("/5")
        proxy_client:close()
        if res and res.status == 503 then
          return true
        end
      end, 5)

      for i = 4, 2, -1 do
        res = proxy_client:get("/" .. i)
        assert.res_status(503, res)
      end

      for i = 1, 5 do
        local res = admin_client:delete("/routes/" .. i)
        assert.res_status(204, res)
      end

      helpers.wait_until(function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)
        -- deleted route should return 404
        res = proxy_client:get("/1")
        proxy_client:close()
        if res and res.status == 404 then
          return true
        end
      end, 5)

      -- TODO: it may cause flakiness
      -- wait for rpc sync finishing
      if rpc_sync == "on" then
        ngx.sleep(0.5)
      end

      for i = 5, 2, -1 do
        res = proxy_client:get("/" .. i)
        assert.res_status(404, res)
      end
    end)
  end)
end)

describe("CP/DP labels #" .. strategy, function()

  lazy_setup(function()
    helpers.get_db_utils(strategy) -- runs migrations

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      database = strategy,
      db_update_frequency = 0.1,
      cluster_listen = "127.0.0.1:9005",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      cluster_rpc = rpc,
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
      nginx_conf = "spec/fixtures/custom_nginx.template",
      cluster_dp_labels="deployment:mycloud,region:us-east-1",
      cluster_rpc = rpc,
      cluster_rpc_sync = rpc_sync,
    }))

    if rpc_sync == "on" then
      assert.logfile("servroot2/logs/error.log").has.line("[kong.sync.v2] full sync ends", true, 10)
    end
  end)

  lazy_teardown(function()
    helpers.stop_kong("servroot2")
    helpers.stop_kong()
  end)

  describe("status API", function()
    it("shows DP status", function()
      local admin_client = helpers.admin_client()
      finally(function()
        admin_client:close()
      end)

      helpers.wait_until(function()
        local res = assert(admin_client:get("/clustering/data-planes"))
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        for _, v in pairs(json.data) do
          if v.ip == "127.0.0.1" then
            assert.near(14 * 86400, v.ttl, 3)
            assert.matches("^(%d+%.%d+)%.%d+", v.version)
            assert.equal(CLUSTERING_SYNC_STATUS.NORMAL, v.sync_status)
            assert.equal(CLUSTERING_SYNC_STATUS.NORMAL, v.sync_status)
            assert.equal("mycloud", v.labels.deployment)
            assert.equal("us-east-1", v.labels.region)
            return true
          end
        end
      end, 10)
    end)
  end)
end)

describe("CP/DP cert details(cluster_mtls = shared) #" .. strategy, function()
  lazy_setup(function()
    helpers.get_db_utils(strategy) -- runs migrations

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      database = strategy,
      db_update_frequency = 0.1,
      cluster_listen = "127.0.0.1:9005",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      cluster_rpc = rpc,
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
      nginx_conf = "spec/fixtures/custom_nginx.template",
      cluster_dp_labels="deployment:mycloud,region:us-east-1",
      cluster_rpc = rpc,
      cluster_rpc_sync = rpc_sync,
    }))
    if rpc_sync == "on" then
      assert.logfile("servroot2/logs/error.log").has.line("[kong.sync.v2] full sync ends", true, 10)
    end
  end)

  lazy_teardown(function()
    helpers.stop_kong("servroot2")
    helpers.stop_kong()
  end)

  describe("status API", function()
    it("shows DP cert details", function()
      helpers.wait_until(function()
        local admin_client = helpers.admin_client()
        finally(function()
          admin_client:close()
        end)

        local res = assert(admin_client:get("/clustering/data-planes"))
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        for _, v in pairs(json.data) do
          if v.ip == "127.0.0.1" then
            assert.equal(1888983905, v.cert_details.expiry_timestamp)
            return true
          end
        end
      end, 3)
    end)
  end)
end)

describe("CP/DP cert details(cluster_mtls = pki) #" .. strategy, function()
  lazy_setup(function()
    helpers.get_db_utils(strategy) -- runs migrations

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      db_update_frequency = 0.1,
      database = strategy,
      cluster_listen = "127.0.0.1:9005",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      -- additional attributes for PKI:
      cluster_mtls = "pki",
      cluster_ca_cert = "spec/fixtures/kong_clustering_ca.crt",
      cluster_rpc = rpc,
      cluster_rpc_sync = rpc_sync,
    }))

    assert(helpers.start_kong({
      role = "data_plane",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      database = "off",
      prefix = "servroot2",
      cluster_cert = "spec/fixtures/kong_clustering_client.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering_client.key",
      cluster_control_plane = "127.0.0.1:9005",
      proxy_listen = "0.0.0.0:9002",
      -- additional attributes for PKI:
      cluster_mtls = "pki",
      cluster_server_name = "kong_clustering",
      cluster_ca_cert = "spec/fixtures/kong_clustering.crt",
      cluster_rpc = rpc,
      cluster_rpc_sync = rpc_sync,
    }))

    if rpc_sync == "on" then
      assert.logfile("servroot2/logs/error.log").has.line("[kong.sync.v2] full sync ends", true, 10)
    end
  end)

  lazy_teardown(function()
    helpers.stop_kong("servroot2")
    helpers.stop_kong()
  end)

  describe("status API", function()
    it("shows DP cert details", function()
      helpers.wait_until(function()
        local admin_client = helpers.admin_client()
        finally(function()
          admin_client:close()
        end)

        local res = admin_client:get("/clustering/data-planes")
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)

        for _, v in pairs(json.data) do
          if v.ip == "127.0.0.1" then
            assert.equal(1897136778, v.cert_details.expiry_timestamp)
            return true
          end
        end
      end, 3)
    end)
  end)
end)

end -- for _, strategy
end -- for rpc_sync
