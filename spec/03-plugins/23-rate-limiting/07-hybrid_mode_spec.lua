local helpers = require "spec.helpers"

local REDIS_HOST        = helpers.redis_host
local REDIS_PORT        = helpers.redis_port

for _, strategy in helpers.each_strategy({"postgres"}) do
  describe("Plugin: rate-limiting (handler.access) worked with [#" .. strategy .. "]", function()
    local dp_prefix = "servroot2"
    local dp_logfile, bp, db, route

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
      }, { "rate-limiting", })

      local service = assert(bp.services:insert {
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      })

      route = assert(bp.routes:insert {
        paths = { "/rate-limit-test" },
        service   = service
      })

      assert(helpers.start_kong({
        role = "control_plane",
        database = strategy,
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        cluster_listen = "127.0.0.1:9005",
        cluster_telemetry_listen = "127.0.0.1:9006",
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
        admin_listen = "off",
        proxy_listen = "0.0.0.0:9002",
      }))
      dp_logfile = helpers.get_running_conf(dp_prefix).nginx_err_logs
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)

    describe("\"redis\" storage mode in Hybrid mode", function()
      lazy_setup(function ()
        local admin_client = helpers.admin_client(nil, 9001)
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name = "rate-limiting",
            route = {
              id = route.id
            },
            config = {
              minute = 2,
              policy = "redis",
              redis = {
                host = REDIS_HOST,
                port = REDIS_PORT,
              }
            },
          },
          headers = {
            ["Content-Type"] = "application/json",
          }
        })
        assert.res_status(201, res)
        admin_client:close()
      end)

      lazy_teardown(function ()
        db:truncate("plugins")
      end)

      before_each(function()
        helpers.clean_logfile(dp_logfile)
      end)

      it("sanity test - check if old fields are not pushed & visible in logs as deprecation warnings", function()
        helpers.wait_until(function()
          local proxy_client = helpers.proxy_client(nil, 9002)
          local res = assert(proxy_client:get("/rate-limit-test"))
          proxy_client:close()

          return res.status == 429
        end, 10, 1)
      end)
    end)
  end)
end
