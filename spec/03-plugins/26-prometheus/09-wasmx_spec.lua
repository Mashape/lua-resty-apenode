local helpers = require "spec.helpers"
local cjson = require "cjson"


local TEST_NAME_HEADER = "X-PW-Test"
local TESTS_FILTER_FILE = helpers.test_conf.wasm_filters_path .. "/tests.wasm"

local fixtures = {
  dns_mock = helpers.dns_mock.new({
    mocks_only = true
  }),
  http_mock = {},
  stream_mock = {}
}

fixtures.dns_mock:A({
  name = "mock.io",
  address = "127.0.0.1"
})

fixtures.dns_mock:A({
  name = "status.io",
  address = "127.0.0.1"
})


local function add_service_and_route(bp, name, path)
  local service = assert(bp.services:insert({
    name = name,
    url = helpers.mock_upstream_url,
  }))

  local route = assert(bp.routes:insert({
    name = name .. "-route",
    service = { id = service.id },
    paths = { path },
    hosts = { name },
    protocols = { "https" },
  }))

  return service, route
end


local function add_filter_to_service(bp, filter_name, service)
  local filters = {
    { name = filter_name, enabled = true, config = {} },
  }

  assert(bp.filter_chains:insert({
    service = { id = service.id }, filters = filters,
  }))
end


for _, strategy in helpers.each_strategy() do
  describe("Plugin: prometheus (metrics) [#" .. strategy .. "]", function()
    local admin_client

    lazy_setup(function()
      local filter_dir = helpers.make_temp_dir()
      local filter_file = filter_dir .. "/tests.wasm"
      local status_api_port = helpers.get_available_port()

      -- copy filter to a custom location to avoid filter metadata collision
      assert(helpers.file.copy(TESTS_FILTER_FILE, filter_file))
      assert(helpers.file.write(filter_dir .. "/tests.meta.json", cjson.encode({
        config_schema = { type = "object", properties = {} },
        metrics = {
          label_patterns = {
            { label = "service", pattern = "(_s_id=([0-9a-z%-]+))" },
            { label = "route", pattern = "(_r_id=([0-9a-z%-]+))" },
          }
        }
      })))

      require("kong.runloop.wasm").enable({
        { name = "tests", path = filter_file },
      })

      local bp = helpers.get_db_utils(strategy, {
        "services", "routes", "plugins", "filter_chains",
      })

      local service, _ = add_service_and_route(bp, "mock", "/")
      local service2, _ = add_service_and_route(bp, "mock2", "/v2")

      add_service_and_route(bp, "status.io", "/metrics")

      add_filter_to_service(bp, "tests", service)
      add_filter_to_service(bp, "tests", service2)

      assert(bp.plugins:insert({
        name = "prometheus",
        config = { wasm_metrics = true },
      }))

      assert(helpers.start_kong({
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = true,
        wasm_filters_path = filter_dir,
        plugins = "bundled,prometheus",
        status_listen = '127.0.0.1:' .. status_api_port .. ' ssl',
        status_access_log = "logs/status_access.log",
        status_error_log = "logs/status_error.log"
      }, nil, nil, fixtures))

      local proxy_client = helpers.proxy_ssl_client()

      local res = proxy_client:get("/", {
        headers = { host = "mock", [TEST_NAME_HEADER] = "update_metrics" },
      })
      assert.res_status(200, res)

      res = proxy_client:get("/v2", {
        headers = { host = "mock2", [TEST_NAME_HEADER] = "update_metrics" },
      })
      assert.res_status(200, res)

      proxy_client:close()
    end)

    lazy_teardown(function()
      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong()
    end)

    before_each(function()
      admin_client = helpers.admin_client()
    end)

    after_each(function()
      if admin_client then
        admin_client:close()
      end
    end)

    it("exposes Proxy-Wasm counters", function()
      local res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })

      local body = assert.res_status(200, res)
      local expected_c = '# HELP pw_tests_a_counter\n'
        .. '# TYPE pw_tests_a_counter counter\n'
        .. 'pw_tests_a_counter 2'

      assert.matches(expected_c, body, nil, true)
    end)

    it("exposes Proxy-Wasm labeled counters", function()
      local res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })

      local body = assert.res_status(200, res)

      local expected_c = '# HELP pw_tests_a_labeled_counter\n'
        .. '# TYPE pw_tests_a_labeled_counter counter\n'
        .. 'pw_tests_a_labeled_counter{service="mock2",route="mock2-route"} 1\n'
        .. 'pw_tests_a_labeled_counter{service="mock",route="mock-route"} 1'

      assert.matches(expected_c, body, nil, true)
    end)

    it("exposes Proxy-Wasm gauges", function()
      local res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })

      local body = assert.res_status(200, res)

      local expected_g = '# HELP pw_tests_a_gauge\n'
        .. '# TYPE pw_tests_a_gauge gauge\n'
        .. 'pw_tests_a_gauge 1'

      assert.matches(expected_g, body, nil, true)
    end)

    it("exposes Proxy-Wasm labeled gauges", function()
      local res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })

      local body = assert.res_status(200, res)

      local expected_g = '# HELP pw_tests_a_labeled_gauge\n'
        .. '# TYPE pw_tests_a_labeled_gauge gauge\n'
        .. 'pw_tests_a_labeled_gauge{service="mock2",route="mock2-route"} 1\n'
        .. 'pw_tests_a_labeled_gauge{service="mock",route="mock-route"} 1'

      assert.matches(expected_g, body, nil, true)
    end)

    it("exposes Proxy-Wasm histograms", function()
      local res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })

      local body = assert.res_status(200, res)

      local expected_h = '# HELP pw_tests_a_histogram\n'
        .. '# TYPE pw_tests_a_histogram histogram\n'
        .. 'pw_tests_a_histogram{le="1"} 2\n'
        .. 'pw_tests_a_histogram{le="2"} 4\n'
        .. 'pw_tests_a_histogram{le="4"} 6\n'
        .. 'pw_tests_a_histogram{le="8"} 8\n'
        .. 'pw_tests_a_histogram{le="16"} 10\n'
        .. 'pw_tests_a_histogram{le="32"} 12\n'
        .. 'pw_tests_a_histogram{le="64"} 14\n'
        .. 'pw_tests_a_histogram{le="128"} 16\n'
        .. 'pw_tests_a_histogram{le="256"} 18\n'
        .. 'pw_tests_a_histogram{le="512"} 20\n'
        .. 'pw_tests_a_histogram{le="1024"} 22\n'
        .. 'pw_tests_a_histogram{le="2048"} 24\n'
        .. 'pw_tests_a_histogram{le="4096"} 26\n'
        .. 'pw_tests_a_histogram{le="8192"} 28\n'
        .. 'pw_tests_a_histogram{le="16384"} 30\n'
        .. 'pw_tests_a_histogram{le="32768"} 32\n'
        .. 'pw_tests_a_histogram{le="65536"} 34\n'
        .. 'pw_tests_a_histogram{le="+Inf"} 36\n'
        .. 'pw_tests_a_histogram_sum 524286\n'
        .. 'pw_tests_a_histogram_count 36'

      assert.matches(expected_h, body, nil, true)
    end)

    it("exposes Proxy-Wasm labeled histograms", function()
      local res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })

      local body = assert.res_status(200, res)

      local expected_h = '# HELP pw_tests_a_labeled_histogram\n'
        .. '# TYPE pw_tests_a_labeled_histogram histogram\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="1"} 1\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="2"} 2\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="4"} 3\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="8"} 4\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="16"} 5\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="32"} 6\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="64"} 7\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="128"} 8\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="256"} 9\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="512"} 10\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="1024"} 11\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="2048"} 12\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="4096"} 13\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="8192"} 14\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="16384"} 15\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="32768"} 16\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="65536"} 17\n'
        .. 'pw_tests_a_labeled_histogram{service="mock2",route="mock2-route",le="+Inf"} 18\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="1"} 1\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="2"} 2\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="4"} 3\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="8"} 4\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="16"} 5\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="32"} 6\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="64"} 7\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="128"} 8\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="256"} 9\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="512"} 10\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="1024"} 11\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="2048"} 12\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="4096"} 13\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="8192"} 14\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="16384"} 15\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="32768"} 16\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="65536"} 17\n'
        .. 'pw_tests_a_labeled_histogram{service="mock",route="mock-route",le="+Inf"} 18\n'
        .. 'pw_tests_a_labeled_histogram_sum{service="mock2",route="mock2-route"} 262143\n'
        .. 'pw_tests_a_labeled_histogram_sum{service="mock",route="mock-route"} 262143\n'
        .. 'pw_tests_a_labeled_histogram_count{service="mock2",route="mock2-route"} 18\n'
        .. 'pw_tests_a_labeled_histogram_count{service="mock",route="mock-route"} 18'

      assert.matches(expected_h, body, nil, true)
    end)
  end)
end
