local helpers = require("spec.helpers")
local join = require("pl.stringx").join

local ENABLED_PLUGINS = { "dummy" , "reconfiguration-completion"}

for _, strategy in helpers.each_strategy({"postgres"}) do
  describe("deprecations are not reported on DP but on CP", function()
    local cp_prefix = "servroot1"
    local dp_prefix = "servroot2"
    local cp_logfile, dp_logfile, route

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
      }, ENABLED_PLUGINS)

      local service = bp.services:insert {
        name = "example",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      }

      route = assert(bp.routes:insert {
        hosts     = { "mock_upstream" },
        protocols = { "http" },
        service   = service,
      })

      assert(helpers.start_kong({
        role = "control_plane",
        database = strategy,
        prefix = cp_prefix,
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        cluster_listen = "127.0.0.1:9005",
        cluster_telemetry_listen = "127.0.0.1:9006",
        plugins = "bundled," .. join(",", ENABLED_PLUGINS),
        nginx_conf = "spec/fixtures/custom_nginx.template",
        admin_listen = "0.0.0.0:9001",
        proxy_listen = "off",
      }))

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = dp_prefix,
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        cluster_control_plane = "127.0.0.1:9005",
        cluster_telemetry_endpoint = "127.0.0.1:9006",
        plugins = "bundled," .. join(",", ENABLED_PLUGINS),
        admin_listen = "off",
        proxy_listen = "0.0.0.0:9002",
      }))
      dp_logfile = helpers.get_running_conf(dp_prefix).nginx_err_logs
      cp_logfile = helpers.get_running_conf(cp_prefix).nginx_err_logs
    end)

    lazy_teardown(function()
      helpers.stop_kong(dp_prefix)
      helpers.stop_kong(cp_prefix)
    end)

    describe("deprecations are not reported on DP but on CP", function()
      before_each(function()
        helpers.clean_logfile(dp_logfile)
      end)

      it("deprecation warnings are only fired on CP not DP", function()
        local proxy_client, admin_client = helpers.make_synchronized_clients({
          proxy_client = helpers.proxy_client(nil, 9002),
          admin_client = helpers.admin_client(nil, 9001)
        })
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name = "dummy",
            route = { id = route.id },
            config = {
              old_field = 10,
              append_body = "appended from body filtering"
            },
          },
          headers = {
            ["Content-Type"] = "application/json",
          }
        })
        assert.res_status(201, res)

        local res = assert(proxy_client:send {
          method = "GET",
          path = "/status/200",
          headers = {
            ["Host"] = "mock_upstream",
          }
        })
        local body = assert.res_status(200, res)

        -- TEST: ensure that the dummy plugin was executed by checking
        -- that the body filtering phase has run

        assert.matches("appended from body filtering", body, nil, true)

        assert.logfile(cp_logfile).has.line("dummy: old_field is deprecated", true)
        assert.logfile(dp_logfile).has.no.line("dummy: old_field is deprecated", true)
      end)
    end)
  end)
end
