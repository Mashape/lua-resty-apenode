local helpers = require "spec.helpers"
local cjson = require "cjson"
local pl_path = require "pl.path"
local ssl_fixtures = require "spec.fixtures.ssl"

local FILE_LOG_PATH = os.tmpname()


local function reload_router(flavor)
  helpers = require("spec.internal.module").reload_helpers(flavor)
end

-- TODO: remove it when we confirm it is not needed
local function gen_route(flavor, r)
  return r
end


for _, flavor in ipairs({ "traditional", "traditional_compatible", "expressions" }) do
for _, strategy in helpers.each_strategy() do
  describe("gRPC Proxying [#" .. strategy .. ", flavor = " .. flavor .. "]", function()
    local proxy_client_grpc
    local proxy_client_grpcs
    local proxy_client
    local proxy_client_ssl
    local proxy_client_h2c
    local proxy_client_h2
    local ca_certificate
    local mock_grpcs_service

    reload_router(flavor)

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "ca_certificates",
      })

      local service1 = assert(bp.services:insert {
        name = "grpc",
        url = helpers.grpcbin_url,
      })

      local service2 = assert(bp.services:insert {
        name = "grpcs",
        url = helpers.grpcbin_ssl_url,
      })

      local mock_grpc_service = assert(bp.services:insert {
        name = "mock_grpc_service",
        url = "grpc://localhost:8765",
      })

      mock_grpcs_service = assert(bp.services:insert {
        name = "mock_grpcs_service",
        url = helpers.grpcbin_ssl_url,
      })

      local mock_grpc_service_retry = assert(bp.services:insert {
        name = "mock_grpc_service_retry",
        url = "grpc://grpc_retry",
      })

      local upstream_retry = assert(bp.upstreams:insert {
        name = "grpc_retry",
      })

      assert(bp.targets:insert { -- bad target, this one will timeout
        upstream = upstream_retry,
        target = "127.0.0.1:54321",
      })

      assert(bp.targets:insert {
        upstream = upstream_retry,
        target = "127.0.0.1:8765",
      })

      assert(bp.routes:insert(gen_route(flavor, {
        protocols = { "grpc" },
        hosts = { "grpc" },
        service = service1,
      })))

      assert(bp.routes:insert(gen_route(flavor, {
        protocols = { "grpcs" },
        hosts = { "grpcs" },
        service = service2,
      })))

      assert(bp.routes:insert(gen_route(flavor, {
        protocols = { "grpc" },
        hosts = { "grpc_authority_1.example" },
        service = mock_grpc_service,
        preserve_host = true,
      })))

      assert(bp.routes:insert(gen_route(flavor, {
        protocols = { "grpc" },
        hosts = { "grpc_authority_2.example" },
        service = mock_grpc_service,
        preserve_host = false,
      })))

      assert(bp.routes:insert(gen_route(flavor, {
        protocols = { "grpcs" },
        hosts = { "example.com" },
        service = mock_grpcs_service,
        preserve_host = false,
      })))

      assert(bp.routes:insert(gen_route(flavor, {
        protocols = { "grpc" },
        hosts = { "grpc_authority_retry.example" },
        service = mock_grpc_service_retry,
        preserve_host = false,
      })))

      assert(bp.plugins:insert {
        service = mock_grpc_service_retry,
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = true,
        },
      })

      ca_certificate = assert(bp.ca_certificates:insert({
        cert = ssl_fixtures.cert_ca2,
      }))

      local fixtures = {
        http_mock = {}
      }

      fixtures.http_mock.my_server_block = [[
        server {
          server_name myserver;
          listen 8765;
          http2 on;

          location ~ / {
            content_by_lua_block {
              ngx.header.content_type = "application/grpc"
              ngx.header.received_host = ngx.req.get_headers()["Host"]
            }
          }
        }
      ]]

      assert(helpers.start_kong({
        router_flavor = flavor,
        database = strategy,
        nginx_conf       = "spec/fixtures/custom_nginx.template",
      }, nil, nil, fixtures))

      proxy_client_grpc = helpers.proxy_client_grpc()
      proxy_client_grpcs = helpers.proxy_client_grpcs()
      proxy_client_h2c = helpers.proxy_client_h2c()
      proxy_client_h2 = helpers.proxy_client_h2()
      proxy_client = helpers.proxy_client()
      proxy_client_ssl = helpers.proxy_ssl_client()
    end)

    before_each(function()
      os.remove(FILE_LOG_PATH)
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    it("proxies grpc", function()
      local ok, resp = assert(proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "grpc",
        }
      }))
      assert.truthy(ok)
      assert.truthy(resp)
    end)

    it("proxies grpc, streaming response", function()
      local ok, resp = assert(proxy_client_grpc({
        service = "hello.HelloService.LotsOfReplies",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "grpc",
        }
      }))
      assert.truthy(ok)
      assert.truthy(resp)
    end)

    it("proxies grpc, streaming request", function()
      local ok, resp = assert(proxy_client_grpc({
        service = "hello.HelloService.LotsOfGreetings",
        body = [[
            { "greeting": "world!" }
            { "greeting": "people!" }
            { "greeting": "y`all!" }
        ]],
        opts = {
          ["-authority"] = "grpc",
        }
      }))
      assert.truthy(ok)
      assert.truthy(resp)
    end)

    it("proxies grpc, streaming request/response", function()
      local ok, resp = assert(proxy_client_grpc({
        service = "hello.HelloService.BidiHello",
        body = [[
            { "greeting": "world!" }
            { "greeting": "people!" }
            { "greeting": "y`all!" }
        ]],
        opts = {
          ["-authority"] = "grpc",
        }
      }))
      assert.truthy(ok)
      assert.truthy(resp)
    end)

    it("proxies grpcs", function()
      local ok, resp = assert(proxy_client_grpcs({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "grpcs",
        }
      }))
      assert.truthy(ok)
      assert.truthy(resp)
    end)

    it("proxies :authority header if `preserve_host` is set", function()
      local _, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "grpc_authority_1.example",
          ["-v"] = true,
        }
      })

      assert.matches("received%-host: grpc_authority_1.example", resp)
    end)

    it("sets default :authority header if `preserve_host` isn't set", function()
      local _, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "grpc_authority_2.example",
          ["-v"] = true,
        }
      })

      assert.matches("received%-host: localhost:8765", resp)
    end)

    it("proxies :authority header on balancer retry", function()
      local resp
      local file_log_json
      helpers.wait_until(function()
        os.remove(FILE_LOG_PATH)
        local _
        _, resp = proxy_client_grpc({
          service = "hello.HelloService.SayHello",
          body = {
            greeting = "world!"
          },
          opts = {
            ["-authority"] = "grpc_authority_retry.example",
            ["-v"] = true,
          }
        })
        local f = io.open(FILE_LOG_PATH, 'r')
        if not f then
          return false
        end

        file_log_json = cjson.decode((assert(f:read("*a"))))
        f:close()
        return pl_path.exists(FILE_LOG_PATH) and pl_path.getsize(FILE_LOG_PATH) > 0
              and #file_log_json.tries >= 2
      end, 5)

      assert.matches("received%-host: 127.0.0.1:8765", resp)
    end)

    describe("errors with", function()
      it("non-http2 request on grpc route", function()
        local res = assert(proxy_client:post("/", {
          headers = {
            ["Host"] = "grpc",
            ["Content-Type"] = "application/grpc"
          }
        }))
        local body = assert.res_status(426, res)
        local json = cjson.decode(body)
        assert.equal("Please use HTTP2 protocol", json.message)
        assert.contains("Upgrade", res.headers.connection)
        assert.same("HTTP/2", res.headers["upgrade"])
      end)

      it("non-http2 request on grpcs route", function()
        local res = assert(proxy_client_ssl:post("/", {
          headers = {
            ["Host"] = "grpcs",
            ["Content-Type"] = "application/grpc"
          }
        }))
        local body = assert.res_status(426, res)
        local json = cjson.decode(body)
        assert.equal("Please use HTTP2 protocol", json.message)
      end)

      it("non-grpc request on grpc route (no content-type)", function()
        local body, headers = proxy_client_h2c({
          headers = {
            ["method"] = "POST",
            [":authority"] = "grpc",
          }
        })
        local json = cjson.decode(body)
        assert.same("415", headers:get(":status"))
        assert.same("Non-gRPC request matched gRPC route", json.message)
      end)

      it("non-grpc request on grpcs route (no content-type)", function()
        local body, headers = proxy_client_h2({
          headers = {
            ["method"] = "POST",
            [":authority"] = "grpcs",
          }
        })
        local json = cjson.decode(body)
        assert.same("415", headers:get(":status"))
        assert.same("Non-gRPC request matched gRPC route", json.message)
      end)

      it("non-grpc request on grpc route (non-grpc content-type)", function()
        local body, headers = proxy_client_h2c({
          headers = {
            ["method"] = "POST",
            ["content-type"] = "application/json",
            [":authority"] = "grpc",
          }
        })
        local json = cjson.decode(body)
        assert.same("415", headers:get(":status"))
        assert.same("Non-gRPC request matched gRPC route", json.message)
      end)

      it("non-grpc request on grpcs route (non-grpc content-type)", function()
        local body, headers = proxy_client_h2({
          headers = {
            ["method"] = "POST",
            ["content-type"] = "application/json",
            [":authority"] = "grpcs",
          }
        })
        local json = cjson.decode(body)
        assert.same("415", headers:get(":status"))
        assert.same("Non-gRPC request matched gRPC route", json.message)
      end)

      it("grpc on grpcs route", function()
        local ok, resp = proxy_client_grpc({
          service = "hello.HelloService.SayHello",
          body = {
            greeting = "world!"
          },
          opts = {
            ["-authority"] = "grpcs",
          }
        })
        assert.falsy(ok)

        assert.matches("Code: Canceled", resp, nil, true)
        assert.matches("Message: gRPC request matched gRPCs route", resp, nil, true)
      end)
    end)

    if strategy ~= "off" then
      describe("grpcs with tls", function()
        local function proxy_grpcs_with_ca_certificate()
          local ok, resp = assert(proxy_client_grpcs({
            service = "hello.HelloService.SayHello",
            body = {
              greeting = "world!"
            },
            opts = {
              ["-authority"] = "example.com",
            }
          }))
          assert.truthy(ok)
          assert.truthy(resp)
        end

        it("proxies grpcs without ca_certificate", function()
          proxy_grpcs_with_ca_certificate()
        end)

        describe("tls_verify", function()
          it("default is off", function()
            local admin_client = helpers.admin_client()
            local res = assert(admin_client:patch("/services/" .. mock_grpcs_service.id, {
              body = {
                ca_certificates = { ca_certificate.id, },
              },
              headers = { ["Content-Type"] = "application/json" },
            }))

            assert.res_status(200, res)
            proxy_grpcs_with_ca_certificate()
          end)

          it("turn it on", function()
            local admin_client = helpers.admin_client()
            local res = assert(admin_client:patch("/services/" .. mock_grpcs_service.id, {
              body = {
                tls_verify = true,
                ca_certificates = { ca_certificate.id, },
              },
              headers = { ["Content-Type"] = "application/json" },
            }))

            assert.res_status(200, res)
            proxy_grpcs_with_ca_certificate()
          end)
        end)

        describe("tls_verify_depth", function()
          lazy_setup(function()
            local admin_client = helpers.admin_client()
            local res = assert(admin_client:patch("/services/" .. mock_grpcs_service.id, {
              body = {
                tls_verify = true,
                ca_certificates = { ca_certificate.id, },
              },
              headers = { ["Content-Type"] = "application/json" },
            }))

            assert.res_status(200, res)
          end)

          it("request is allowed through if depth limit is sufficient", function()
            local admin_client = helpers.admin_client()
            local res = assert(admin_client:patch("/services/" .. mock_grpcs_service.id, {
              body = {
                tls_verify_depth = 1,
              },
              headers = { ["Content-Type"] = "application/json" },
            }))

            assert.res_status(200, res)
            proxy_grpcs_with_ca_certificate()
          end)
        end)
      end)
    end
  end)
end
end   -- flavor
