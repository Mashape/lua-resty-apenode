local helpers = require "spec.helpers"


-- register a test rpc service in custom plugin rpc-notification-test
for _, strategy in helpers.each_strategy() do
  describe("Hybrid Mode RPC #" .. strategy, function()

    lazy_setup(function()
      helpers.get_db_utils(strategy, {
        "clustering_data_planes",
      }) -- runs migrations

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled,rpc-notification-test",
        nginx_worker_processes = 4, -- multiple workers
        cluster_rpc = "on", -- enable rpc
        cluster_rpc_sync = "off", -- disable rpc sync
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
        plugins = "bundled,rpc-notification-test",
        nginx_worker_processes = 4, -- multiple workers
        cluster_rpc = "on", -- enable rpc
        cluster_rpc_sync = "off", -- disable rpc sync
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)

    describe("notification works", function()
      it("in custom plugin", function()
        local name = nil

        -- cp logs
        helpers.pwait_until(function()
          assert.logfile(name).has.line(
            "notification is hello", true)
          assert.logfile(name).has.line(
            "[rpc] notifying kong.test.notification(node_id:", true)
          assert.logfile(name).has.line(
            "[rpc] notification has no response", true)
          assert.logfile(name).has.no.line(
            "assert failed", true)
          return true
        end, 10)

        local name = "servroot2/logs/error.log"

        -- dp logs
        helpers.pwait_until(function()
          assert.logfile(name).has.line(
            "[rpc] notifying kong.test.notification(node_id: control_plane) via local", true)
          assert.logfile(name).has.line(
            "notification is world", true)
          assert.logfile(name).has.line(
            "[rpc] notification has no response", true)
          assert.logfile(name).has.no.line(
            "assert failed", true)
          return true
        end, 10)

      end)
    end)
  end)
end -- for _, strategy
