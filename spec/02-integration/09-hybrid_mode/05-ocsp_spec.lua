local helpers = require "spec.helpers"
local cjson = require "cjson.safe"
local pl_file = require "pl.file"


local TEST_CONF = helpers.test_conf


local function set_ocsp_status(status)
  local upstream_client = helpers.http_client(helpers.mock_upstream_host, helpers.mock_upstream_port, 5000)
  local res = assert(upstream_client:get("/set_ocsp?status=" .. status))
  assert.res_status(200, res)
  upstream_client:close()
end


for _, v in ipairs({ {"off", "off"}, {"on", "off"}, {"on", "on"}, }) do
  local rpc, rpc_sync = v[1], v[2]

for _, strategy in helpers.each_strategy() do

describe("cluster_ocsp = on works #" .. strategy .. " rpc_sync=" .. rpc_sync, function()
  describe("DP certificate good", function()
    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "clustering_data_planes",
        "upstreams",
        "targets",
        "certificates",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_clustering.key",
        cluster_ocsp = "on",
        db_update_frequency = 0.1,
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      set_ocsp_status("good")

      assert(helpers.start_kong({
        role = "data_plane",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_data_plane.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_data_plane.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_server_name = "kong_clustering",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
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
              return true
            end
          end
        end, 5)
      end)
    end)
  end)

  describe("DP certificate revoked", function()
    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "clustering_data_planes",
        "upstreams",
        "targets",
        "certificates",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_clustering.key",
        cluster_ocsp = "on",
        db_update_frequency = 0.1,
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      set_ocsp_status("revoked")

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_data_plane.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_data_plane.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_server_name = "kong_clustering",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)

    it("revoked DP certificate can not connect to CP", function()
      helpers.wait_until(function()
        local logs = pl_file.read(TEST_CONF.prefix .. "/" .. TEST_CONF.proxy_error_log)
        if logs:find([[client certificate was revoked: failed to validate OCSP response: certificate status "revoked" in the OCSP response]], 1, true) then
          local admin_client = helpers.admin_client()
          finally(function()
            admin_client:close()
          end)

          local res = assert(admin_client:get("/clustering/data-planes"))
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.equal(0, #json.data)
          return true
        end
      end, 10)
    end)
  end)

  describe("OCSP responder errors, DP are not allowed", function()
    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "clustering_data_planes",
        "upstreams",
        "targets",
        "certificates",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_clustering.key",
        cluster_ocsp = "on",
        db_update_frequency = 0.1,
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      set_ocsp_status("error")

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_data_plane.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_data_plane.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_server_name = "kong_clustering",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)
    describe("status API", function()
      it("does not show DP status", function()
        helpers.wait_until(function()
          local logs = pl_file.read(TEST_CONF.prefix .. "/" .. TEST_CONF.proxy_error_log)
          if logs:find('data plane client certificate revocation check failed: OCSP responder returns bad HTTP status code: 500', nil, true) then
            local admin_client = helpers.admin_client()
            finally(function()
              admin_client:close()
            end)

            local res = assert(admin_client:get("/clustering/data-planes"))
            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(0, #json.data)
            return true
          end
        end, 5)
      end)
    end)
  end)
end)

describe("cluster_ocsp = off works with #" .. strategy .. " rpc_sync=" .. rpc_sync .. " backend", function()
  describe("DP certificate revoked, not checking for OCSP", function()
    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "clustering_data_planes",
        "upstreams",
        "targets",
        "certificates",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_clustering.key",
        cluster_ocsp = "off",
        db_update_frequency = 0.1,
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      set_ocsp_status("revoked")

      assert(helpers.start_kong({
        role = "data_plane",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_data_plane.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_data_plane.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_server_name = "kong_clustering",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
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
              return true
            end
          end
        end, 5)
      end)
    end)
  end)
end)

describe("cluster_ocsp = optional works with #" .. strategy .. " rpc_sync=" .. rpc_sync .. " backend", function()
  describe("DP certificate revoked", function()
    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "clustering_data_planes",
        "upstreams",
        "targets",
        "certificates",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_clustering.key",
        cluster_ocsp = "optional",
        db_update_frequency = 0.1,
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      set_ocsp_status("revoked")

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_data_plane.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_data_plane.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_server_name = "kong_clustering",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)

    it("revoked DP certificate can not connect to CP", function()
      helpers.wait_until(function()
        local logs = pl_file.read(TEST_CONF.prefix .. "/" .. TEST_CONF.proxy_error_log)
        if logs:find('client certificate was revoked: failed to validate OCSP response: certificate status "revoked" in the OCSP response', nil, true) then
          local admin_client = helpers.admin_client()
          finally(function()
            admin_client:close()
          end)

          local res = assert(admin_client:get("/clustering/data-planes"))
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.equal(0, #json.data)
          return true
        end
      end, 5)
    end)
  end)

  describe("OCSP responder errors, DP are allowed through", function()
    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "clustering_data_planes",
        "upstreams",
        "targets",
        "certificates",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_clustering.key",
        cluster_ocsp = "optional",
        db_update_frequency = 0.1,
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        cluster_rpc = rpc,
        cluster_rpc_sync = rpc_sync,
      }))

      set_ocsp_status("error")

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = "servroot2",
        cluster_cert = "spec/fixtures/ocsp_certs/kong_data_plane.crt",
        cluster_cert_key = "spec/fixtures/ocsp_certs/kong_data_plane.key",
        cluster_control_plane = "127.0.0.1:9005",
        proxy_listen = "0.0.0.0:9002",
        -- additional attributes for PKI:
        cluster_mtls = "pki",
        cluster_server_name = "kong_clustering",
        cluster_ca_cert = "spec/fixtures/ocsp_certs/ca.crt",
        nginx_conf = "spec/fixtures/custom_nginx.template",
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
              local logs = pl_file.read(TEST_CONF.prefix .. "/" .. TEST_CONF.proxy_error_log)
              if logs:find('data plane client certificate revocation check failed: OCSP responder returns bad HTTP status code: 500', nil, true) then
                return true
              end
            end
          end

        end, 5)
      end)
    end)
  end)
end)

end -- for _, strategy
end -- for rpc_sync
