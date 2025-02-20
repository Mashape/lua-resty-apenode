local helpers = require "spec.helpers"
local pl_path = require "pl.path"
local pl_file = require "pl.file"


local fixtures = {
  stream_mock = {
    forward_proxy = [[
    server {
      listen 16797;
      listen 16799 ssl;
      listen [::]:16799 ssl;

      ssl_certificate ../spec/fixtures/kong_spec.crt;
      ssl_certificate_key ../spec/fixtures/kong_spec.key;

      error_log logs/proxy.log debug;

      content_by_lua_block {
        require("spec.fixtures.forward-proxy-server").connect()
      }
    }

    server {
      listen 16796;
      listen 16798 ssl;
      listen [::]:16798 ssl;

      ssl_certificate ../spec/fixtures/kong_spec.crt;
      ssl_certificate_key ../spec/fixtures/kong_spec.key;

      error_log logs/proxy_auth.log debug;


      content_by_lua_block {
        require("spec.fixtures.forward-proxy-server").connect({
          basic_auth = ngx.encode_base64("test:konghq#"),
        })
      }
    }
    ]],
  },
}


local proxy_configs = {
  ["https off auth off"] = {
    proxy_server = "http://127.0.0.1:16797",
    proxy_server_ssl_verify = "off",
  },
  ["https off auth on"] = {
    proxy_server = "http://test:konghq%23@127.0.0.1:16796",
    proxy_server_ssl_verify = "off",
  },
  ["https on auth off"] = {
    proxy_server = "https://127.0.0.1:16799",
    proxy_server_ssl_verify = "off",
  },
  ["https on auth on"] = {
    proxy_server = "https://test:konghq%23@127.0.0.1:16798",
    proxy_server_ssl_verify = "off",
  },
  ["https on auth off verify on"] = {
    proxy_server = "https://localhost:16799", -- use `localhost` to match CN of cert
    proxy_server_ssl_verify = "on",
    lua_ssl_trusted_certificate = "spec/fixtures/kong_spec.crt",
  },
}

-- Note: this test suite will become flakky if KONG_TEST_DONT_CLEAN
-- if existing lmdb data is set, the service/route exists and
-- test run too fast before the proxy connection is established

for _, v in ipairs({ {"off", "off"}, {"on", "off"}, {"on", "on"}, }) do
  local rpc, rpc_sync = v[1], v[2]
for _, strategy in helpers.each_strategy() do
  for proxy_desc, proxy_opts in pairs(proxy_configs) do
    describe("CP/DP sync through proxy (" .. proxy_desc .. ") works with #"
             .. strategy .. " rpc=" .. rpc .. " rpc_sync=" .. rpc_sync
             .. " backend", function()
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
          log_level = "debug",

          -- used to render the mock fixture
          nginx_conf = "spec/fixtures/custom_nginx.template",

          cluster_use_proxy = "on",
          proxy_server = proxy_opts.proxy_server,
          proxy_server_ssl_verify = proxy_opts.proxy_server_ssl_verify,
          lua_ssl_trusted_certificate = proxy_opts.lua_ssl_trusted_certificate,

          cluster_rpc = rpc,
          cluster_rpc_sync = rpc_sync,

          -- this is unused, but required for the template to include a stream {} block
          stream_listen = "0.0.0.0:5555",
        }, nil, nil, fixtures))

        if rpc_sync == "on" then
          assert.logfile("servroot2/logs/error.log").has.line("[kong.sync.v2] full sync ends", true, 10)
        end

      end)

      lazy_teardown(function()
        helpers.stop_kong("servroot2")
        helpers.stop_kong()
      end)

      describe("sync works", function()
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
          assert.res_status(201, res)

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

          local auth_on = string.match(proxy_desc, "auth on")

          -- ensure this goes through proxy
          local path = pl_path.join("servroot2", "logs",
                                    auth_on and "proxy_auth.log" or "proxy.log")
          local contents = pl_file.read(path)
          assert.matches("CONNECT 127.0.0.1:9005", contents)

          if auth_on then
            assert.matches("accepted basic proxy%-authorization", contents)
          end

          -- check the debug log of the `cluster_use_proxy` option
          local line = rpc_sync == "on" and "[rpc] using proxy" or
                                            "[clustering] using proxy"
          assert.logfile("servroot2/logs/error.log").has.line(line, true)
        end)
      end)
    end)

  end -- proxy configs
end -- for _, strategy
end -- for rpc_sync
