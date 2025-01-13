local cjson          = require "cjson"
local helpers        = require "spec.helpers"
local redis_helper   = require "spec.helpers.redis_helper"

local REDIS_HOST      = helpers.redis_host
local REDIS_PORT      = helpers.redis_port
local REDIS_SSL_PORT  = helpers.redis_ssl_port
local REDIS_SSL_SNI   = helpers.redis_ssl_sni
local REDIS_PASSWORD  = ""
local REDIS_DATABASE  = 1

local SLEEP_TIME = 0.01
local ITERATIONS = 10

local fmt = string.format


local proxy_client = helpers.proxy_client


local function wait(reset)
  ngx.update_time()
  local now = ngx.now()
  local seconds = (now - math.floor(now/60)*60)
  if (seconds > 50) or reset then -- tune tolerance time to reduce test time or stabilize tests depending on machine spec
    ngx.sleep(60 - seconds + 3) -- avoid time jitter between test and kong
  end
end

local function wait_mills()
  ngx.update_time()
  local now = ngx.now()
  local millis = (now - math.floor(now))
  ngx.sleep(1 - millis)
end

local redis_confs = {
  no_ssl = {
    redis_port = REDIS_PORT,
  },
  ssl_verify = {
    redis_ssl = true,
    redis_ssl_verify = true,
    redis_server_name = REDIS_SSL_SNI,
    redis_port = REDIS_SSL_PORT,
  },
  ssl_no_verify = {
    redis_ssl = true,
    redis_ssl_verify = false,
    redis_server_name = "really.really.really.does.not.exist.host.test",
    redis_port = REDIS_SSL_PORT,
  },
}


local function test_limit(path, host, limit)
  wait()
  limit = limit or ITERATIONS
  for i = 1, limit do
    local res = proxy_client():get(path, {
      headers = { Host = host:format(i) },
    })
    assert.res_status(200, res)
  end

  ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

  local res = proxy_client():get(path, {
    headers = { Host = host:format(1) },
  })
  assert.res_status(429, res)
  assert.equal(limit, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
  assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
end


local function init_db(strategy, policy)
  local bp = helpers.get_db_utils(strategy, {
    "routes",
    "services",
    "plugins",
    "consumers",
    "keyauth_credentials",
  })

  if policy == "redis" then
    redis_helper.reset_redis(REDIS_HOST, REDIS_PORT)
  end

  return bp
end


for _, strategy in helpers.each_strategy() do
  for _, policy in ipairs({"local", "cluster", "redis"}) do

    for redis_conf_name, redis_conf in pairs(redis_confs) do
      if redis_conf_name ~= "no_ssl" and policy ~= "redis" then
        goto continue
      end

      describe(fmt("Plugin: response-ratelimiting (access) with policy: #%s #%s [#%s]", redis_conf_name, policy, strategy), function()

        lazy_setup(function()
          local bp = init_db(strategy, policy)

          if policy == "local" then
            SLEEP_TIME = 0.001
          else
            SLEEP_TIME = 0.15
          end

          local consumer1 = bp.consumers:insert {custom_id = "provider_123"}
          bp.keyauth_credentials:insert {
            key      = "apikey123",
            consumer = { id = consumer1.id },
          }

          local consumer2 = bp.consumers:insert {custom_id = "provider_124"}
          bp.keyauth_credentials:insert {
            key      = "apikey124",
            consumer = { id = consumer2.id },
          }

          local route1 = bp.routes:insert {
            hosts      = { "test1.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route1.id },
            config   = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS } },
            },
          })

          local route2 = bp.routes:insert {
            hosts      = { "test2.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route2.id },
            config   = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS*2, hour = ITERATIONS*4 },
                                    image = { minute = ITERATIONS } },
            },
          })

          local route3 = bp.routes:insert {
            hosts      = { "test3.test" },
            protocols  = { "http", "https" },
          }

          bp.plugins:insert {
            name     = "key-auth",
            route = { id = route3.id },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route3.id },
            config   = {
              policy = policy,
              redis = {
                host        = REDIS_HOST,
                port        = REDIS_PORT,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits = { video = { minute = ITERATIONS - 3 }
            } },
          })

          bp.response_ratelimiting_plugins:insert({
            route = { id = route3.id },
            consumer = { id = consumer1.id },
            config      = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS - 2 } },
            },
          })

          local route4 = bp.routes:insert {
            hosts      = { "test4.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route4.id },
            config   = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = {
                video = { minute = ITERATIONS * 2 + 2 },
                image = { minute = ITERATIONS }
              },
            }
          })

          local route7 = bp.routes:insert {
            hosts      = { "test7.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route7.id },
            config   = {
              fault_tolerant           = false,
              policy                   = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              block_on_first_violation = true,
              limits                   = {
                video = {
                  minute = ITERATIONS,
                  hour = ITERATIONS * 2,
                },
                image = {
                  minute = 4,
                },
              },
            }
          })

          local route8 = bp.routes:insert {
            hosts      = { "test8.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route8.id },
            config   = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS, hour = ITERATIONS*2 },
                                    image = { minute = ITERATIONS-1 } },
            }
          })

          local route9 = bp.routes:insert {
            hosts      = { "test9.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert({
            route = { id = route9.id },
            config   = {
              fault_tolerant      = false,
              policy              = policy,
              hide_client_headers = true,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits              = { video = { minute = ITERATIONS } },
            }
          })


          local service10 = bp.services:insert()
          bp.routes:insert {
            hosts = { "test-service1.test" },
            service = service10,
          }
          bp.routes:insert {
            hosts = { "test-service2.test" },
            service = service10,
          }

          bp.response_ratelimiting_plugins:insert({
            service = { id = service10.id },
            config = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS } },
            }
          })

          local grpc_service = assert(bp.services:insert {
            name = "grpc",
            url = helpers.grpcbin_url,
          })

          assert(bp.routes:insert {
            protocols = { "grpc" },
            paths = { "/hello.HelloService/" },
            service = grpc_service,
          })

          bp.response_ratelimiting_plugins:insert({
            service = { id = grpc_service.id },
            config = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS } },
            }
          })

          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            lua_ssl_trusted_certificate = "spec/fixtures/redis/ca.crt",
          }))
        end)

        lazy_teardown(function()
          helpers.stop_kong()
        end)

        describe("Without authentication (IP address)", function()

          it("returns remaining counter", function()
            wait()
            local n = math.floor(ITERATIONS / 2)
            for _ = 1, n do
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
                headers = { Host = "test1.test" },
              })
              assert.res_status(200, res)
            end

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
              headers = { Host = "test1.test" },
            })
            assert.res_status(200, res)
            assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
            assert.equal(ITERATIONS - n - 1, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          end)

          it("returns remaining counter #grpc", function()
            wait()

            local ok, res = helpers.proxy_client_grpc(){
              service = "hello.HelloService.SayHello",
              opts = {
                ["-v"] = true,
              },
            }
            assert.truthy(ok, res)
            assert.matches("x%-ratelimit%-limit%-video%-minute: %d+", res)
            assert.matches("x%-ratelimit%-remaining%-video%-minute: %d+", res)

            -- Note: tests for this plugin rely on the ability to manipulate
            -- upstream response headers, which is not currently possible with
            -- the grpc service we use. Therefore, we are only testing that
            -- headers are indeed inserted.
          end)

          it("blocks if exceeding limit", function()
            wait(true)
            test_limit("/response-headers?x-kong-limit=video%3D1", "test1.test")
          end)

          it("counts against the same service register from different routes", function()
            wait()
            local n = math.floor(ITERATIONS / 2)
            for i = 1, n do
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1%2C%20test%3D" .. ITERATIONS, {
                headers = { Host = "test-service1.test" },
              })
              assert.res_status(200, res)
            end

            for i = n+1, ITERATIONS do
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1%2C%20test%3D" .. ITERATIONS, {
                headers = { Host = "test-service2.test" },
              })
              assert.res_status(200, res)
            end

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the list

            -- Additional request, while limit is ITERATIONS/minute
            local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1%2C%20test%3D" .. ITERATIONS, {
              headers = { Host = "test-service1.test" },
            })
            assert.res_status(429, res)
          end)

          it("handles multiple limits", function()
            wait()
            local n = math.floor(ITERATIONS / 2)
            local res
            for i = 1, n do
              if i == n then
                ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit
              end
              res = proxy_client():get("/response-headers?x-kong-limit=video%3D2%2C%20image%3D1", {
                headers = { Host = "test2.test" },
              })
              assert.res_status(200, res)
            end

            assert.equal(ITERATIONS * 2, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
            assert.equal(ITERATIONS * 2 - (n * 2), tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
            assert.equal(ITERATIONS * 4, tonumber(res.headers["x-ratelimit-limit-video-hour"]))
            assert.equal(ITERATIONS * 4 - (n * 2), tonumber(res.headers["x-ratelimit-remaining-video-hour"]))
            assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-image-minute"]))
            assert.equal(ITERATIONS - n, tonumber(res.headers["x-ratelimit-remaining-image-minute"]))

            for i = n+1, ITERATIONS do
              if i == ITERATIONS then
                ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit
              end
              res = proxy_client():get("/response-headers?x-kong-limit=video%3D1%2C%20image%3D1", {
                headers = { Host = "test2.test" },
              })
              assert.res_status(200, res)
            end
            assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-image-minute"]))
            assert.equal(ITERATIONS * 4 - (n * 2) - (ITERATIONS - n), tonumber(res.headers["x-ratelimit-remaining-video-hour"]))
            assert.equal(ITERATIONS * 2 - (n * 2) - (ITERATIONS - n), tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1%2C%20image%3D1", {
              headers = { Host = "test2.test" },
            })

            assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-image-minute"]))
            assert.equal(ITERATIONS * 4 - (n * 2) - (ITERATIONS - n) - 1, tonumber(res.headers["x-ratelimit-remaining-video-hour"]))
            assert.equal(ITERATIONS * 2 - (n * 2) - (ITERATIONS - n) - 1, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
            assert.res_status(429, res)
          end)
        end)

        describe("With authentication", function()
          describe("API-specific plugin", function()
            it("blocks if exceeding limit and a per consumer & route setting", function()
              test_limit("/response-headers?apikey=apikey123&x-kong-limit=video%3D1", "test3.test", ITERATIONS - 2)
            end)

            it("blocks if exceeding limit and a per route setting", function()
              test_limit("/response-headers?apikey=apikey124&x-kong-limit=video%3D1", "test3.test", ITERATIONS - 3)
            end)
          end)
        end)

        describe("Upstream usage headers", function()
          it("should append the headers with multiple limits", function()
            wait()
            local res = proxy_client():get("/get", {
              headers = { Host = "test8.test" },
            })
            local json = cjson.decode(assert.res_status(200, res))
            assert.equal(ITERATIONS-1, tonumber(json.headers["x-ratelimit-remaining-image"]))
            assert.equal(ITERATIONS, tonumber(json.headers["x-ratelimit-remaining-video"]))

            -- Actually consume the limits
            local res = proxy_client():get("/response-headers?x-kong-limit=video%3D2%2C%20image%3D1", {
              headers = { Host = "test8.test" },
            })
            local json2 = cjson.decode(assert.res_status(200, res))
            assert.equal(ITERATIONS-1, tonumber(json2.headers["x-ratelimit-remaining-image"]))
            assert.equal(ITERATIONS, tonumber(json2.headers["x-ratelimit-remaining-video"]))

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            local res = proxy_client():get("/get", {
              headers = { Host = "test8.test" },
            })
            local body = cjson.decode(assert.res_status(200, res))
            assert.equal(ITERATIONS-2, tonumber(body.headers["x-ratelimit-remaining-image"]))
            assert.equal(ITERATIONS-2, tonumber(body.headers["x-ratelimit-remaining-video"]))
          end)

          it("combines multiple x-kong-limit headers from upstream", function()
            wait()
            -- NOTE: this test is not working as intended because multiple response headers are merged into one comma-joined header by send_text_response function
            for _ = 1, ITERATIONS do
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D2&x-kong-limit=image%3D1", {
                headers = { Host = "test4.test" },
              })
              assert.res_status(200, res)
            end

            proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
              headers = { Host = "test4.test" },
            })

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            local res = proxy_client():get("/response-headers?x-kong-limit=video%3D2&x-kong-limit=image%3D1", {
              headers = { Host = "test4.test" },
            })

            assert.res_status(429, res)
            assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-image-minute"]))
            assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          end)
        end)

        it("should block on first violation", function()
          wait()
          local res = proxy_client():get("/response-headers?x-kong-limit=video%3D2%2C%20image%3D4", {
            headers = { Host = "test7.test" },
          })
          assert.res_status(200, res)

          ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

          local res = proxy_client():get("/response-headers?x-kong-limit=video%3D2", {
            headers = { Host = "test7.test" },
          })
          local body = assert.res_status(429, res)
          local json = cjson.decode(body)
          assert.matches("API rate limit exceeded for 'image'", json.message)
        end)

        describe("Config with hide_client_headers", function()
          it("does not send rate-limit headers when hide_client_headers==true", function()
            wait()
            local res = proxy_client():get("/status/200", {
              headers = { Host = "test9.test" },
            })

            assert.res_status(200, res)
            assert.is_nil(res.headers["x-ratelimit-remaining-video-minute"])
            assert.is_nil(res.headers["x-ratelimit-limit-video-minute"])
          end)
        end)
      end)

      describe(fmt("Plugin: response-ratelimiting (expirations) with policy: #%s #%s [#%s]", redis_conf_name, policy, strategy), function()

        lazy_setup(function()
          local bp = init_db(strategy, policy)

          local route = bp.routes:insert {
            hosts      = { "expire1.test" },
            protocols  = { "http", "https" },
          }

          bp.response_ratelimiting_plugins:insert {
            route = { id = route.id },
            config   = {
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
              },
              fault_tolerant    = false,
              limits            = { video = { second = ITERATIONS } },
            }
          }

          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            lua_ssl_trusted_certificate = "spec/fixtures/redis/ca.crt",
          }))
        end)

        lazy_teardown(function()
          helpers.stop_kong()
        end)

        it("expires a counter", function()
          wait_mills()
          local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
            headers = { Host = "expire1.test" },
          })

          ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

          assert.res_status(200, res)
          assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-video-second"]))
          assert.equal(ITERATIONS-1, tonumber(res.headers["x-ratelimit-remaining-video-second"]))

          ngx.sleep(0.01)
          wait_mills() -- Wait for counter to expire

          local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
            headers = { Host = "expire1.test" },
          })

          ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

          assert.res_status(200, res)
          assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-video-second"]))
          assert.equal(ITERATIONS-1, tonumber(res.headers["x-ratelimit-remaining-video-second"]))
        end)
      end)

      describe(fmt("Plugin: response-ratelimiting (access - global for single consumer) with policy: #%s  #%s [#%s]", redis_conf_name, policy, strategy), function()

        lazy_setup(function()
          local bp = init_db(strategy, policy)

          local consumer = bp.consumers:insert {
            custom_id = "provider_126",
          }

          bp.key_auth_plugins:insert()

          bp.keyauth_credentials:insert {
            key      = "apikey126",
            consumer = { id = consumer.id },
          }

          -- just consumer, no no route or service
          bp.response_ratelimiting_plugins:insert({
            consumer = { id = consumer.id },
            config = {
              fault_tolerant    = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS } },
            }
          })

          for i = 1, ITERATIONS do
            bp.routes:insert({ hosts = { fmt("test%d.test", i) } })
          end

          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            lua_ssl_trusted_certificate = "spec/fixtures/redis/ca.crt",
          }))
        end)

        lazy_teardown(function()
          helpers.stop_kong()
        end)

        it("blocks when the consumer exceeds their quota, no matter what service/route used", function()
          test_limit("/response-headers?apikey=apikey126&x-kong-limit=video%3D1", "test%d.test")
        end)
      end)

      describe(fmt("Plugin: response-ratelimiting (access - global) with policy: #%s #%s [#%s]", redis_conf_name, policy, strategy), function()

        lazy_setup(function()
          local bp = init_db(strategy, policy)

          -- global plugin (not attached to route, service or consumer)
          bp.response_ratelimiting_plugins:insert({
            config = {
              fault_tolerant = false,
              policy            = policy,
              redis = {
                host        = REDIS_HOST,
                port        = redis_conf.redis_port,
                ssl         = redis_conf.redis_ssl,
                ssl_verify  = redis_conf.redis_ssl_verify,
                server_name = redis_conf.redis_server_name,
                password    = REDIS_PASSWORD,
                database    = REDIS_DATABASE,
              },
              limits            = { video = { minute = ITERATIONS } },
            }
          })

          for i = 1, ITERATIONS do
            bp.routes:insert({ hosts = { fmt("test%d.test", i) } })
          end

          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            lua_ssl_trusted_certificate = "spec/fixtures/redis/ca.crt",
          }))
        end)

        lazy_teardown(function()
          helpers.stop_kong()
        end)

        before_each(function()
          wait()
        end)

        it("blocks if exceeding limit", function()
          wait()
          for i = 1, ITERATIONS do
            local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
              headers = { Host = fmt("test%d.test", i) },
            })
            assert.res_status(200, res)
          end

          ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

          -- last query, while limit is ITERATIONS/minute
          local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
            headers = { Host = "test1.test" },
          })
          assert.res_status(429, res)
          assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
        end)
      end)

      describe(fmt("Plugin: response-ratelimiting (fault tolerance) with policy: #%s #%s [#%s]", redis_conf_name, policy, strategy), function()
        if policy == "cluster" then
          local bp, db

          pending("fault tolerance tests for cluster policy temporarily disabled", function()

            before_each(function()
              bp, db = init_db(strategy, policy)

              local route1 = bp.routes:insert {
                hosts = { "failtest1.test" },
              }

              bp.response_ratelimiting_plugins:insert {
                route = { id = route1.id },
                config   = {
                  fault_tolerant    = false,
                  policy            = policy,
                  redis = {
                    host        = REDIS_HOST,
                    port        = redis_conf.redis_port,
                    ssl         = redis_conf.redis_ssl,
                    ssl_verify  = redis_conf.redis_ssl_verify,
                    server_name = redis_conf.redis_server_name,
                    password    = REDIS_PASSWORD,
                  },
                  limits            = { video = { minute = ITERATIONS} },
                }
              }

              local route2 = bp.routes:insert {
                hosts = { "failtest2.test" },
              }

              bp.response_ratelimiting_plugins:insert {
                route = { id = route2.id },
                config   = {
                  fault_tolerant    = true,
                  policy            = policy,
                  redis = {
                    host        = REDIS_HOST,
                    port        = redis_conf.redis_port,
                    ssl         = redis_conf.redis_ssl,
                    ssl_verify  = redis_conf.redis_ssl_verify,
                    server_name = redis_conf.redis_server_name,
                    password    = REDIS_PASSWORD,
                  },
                  limits            = { video = {minute = ITERATIONS} }
                }
              }

              assert(helpers.start_kong({
                database   = strategy,
                nginx_conf = "spec/fixtures/custom_nginx.template",
                lua_ssl_trusted_certificate = "spec/fixtures/redis/ca.crt",
              }))

              wait()
            end)

            after_each(function()
              helpers.stop_kong()
            end)

            it("does not work if an error occurs", function()
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
                headers = { Host = "failtest1.test" },
              })
              assert.res_status(200, res)
              assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
              assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

              -- Simulate an error on the database
              -- (valid SQL and CQL)
              db.connector:query("DROP TABLE response_ratelimiting_metrics;")
              -- FIXME this leaves the database in a bad state after this test,
              -- affecting subsequent tests.

              -- Make another request
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
                headers = { Host = "failtest1.test" },
              })
              local body = assert.res_status(500, res)
              local json = cjson.decode(body)
              assert.matches("An unexpected error occurred", json.message)
            end)

            it("keeps working if an error occurs", function()
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
                headers = { Host = "failtest2.test" },
              })
              assert.res_status(200, res)
              assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
              assert.equal(ITERATIONS, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

              -- Simulate an error on the database
              -- (valid SQL and CQL)
              db.connector:query("DROP TABLE response_ratelimiting_metrics;")
              -- FIXME this leaves the database in a bad state after this test,
              -- affecting subsequent tests.

              -- Make another request
              local res = proxy_client():get("/response-headers?x-kong-limit=video%3D1", {
                headers = { Host = "failtest2.test" },
              })
              assert.res_status(200, res)
              assert.is_nil(res.headers["x-ratelimit-limit-video-minute"])
              assert.is_nil(res.headers["x-ratelimit-remaining-video-minute"])
            end)
          end)
        end

        if policy == "redis" then

          before_each(function()
            local bp = init_db(strategy, policy)

            local route1 = bp.routes:insert {
              hosts      = { "failtest3.test" },
              protocols  = { "http", "https" },
            }

            bp.response_ratelimiting_plugins:insert {
              route = { id = route1.id },
              config   = {
                fault_tolerant = false,
                policy         = policy,
                redis = {
                  host = "5.5.5.5",
                  port = REDIS_PORT
                },
                limits         = { video = { minute = ITERATIONS } },
              }
            }

            local route2 = bp.routes:insert {
              hosts      = { "failtest4.test" },
              protocols  = { "http", "https" },
            }

            bp.response_ratelimiting_plugins:insert {
              route = { id = route2.id },
              config   = {
                fault_tolerant = true,
                policy         = policy,
                redis = {
                  host = "5.5.5.5",
                  port = REDIS_PORT
                },
                limits         = { video = { minute = ITERATIONS } },
              }
            }

            assert(helpers.start_kong({
              database   = strategy,
              nginx_conf = "spec/fixtures/custom_nginx.template",
              lua_ssl_trusted_certificate = "spec/fixtures/redis/ca.crt",
            }))

            wait()
          end)

          after_each(function()
            helpers.stop_kong()
          end)

          it("does not work if an error occurs", function()
            -- Make another request
            local res = proxy_client():get("/status/200", {
              headers = { Host = "failtest3.test" },
            })
            local body = assert.res_status(500, res)
            local json = cjson.decode(body)
            assert.matches("An unexpected error occurred", json.message)
          end)
          it("keeps working if an error occurs", function()
            -- Make another request
            local res = proxy_client():get("/status/200", {
              headers = { Host = "failtest4.test" },
            })
            assert.res_status(200, res)
            assert.falsy(res.headers["x-ratelimit-limit-video-minute"])
            assert.falsy(res.headers["x-ratelimit-remaining-video-minute"])
          end)
        end
      end)

      ::continue::
    end
  end
end
