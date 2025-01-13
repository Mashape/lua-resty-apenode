local helpers = require "spec.helpers"

-- register a test rpc service in custom plugin rpc-batch-test
for _, strategy in helpers.each_strategy() do
  describe("Hybrid Mode RPC #" .. strategy, function()

    lazy_setup(function()
      helpers.get_db_utils(strategy, { "routes", "services" })

      assert(helpers.start_kong({
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        database = strategy,
        cluster_listen = "127.0.0.1:9005",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        cluster_rpc = "on",
        plugins = "bundled,rpc-batch-test", -- enable custom plugin
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
        cluster_rpc = "on",
        plugins = "bundled,rpc-batch-test", -- enable custom plugin
        cluster_rpc_sync = "off", -- disable rpc sync
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)

    describe("batch works", function()
      it("DP calls CP via batching", function()
        local cp_logfile = nil
        local dp_logfile = "servroot2/logs/error.log"

        helpers.pwait_until(function()
          assert.logfile(dp_logfile).has.line(
            "[rpc] sent batch RPC call: 1", true)

          assert.logfile(cp_logfile).has.line(
            "[rpc] got batch RPC call: 1", true)
          assert.logfile(cp_logfile).has.line(
            "kong.test.batch called: world", true)

          assert.logfile(dp_logfile).has.line(
            "[rpc] got batch RPC call: 1", true)
          assert.logfile(dp_logfile).has.line(
            "kong.test.batch called: hello world", true)

          assert.logfile(dp_logfile).has.line(
            "[rpc] sent batch RPC call: 2", true)

          assert.logfile(cp_logfile).has.line(
            "[rpc] got batch RPC call: 2", true)
          assert.logfile(cp_logfile).has.line(
            "kong.test.batch called: kong", true)
          assert.logfile(cp_logfile).has.line(
            "kong.test.batch called: gateway", true)
          assert.logfile(cp_logfile).has.line(
            "[rpc] notification has no response", true)

          return true
        end, 15)
      end)
    end)
  end)
end -- for _, strategy
