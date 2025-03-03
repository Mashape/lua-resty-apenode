local cjson      = require "cjson"
local helpers    = require "spec.helpers"

local function reset_log(logname)
  local client = assert(helpers.http_client(helpers.mock_upstream_host,
      helpers.mock_upstream_port))
  assert(client:send {
      method  = "DELETE",
      path    = "/reset_log/" .. logname,
      headers = {
        Accept = "application/json"
      }
  })
  client:close()
end

local function get_log(typ, n)
  local entries
  helpers.wait_until(function()
    local client = assert(helpers.http_client(helpers.mock_upstream_host,
                                              helpers.mock_upstream_port))
    local res = client:get("/read_log/" .. typ, {
      headers = {
        Accept = "application/json"
      }
    })
    local raw = assert.res_status(200, res)
    local body = cjson.decode(raw)

    entries = body.entries
    return #entries > 0
  end, 10)
  if n then
    assert(#entries == n, "expected " .. n .. " log entries, but got " .. #entries)
  end
  return entries
end


for _, strategy in helpers.each_strategy() do
  describe("Plugin: http-log (log) [#" .. strategy .. "]", function()
    local proxy_client
    local proxy_client_grpc, proxy_client_grpcs
    local vault_env_name = "HTTP_LOG_KEY2"
    local vault_env_value = "the secret"

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      })

      local service1 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route1 = bp.routes:insert {
        hosts   = { "http_logging.test" },
        service = service1
      }

      bp.plugins:insert {
        route = { id = route1.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/http"
        }
      }

      local service1_1 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route1_1 = bp.routes:insert {
        hosts   = { "http_logging_tag.test" },
        service = service1_1
      }

      bp.plugins:insert {
        route = { id = route1_1.id },
        name = "http-log",
        instance_name = "my-plugin-instance-name",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
            .. ":"
            .. helpers.mock_upstream_port
            .. "/post_log/http_tag"
        }
      }

      local service1_2 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route1_2 = bp.routes:insert {
        hosts   = { "content_type_application_json_http_logging.test" },
        service = service1_2
      }

      bp.plugins:insert {
        route = { id = route1_2.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/http2",
          content_type = "application/json"
        }
      }

      local service1_3 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route1_3 = bp.routes:insert {
        hosts   = { "content_type_application_json_charset_utf_8_http_logging.test" },
        service = service1_3
      }

      bp.plugins:insert {
        route = { id = route1_3.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/http3",
          content_type = "application/json; charset=utf-8"
        }
      }

      local service2 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route2 = bp.routes:insert {
        hosts   = { "https_logging.test" },
        service = service2
      }

      bp.plugins:insert {
        route = { id = route2.id },
        name     = "http-log",
        config   = {
          http_endpoint = "https://" .. helpers.mock_upstream_ssl_host
                                     .. ":"
                                     .. helpers.mock_upstream_ssl_port
                                     .. "/post_log/https"
        }
      }

      local service3 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route3 = bp.routes:insert {
        hosts   = { "http_basic_auth_logging.test" },
        service = service3
      }

      bp.plugins:insert {
        route = { id = route3.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. "testuser:testpassword@"
                                    .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_auth_log/basic_auth"
                                    .. "/testuser/testpassword",
          headers = { ["Hello-World"] = "hi there" },
        }
      }

      local route4 = bp.routes:insert {
        hosts   = { "http_queue_logging.test" },
        service = service1
      }

      bp.plugins:insert {
        route = { id = route4.id },
        name     = "http-log",
        config   = {
          queue = {
            max_batch_size = 5,
            max_coalescing_delay = 0.1,
          },
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/http_queue"
        }
      }

      local route5 = bp.routes:insert {
        hosts   = { "http_host_header.test" },
        service = service1
      }

      bp.plugins:insert {
        route  = { id = route5.id },
        name   = "http-log",
        config = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/http_host_header"
        }
      }

      local route6 = bp.routes:insert {
        hosts   = { "https_logging_faulty.test" },
        service = service2
      }

      bp.plugins:insert {
        route = { id = route6.id },
        name     = "http-log",
        config   = {
          http_endpoint = "https://" .. helpers.mock_upstream_ssl_host
                                     .. ":"
                                     .. helpers.mock_upstream_ssl_port
                                     .. "/delay/5",
          timeout = 1
        }
      }

      local grpc_service = assert(bp.services:insert {
        name = "grpc-service",
        url = helpers.grpcbin_url,
      })

      local route7 = assert(bp.routes:insert {
        service = grpc_service,
        protocols = { "grpc" },
        hosts = { "http_logging_grpc.test" },
      })

      bp.plugins:insert {
        route = { id = route7.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/grpc",
        },
      }

      local grpcs_service = assert(bp.services:insert {
        name = "grpcs-service",
        url = helpers.grpcbin_ssl_url,
      })

      local route8 = assert(bp.routes:insert {
        service = grpcs_service,
        protocols = { "grpcs" },
        hosts = { "http_logging_grpcs.test" },
      })

      bp.plugins:insert {
        route = { id = route8.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/grpcs",
        },
      }

      local service9 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route9 = bp.routes:insert {
        hosts   = { "custom_http_logging.test" },
        service = service9
      }

      bp.plugins:insert {
        route = { id = route9.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/custom_http",
          custom_fields_by_lua = {
            new_field = "return 123",
            ["nested.keys"] = "return 456",
            ["escape\\.dots"] = "return 789",
            ["nested.escape\\.dots"] = "return 135",
            route = "return nil", -- unset route field
          },
        }
      }

      local service10 = bp.services:insert{
        protocol = "http",
        host     = helpers.mock_upstream_host,
        port     = helpers.mock_upstream_port,
      }

      local route10 = bp.routes:insert {
        hosts   = { "vault_headers_logging.test" },
        service = service10
      }

      bp.plugins:insert {
        route = { id = route10.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
            .. ":"
            .. helpers.mock_upstream_port
            .. "/post_log/vault_header",
          headers = {
            key1 = "value1",
            key2 = "{vault://env/http-log-key2}"
          }
        }
      }

      local route1_4 = bp.routes:insert {
        hosts   = { "no_queue.test" },
        service = service1
      }

      bp.plugins:insert {
        route = { id = route1_4.id },
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
            .. ":"
            .. helpers.mock_upstream_port
            .. "/post_log/http",
          queue = {
            concurrency_limit = -1,
          },
        }
      }

      helpers.setenv(vault_env_name, vault_env_value)

      assert(helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))

      proxy_client_grpc = helpers.proxy_client_grpc()
      proxy_client_grpcs = helpers.proxy_client_grpcs()
    end)

    lazy_teardown(function()
      helpers.unsetenv(vault_env_name)
      helpers.stop_kong()
    end)

    before_each(function()
      helpers.clean_logfile()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then
        proxy_client:close()
      end
    end)

    it("logs to HTTP", function()
      reset_log("http")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "http_logging.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("http", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
    end)

    it("identifies plugin in queue handler logs", function()
      reset_log("http_tag")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "http_logging_tag.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("http_tag", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
      assert.logfile().has.line("http\\-log.*my-plugin-instance-name.*done processing queue")
    end)

    it("logs to HTTP with content-type 'application/json'", function()
      reset_log("http2")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "content_type_application_json_http_logging.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("http2", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
      assert.same(entries[1].log_req_headers['content-type'] or "", "application/json")
    end)

    it("logs to HTTP with content-type 'application/json; charset=utf-8'", function()
      reset_log("http3")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "content_type_application_json_charset_utf_8_http_logging.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("http3", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
      assert.same(entries[1].log_req_headers['content-type'] or "", "application/json; charset=utf-8")
    end)

    describe("custom log values by lua", function()
      it("logs custom values", function()
        reset_log("custom_http")
        local res = proxy_client:get("/status/200", {
          headers = {
            ["Host"] = "custom_http_logging.test"
          }
        })
        assert.res_status(200, res)

        local entries = get_log("custom_http", 1)
        assert.same("127.0.0.1", entries[1].client_ip)
        assert.same(123, entries[1].new_field)
        assert.same(456, entries[1].nested.keys)
        assert.same(789, entries[1]["escape.dots"])
        assert.same(135, entries[1].nested["escape.dots"])
      end)
    end)

    it("logs to HTTP (#grpc)", function()
      reset_log("grpc")
      -- Making the request
      local ok, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "http_logging_grpc.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      local entries = get_log("grpc", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
      assert.same("application/grpc", entries[1].request.headers["content-type"])
      assert.same("application/grpc", entries[1].response.headers["content-type"])
    end)

    it("logs to HTTP (#grpcs)", function()
      reset_log("grpcs")
      -- Making the request
      local ok, resp = proxy_client_grpcs({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-authority"] = "http_logging_grpcs.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      local entries = get_log("grpcs", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
      assert.same("application/grpc", entries[1].request.headers["content-type"])
      assert.same("application/grpc", entries[1].response.headers["content-type"])
    end)

    it("logs to HTTPS", function()
      reset_log("https")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "https_logging.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("https", 1)
      assert(#entries == 1, "expected 1 log entry, but got " .. #entries)
      assert.same("127.0.0.1", entries[1].client_ip)
    end)

    it("gracefully handles layer 4 failures", function()
      -- setup: cleanup logs
      local shell = require "resty.shell"
      shell.run(":> " .. helpers.test_conf.nginx_err_logs, nil, 0)

      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "https_logging_faulty.test"
        }
      })
      assert.res_status(200, res)
      assert.logfile().has.line(
        "handler could not process entries: failed request to "
          .. helpers.mock_upstream_ssl_host .. ":"
          .. helpers.mock_upstream_ssl_port .. ": timeout", false, 2
      )
    end)

    it("adds authorization if userinfo and/or header is present", function()
      reset_log("basic_auth")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "http_basic_auth_logging.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("basic_auth", 1)

      local ok = 0
        for name, value in pairs(entries[1].log_req_headers) do
          if name == "authorization" then
            assert.same("Basic dGVzdHVzZXI6dGVzdHBhc3N3b3Jk", value)
            ok = ok + 1
          end
          if name == "hello-world" then
            assert.equal("hi there", value)
            ok = ok + 1
          end
        end
        if ok == 2 then
          return true
        end
    end)

    it("should dereference config.headers value", function()
      reset_log("vault_header")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "vault_headers_logging.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("vault_header", 1)
      assert.same("value1", entries[1].log_req_headers.key1)
      assert.same(vault_env_value, entries[1].log_req_headers.key2)
    end)

    it("http client implicitly adds Host header", function()
      reset_log("http_host_header")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "http_host_header.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("http_host_header", 1)
      local host_header
      if helpers.mock_upstream_port == 80 then
        host_header = helpers.mock_upstream_host
      else
        host_header = helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port
      end
      assert.same(entries[1].log_req_headers['host'] or "", host_header)
    end)

    it("puts changed configuration into effect immediately", function()
        local admin_client = assert(helpers.admin_client())

        local function check_header_is(value)
          reset_log("config_change")
          ngx.sleep(2)

          local res = proxy_client:get("/status/200", {
                headers = {
                  ["Host"] = "config_change.test"
                }
          })
          assert.res_status(200, res)
          local entries = get_log("config_change", 1)
          assert.same(value, entries[1].log_req_headers.key1)
        end

        local res = admin_client:post("/services/", {
            body = {
              name = "config_change",
              url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port,
            },
            headers = {["Content-Type"] = "application/json"},
        })
        assert.res_status(201, res)

        local res = admin_client:post("/services/config_change/routes/", {
            body = {
              hosts = { "config_change.test" },
            },
            headers = {["Content-Type"] = "application/json"},
        })
        assert.res_status(201, res)

        res = admin_client:post("/services/config_change/plugins/", {
            body = {
              name     = "http-log",
              config   = {
                http_endpoint = "http://" .. helpers.mock_upstream_host
                  .. ":"
                  .. helpers.mock_upstream_port
                  .. "/post_log/config_change",
                headers = { key1 = "value1" },
              }
            },
            headers = {["Content-Type"] = "application/json"},
        })
        local body = assert.res_status(201, res)
        local plugin = cjson.decode(body)

        check_header_is("value1")

        local res = admin_client:patch("/plugins/" .. plugin.id, {
            body = {
              config = {
                headers = {
                  key1 = "value2"
                },
              },
            },
            headers = {["Content-Type"] = "application/json"},
        })
        assert.res_status(200, res)

        check_header_is("value2")

        admin_client:close()
   end)

    it("should not use queue when queue.concurrency_limit is -1", function()
      reset_log("http")
      local res = proxy_client:get("/status/200", {
        headers = {
          ["Host"] = "no_queue.test"
        }
      })
      assert.res_status(200, res)

      local entries = get_log("http", 1)
      assert.same("127.0.0.1", entries[1].client_ip)
      assert.logfile().has.no.line("processing queue", true)  -- should not use queue
    end)
  end)

  -- test both with a single worker for a deterministic test,
  -- and with multiple workers for a concurrency test
  for _, workers in ipairs({1, 4}) do
    describe("Plugin: http-log (log) queue (worker_processes = " .. workers .. ") [#" .. strategy .. "]", function()
      local proxy_client

      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        })

        local service = bp.services:insert{
          protocol = "http",
          host     = helpers.mock_upstream_host,
          port     = helpers.mock_upstream_port,
        }

        local route = bp.routes:insert {
          hosts   = { "http_queue_logging.test" },
          service = service
        }

        bp.plugins:insert {
          route = { id = route.id },
          name     = "http-log",
          config   = {
            queue = {
              max_batch_size = 5,
              max_coalescing_delay = 0.1,
            },
            http_endpoint = "http://" .. helpers.mock_upstream_host
                                      .. ":"
                                      .. helpers.mock_upstream_port
                                      .. "/post_log/http_queue"
          }
        }

        local route2 = bp.routes:insert {
          hosts   = { "http_queue_logging2.test" },
          service = service
        }

        bp.plugins:insert {
          route = { id = route2.id },
          name     = "http-log",
          config   = {
            queue = {
              max_batch_size = 5,
              max_coalescing_delay = 0.1,
            },
            http_endpoint = "http://" .. helpers.mock_upstream_host
                                      .. ":"
                                      .. helpers.mock_upstream_port
                                      .. "/post_log/http_queue2"
          }
        }

        assert(helpers.start_kong({
          database = strategy,
          nginx_worker_processes = workers,
        }))

        assert(helpers.start_kong({
          database = strategy,
          prefix = "servroot2",
          admin_listen = "127.0.0.1:9010",
          proxy_listen = "127.0.0.1:9011",
          stream_listen = "off",
          nginx_conf = "spec/fixtures/custom_nginx.template",
          nginx_worker_processes = 1,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
        helpers.stop_kong("servroot2")
      end)

      before_each(function()
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)


      it("logs to HTTP with a buffer", function()
        reset_log("http_queue")

        local n = 200

        for i = 1, n do
          local client = helpers.proxy_client()
          local res = client:get("/status/" .. tostring(200 + (i % 10)), {
            headers = {
              ["Host"] = "http_queue_logging.test"
            }
          })
          assert.res_status(200 + (i % 10), res)
          client:close()
        end

        helpers.wait_until(function()
          local client = assert(helpers.http_client(helpers.mock_upstream_host,
                                                    helpers.mock_upstream_port))
          local res = client:get("/count_log/http_queue", {
            headers = {
              Accept = "application/json"
            }
          })

          if res.status == 500 then
            -- we need to wait until sending has started as /count_log returns a 500 error for unknown log names
            return false
          end

          local count = assert.res_status(200, res)
          client:close()

          if tonumber(count, 10) >= n then
            return true
          end
        end, 60)
      end)

      it("does not mix buffers", function()
        reset_log("http_queue")
        reset_log("http_queue2")

        local n = 200

        for i = 1, n do
          local client = helpers.proxy_client()
          local res = client:get("/status/" .. tostring(200 + (i % 10)), {
            headers = {
              ["Host"] = "http_queue_logging.test"
            }
          })
          assert.res_status(200 + (i % 10), res)
          client:close()

          client = helpers.proxy_client()
          res = client:get("/status/" .. tostring(300 + (i % 10)), {
            headers = {
              ["Host"] = "http_queue_logging2.test"
            }
          })
          assert.res_status(300 + (i % 10), res)
          client:close()
        end

        helpers.wait_until(function()
          local client = assert(helpers.http_client(helpers.mock_upstream_host,
                                                    helpers.mock_upstream_port))
          local res = client:get("/read_log/http_queue", {
            headers = {
              Accept = "application/json"
            }
          })
          local raw = assert.res_status(200, res)
          local body = cjson.decode(raw)
          client:close()

          local client2 = assert(helpers.http_client(helpers.mock_upstream_host,
                                                     helpers.mock_upstream_port))
          local res2 = client2:get("/read_log/http_queue2", {
            headers = {
              Accept = "application/json"
            }
          })
          local raw2 = assert.res_status(200, res2)
          local body2 = cjson.decode(raw2)
          client2:close()

          if not body.count or body.count < n or not body2.count or body2.count < n then
            return false
          end

          table.sort(body.entries, function(a, b)
            return a.response.status < b.response.status
          end)

          local i = 0
          for _, entry in ipairs(body.entries) do
            assert.same("127.0.0.1", entry.client_ip)
            assert.same(200 + math.floor(i / (n / 10)), entry.response.status)
            i = i + 1
          end

          if i ~= n then
            return false
          end

          table.sort(body2.entries, function(a, b)
            return a.response.status < b.response.status
          end)

          i = 0
          for _, entry in ipairs(body2.entries) do
            assert.same("127.0.0.1", entry.client_ip)
            assert.same(300 + math.floor(i / (n / 10)), entry.response.status)
            i = i + 1
          end

          if i ~= n then
            return false
          end

          return true
        end, 60)
      end)
    end)

  end


  describe("Plugin: http-log (log) enabled globally [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      })

      bp.plugins:insert {
        name     = "http-log",
        config   = {
          http_endpoint = "http://" .. helpers.mock_upstream_host
                                    .. ":"
                                    .. helpers.mock_upstream_port
                                    .. "/post_log/http"
        }
      }

      assert(helpers.start_kong({
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then
        proxy_client:close()
      end
    end)

    it("executes successfully when route does not exist", function()
      reset_log("http")
      local res = proxy_client:get("/nonexistant/proxy/path", {
        headers = {
          ["Host"] = "http_no_exist.test"
        }
      })
      assert.res_status(404, res)

      --Assert that the plugin executed and has 1 log entry
      local entries = get_log("http", 1)
      assert.same("127.0.0.1", entries[1].client_ip)

      -- Assertion: there should be no [error], including no error
      -- resulting from attempting to reference the id on
      -- a route when no such value exists after http-log execution
      assert.logfile().has.no.line("[error]", true)
    end)
  end)
end
