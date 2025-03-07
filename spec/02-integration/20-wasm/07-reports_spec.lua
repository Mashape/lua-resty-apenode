local helpers = require "spec.helpers"
local constants = require "kong.constants"
local cjson = require "cjson"


for _, strategy in helpers.each_strategy() do
  local dns_hostsfile
  local reports_server

  describe("anonymous reports for #wasm #" .. strategy, function()
    local reports_send_ping = function(port)
      ngx.sleep(0.2) -- hand over the CPU so other threads can do work (processing the sent data)
      local admin_client = helpers.admin_client()
      local res = admin_client:post("/reports/send-ping" .. (port and "?port=" .. port or ""))
      assert.response(res).has_status(200)
      admin_client:close()
    end

    lazy_setup(function()
      dns_hostsfile = assert(os.tmpname() .. ".hosts")
      local fd = assert(io.open(dns_hostsfile, "w"))
      assert(fd:write("127.0.0.1 " .. constants.REPORTS.ADDRESS))
      assert(fd:close())

      require("kong.runloop.wasm").enable({
        { name = "tests",
          path = helpers.test_conf.wasm_filters_path .. "/tests.wasm",
        },
      })

      local bp = assert(helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
        "filter_chains",
      }, { "reports-api" }))

      local http_srv = assert(bp.services:insert {
        name = "mock-service",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      })

      bp.routes:insert({ service = http_srv,
                         protocols = { "http" },
                         hosts = { "http-service.test" }})

      bp.plugins:insert({
        name = "reports-api",
        config = {}
      })

      bp.filter_chains:insert({
        filters = { { name = "tests" } },
        service = { id = http_srv.id },
      })

      assert(helpers.start_kong({
        nginx_conf = "spec/fixtures/custom_nginx.template",
        database = strategy,
        dns_hostsfile = dns_hostsfile,
        resolver_hosts_file = dns_hostsfile,
        plugins = "bundled,reports-api",
        wasm = true,
        anonymous_reports = true,
      }))
    end)

    lazy_teardown(function()
      os.remove(dns_hostsfile)

      helpers.stop_kong()
    end)

    before_each(function()
      reports_server = helpers.tcp_server(constants.REPORTS.STATS_TLS_PORT, {tls=true})
    end)

    it("logs number of enabled Wasm filters", function()
      reports_send_ping(constants.REPORTS.STATS_TLS_PORT)

      local _, reports_data = assert(reports_server:join())
      reports_data = cjson.encode(reports_data)

      assert.match("wasm_cnt=2", reports_data)
    end)

    it("logs number of requests triggering a Wasm filter", function()
      local proxy_client = assert(helpers.proxy_client())
      local res = proxy_client:get("/", {
        headers = { host  = "http-service.test" }
      })
      assert.res_status(200, res)

      local proxy_client2 = assert(helpers.proxy_client())
      local res = proxy_client2:get("/", {
        headers = { host  = "http-service.test" }
      })
      assert.res_status(200, res)

      reports_send_ping(constants.REPORTS.STATS_TLS_PORT)

      local _, reports_data = assert(reports_server:join())
      reports_data = cjson.encode(reports_data)

      assert.match("wasm_reqs=2", reports_data)
      proxy_client:close()
      proxy_client2:close()
    end)

  end)
end
