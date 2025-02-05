local helpers = require "spec.helpers"
local fmt = string.format

for _, v in ipairs({ {"off", "off"}, {"on", "off"}, {"on", "on"}, }) do
  local rpc, inc_sync = v[1], v[2]

for _, role in ipairs({"traditional", "control_plane", "data_plane"}) do

describe("#wasm wasmtime (role: " .. role .. ") (#postgres, #db)", function()
  describe("kong prepare", function()
    local conf
    local prefix = "./wasm"

    lazy_setup(function()
      helpers.clean_prefix(prefix)
      assert(helpers.kong_exec("prepare", {
        database = role == "data_plane" and "off" or "postgres",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = true,
        prefix = prefix,
        role = role,
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        cluster_rpc = rpc,
        cluster_incremental_sync = inc_sync,
      }))

      conf = assert(helpers.get_running_conf(prefix))
      conf.cluster_incremental_sync = inc_sync == "on"
    end)

    lazy_teardown(function()
      helpers.clean_prefix(prefix)
    end)

    if role == "control_plane" then
      it("does not populate wasmtime config values", function()
        assert.is_nil(conf.wasmtime_cache_directory,
                         "wasmtime_cache_directory should not be set")
        assert.is_nil(conf.wasmtime_cache_config_file,
                         "wasmtime_cache_config_file should not be set")
      end)

    else
      it("populates wasmtime config values", function()
        assert.is_string(conf.wasmtime_cache_directory,
                         "wasmtime_cache_directory was not set")
        assert.is_string(conf.wasmtime_cache_config_file,
                         "wasmtime_cache_config_file was not set")
      end)

      it("creates the cache directory", function()
        assert(helpers.path.isdir(conf.wasmtime_cache_directory),
               fmt("expected cache directory (%s) to exist",
                   conf.wasmtime_cache_directory))
      end)

      it("creates the cache config file", function()
        assert(helpers.path.isfile(conf.wasmtime_cache_config_file),
               fmt("expected cache config file (%s) to exist",
                   conf.wasmtime_cache_config_file))

        local cache_config = assert(helpers.file.read(conf.wasmtime_cache_config_file))
        assert.matches(conf.wasmtime_cache_directory, cache_config, nil, true,
                       "expected cache config file to reference the cache directory")
      end)
    end
  end) -- kong prepare

  describe("kong stop/start/restart", function()
    local conf
    local prefix = "./wasm"
    local log = prefix .. "/logs/error.log"
    local status_port
    local client
    local cp_prefix = "./wasm-cp"

    lazy_setup(function()
      if role == "traditional" then
        helpers.get_db_utils("postgres")
      end

      helpers.clean_prefix(prefix)
      status_port = helpers.get_available_port()

      assert(helpers.kong_exec("prepare", {
        database = role == "data_plane" and "off" or "postgres",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = true,
        prefix = prefix,
        role = role,
        --wasm_filters_path = helpers.test_conf.wasm_filters_path,
        wasm_filters = "tests,response_transformer",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",

        status_listen = "127.0.0.1:" .. status_port,
        nginx_main_worker_processes = 2,

        cluster_rpc = rpc,
        cluster_incremental_sync = inc_sync,
      }))

      conf = assert(helpers.get_running_conf(prefix))
      conf.cluster_incremental_sync = inc_sync == "on"

      -- we need to briefly spin up a control plane, or else we will get
      -- error.log entries when our data plane tries to connect
      if role == "data_plane" then
        helpers.get_db_utils("postgres")

        assert(helpers.start_kong({
          database = "postgres",
          nginx_conf = "spec/fixtures/custom_nginx.template",
          wasm = true,
          prefix = cp_prefix,
          role = "control_plane",
          wasm_filters = "tests,response_transformer",
          cluster_cert = "spec/fixtures/kong_clustering.crt",
          cluster_cert_key = "spec/fixtures/kong_clustering.key",
          status_listen = "off",
          nginx_main_worker_processes = 2,
          cluster_rpc = rpc,
          cluster_incremental_sync = inc_sync,
        }))
      end
    end)

    lazy_teardown(function()
      if client then
        client:close()
      end

      helpers.stop_kong(prefix)

      if role == "data_plane" then
        helpers.stop_kong(cp_prefix)
      end
    end)

    it("does not introduce any errors", function()
      local function assert_no_errors()
        assert.logfile(log).has.no.line("[error]", true, 0)
        assert.logfile(log).has.no.line("[alert]", true, 0)
        assert.logfile(log).has.no.line("[emerg]", true, 0)
        assert.logfile(log).has.no.line("[crit]",  true, 0)
      end

      local function assert_kong_status(context)
        if not client then
          client = helpers.proxy_client(1000, status_port)
          client.reopen = true
        end

        assert.eventually(function()
          local res, err = client:send({ path = "/status", method = "GET" })
          if res and res.status == 200 then
            return true
          end

          return nil, err or "non-200 status"
        end)
        .is_truthy("failed waiting for kong status " .. context)
      end

      assert(helpers.start_kong(conf, nil, true))
      assert_no_errors()

      assert_kong_status("after fresh startup")
      assert_no_errors()

      assert(helpers.restart_kong(conf))
      assert_no_errors()

      assert_kong_status("after restart")
      assert_no_errors()
    end)
  end) -- kong stop/start/restart

end) -- wasmtime
end -- each role
end -- for inc_sync
