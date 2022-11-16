local helpers = require "spec.helpers"
local ssl_fixtures = require "spec.fixtures.ssl"


local fixtures = {
  dns_mock = helpers.dns_mock.new(),
  http_mock = {
    upstream_mtls = [[
      server {
          server_name example.com;
          listen 16798 ssl;
          ssl_certificate        ../spec/fixtures/mtls_certs/example.com.crt;
          ssl_certificate_key    ../spec/fixtures/mtls_certs/example.com.key;
          ssl_client_certificate ../spec/fixtures/mtls_certs/ca.crt;
          ssl_verify_client      on;
          ssl_session_tickets    off;
          ssl_session_cache      off;
          keepalive_requests     0;
          location = / {
              add_header 'X-Cert' $ssl_client_escaped_cert;
              echo 'it works';
          }
      }
    ]],
    upstream_tls = [[
      server {
          server_name example.com;
          listen 16799 ssl;
          ssl_certificate        ../spec/fixtures/mtls_certs/example.com.crt;
          ssl_certificate_key    ../spec/fixtures/mtls_certs/example.com.key;
          ssl_session_tickets    off;
          ssl_session_cache      off;
          keepalive_requests     0;
          location = / {
              echo 'it works';
          }
      }
    ]]
  },
}


fixtures.dns_mock:A {
  name = "example.com",
  address = "127.0.0.1",
}


for _, strategy in helpers.each_strategy() do
  describe("overriding upstream TLS parameters for database #" .. strategy, function()
    local admin_client
    local bp
    local service_mtls, service_tls
    local certificate, certificate_bad, ca_certificate
    local upstream
    local service_mtls_upstream

    lazy_setup(function()
      bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "certificates",
        "ca_certificates",
        "upstreams",
        "targets",
      })

      service_mtls = assert(bp.services:insert({
        name = "protected-service-mtls",
        url = "tls://127.0.0.1:16798",
      }))

      service_tls = assert(bp.services:insert({
        name = "protected-service",
        url = "tls://example.com:16799", -- domain name needed for hostname check
      }))

      upstream = assert(bp.upstreams:insert({
        name = "backend-mtls",
      }))

      assert(bp.targets:insert({
        upstream = { id = upstream.id, },
        target = "example.com:16798",
      }))

      service_mtls_upstream = assert(bp.services:insert({
        name = "protected-service-mtls-upstream",
        url = "tls://backend-mtls",
        host = "example.com"
      }))

      certificate = assert(bp.certificates:insert({
        cert = ssl_fixtures.cert_client,
        key = ssl_fixtures.key_client,
      }))

      certificate_bad = assert(bp.certificates:insert({
        cert = ssl_fixtures.cert, -- this cert is *not* trusted by upstream
        key = ssl_fixtures.key,
      }))

      ca_certificate = assert(bp.ca_certificates:insert({
        cert = ssl_fixtures.cert_ca,
      }))

      assert(bp.routes:insert({
        service = { id = service_mtls.id, },
        destinations = {
          {
            port = 19000,
          },
        },
        protocols = {
          "tls",
        },
      }))

      assert(bp.routes:insert({
        service = { id = service_tls.id, },
        destinations = {
          {
            port = 19001,
          },
        },
        protocols = {
          "tls",
        },
      }))

      assert(bp.routes:insert({
        service = { id = service_mtls_upstream.id, },
        destinations = {
          {
            port = 19002,
          },
        },
        protocols = {
          "tls",
        },
      }))

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        stream_listen = helpers.get_proxy_ip(false) .. ":19000," ..
        helpers.get_proxy_ip(false) .. ":19001," ..
        helpers.get_proxy_ip(false) .. ":19002"
      }, nil, nil, fixtures))

      admin_client = assert(helpers.admin_client())
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    describe("mutual TLS authentication against upstream with Service object", function()
      describe("no client certificate supplied", function()
        it("accessing protected upstream", function()

          local proxy_client = assert(helpers.proxy_client(6000, 19000))
          local res = assert(proxy_client:send {
            path    = "/"
          })

          local body = assert.res_status(400, res)
          assert.matches("400 No required SSL certificate was sent", body, nil, true)
          assert(proxy_client:close())
        end)
      end)
      
      describe("#db client certificate supplied via service.client_certificate", function()
        lazy_setup(function()
          local res = assert(admin_client:patch("/services/" .. service_mtls.id, {
            body = {
              client_certificate = { id = certificate.id, },
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)
        end)

        it("accessing protected upstream", function()
          local proxy_client
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19000))
            local res = assert(proxy_client:send {
              path    = "/"
            })
            return pcall(function()
              local body = assert.res_status(200, res)
              assert.equals("it works", body)
              assert(proxy_client:close())
            end)
          end, 10)
        end)

        it("send updated client certificate", function ()
          local proxy_client = assert(helpers.proxy_client(6000, 19000))
          local res = assert(proxy_client:send {
            path    = "/",
            headers = {
              ["Host"] = "example.com",
            }
          })
          assert.res_status(200, res)
          local res_cert = res.headers["X-Cert"]
          assert(proxy_client:close())

          res = admin_client:patch("/certificates/" .. certificate.id, {
            body = {
              cert = ssl_fixtures.cert_client2,
              key = ssl_fixtures.key_client2,
            },
            headers = { ["Content-Type"] = "application/json" }
          })
          assert.res_status(200, res)

          -- watting for update
          ngx.sleep(5)

          local proxy_client2 = assert(helpers.proxy_client(6000, 19000))
          local res = assert(proxy_client2:send {
            path    = "/",
            headers = {
              ["Host"] = "example.com",
            }
          })
          assert.res_status(200, res)
          local res_cert2 = res.headers["X-Cert"]
          assert.not_equals(res_cert, res_cert2)
          assert(proxy_client2:close())
        end)

        it("remove client_certificate removes access", function()
          local res = assert(admin_client:patch("/services/" .. service_mtls.id, {
            body = {
              client_certificate = ngx.null,
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          local body
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19000))
            res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })
            return pcall(function()
              body = assert.res_status(400, res)
              assert(proxy_client:close())
            end)
          end, 10)

          assert.matches("400 No required SSL certificate was sent", body, nil, true)
        end)
      end)
    end)

    describe("mutual TLS authentication against upstream with Upstream object", function()
      describe("no client certificate supplied", function()
        it("accessing protected upstream", function()
          local proxy_client = assert(helpers.proxy_client(6000, 19002))
          local res = assert(proxy_client:send {
            path    = "/",
            headers = {
              ["Host"] = "example.com",
            }
          })

          local body = assert.res_status(400, res)
          assert.matches("400 No required SSL certificate was sent", body, nil, true)
          assert(proxy_client:close())
        end)
      end)

      describe("#db client certificate supplied via upstream.client_certificate", function()
        lazy_setup(function()
          local res = assert(admin_client:patch("/upstreams/" .. upstream.id, {
            body = {
              client_certificate = { id = certificate.id, },
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)
        end)

        it("accessing protected upstream", function()

          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19002))
            local res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              local body = assert.res_status(200, res)
              assert.equals("it works", body)
              assert(proxy_client:close())
            end)
          end, 10)
        end)

        it("remove client_certificate removes access", function()
          local res = assert(admin_client:patch("/upstreams/" .. upstream.id, {
            body = {
              client_certificate = ngx.null,
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          local body
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19002))
            res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              body = assert.res_status(400, res)
              assert(proxy_client:close())
            end)
          end, 10)

          assert.matches("400 No required SSL certificate was sent", body, nil, true)
        end)
      end)

      describe("#db when both Service.client_certificate and Upstream.client_certificate are set, Service.client_certificate takes precedence", function()
        lazy_setup(function()
          local res = assert(admin_client:patch("/upstreams/" .. upstream.id, {
            body = {
              client_certificate = { id = certificate_bad.id, },
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          res = assert(admin_client:patch("/services/" .. service_mtls_upstream.id, {
            body = {
              client_certificate = { id = certificate.id, },
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)
        end)

        it("access is allowed because Service.client_certificate overrides Upstream.client_certificate", function()
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19002))
            local res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              local body = assert.res_status(200, res)
              assert.equals("it works", body)
              assert(proxy_client:close())
            end)
          end, 10)
        end)
      end)
    end)

    describe("TLS verification options against upstream", function()
      describe("tls_verify", function()
        it("default is off", function()
          local proxy_client = assert(helpers.proxy_client(6000, 19001))
          local res = assert(proxy_client:send {
            path    = "/",
            headers = {
              ["Host"] = "example.com",
            }
          })
          local body = assert.res_status(200, res)
          assert.equals("it works", body)
          assert(proxy_client:close())
        end)

        it("#db turn it on, request is blocked", function()
          local res = assert(admin_client:patch("/services/" .. service_tls.id, {
            body = {
              tls_verify = true,
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          local body
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19001))
            res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              assert(proxy_client:close())
            end)
          end, 10)
        end)
      end)

      describe("ca_certificates", function()
        it("#db request is allowed through once correct CA certificate is set", function()
          local res = assert(admin_client:patch("/services/" .. service_tls.id, {
            body = {
              tls_verify = true,
              ca_certificates = { ca_certificate.id, },
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          local body
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19001))
            res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              body = assert.res_status(200, res)
              assert(proxy_client:close())
            end)
          end, 10)

          assert.equals("it works", body)
        end)
      end)

      describe("#db tls_verify_depth", function()
        lazy_setup(function()
          local res = assert(admin_client:patch("/services/" .. service_tls.id, {
            body = {
              tls_verify = true,
              ca_certificates = { ca_certificate.id, },
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)
        end)

        it("request is not allowed through if depth limit is too low", function()
          local res = assert(admin_client:patch("/services/" .. service_tls.id, {
            body = {
              tls_verify_depth = 0,
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19001))
            res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              assert(proxy_client:close())
            end)
          end, 10)
        end)

        it("request is allowed through if depth limit is sufficient", function()
          local res = assert(admin_client:patch("/services/" .. service_tls.id, {
            body = {
              tls_verify_depth = 1,
            },
            headers = { ["Content-Type"] = "application/json" },
          }))

          assert.res_status(200, res)

          local body
          helpers.wait_until(function()
            local proxy_client = assert(helpers.proxy_client(6000, 19001))
            res = assert(proxy_client:send {
              path    = "/",
              headers = {
                ["Host"] = "example.com",
              }
            })

            return pcall(function()
              body = assert.res_status(200, res)
              assert(proxy_client:close())
            end)
          end, 10)

          assert.equals("it works", body)
        end)
      end)
    end)
  end)
end