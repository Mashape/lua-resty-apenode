local helpers = require "spec.helpers"

for _, strategy in helpers.all_strategies() do
  local describe_func = pending
  if strategy ~= "off" then
    -- skip the "off" strategy, as dbless has its own test suite
    describe_func = describe
  end

  describe_func("Status API - with strategy #" .. strategy, function()
    local status_client
    local admin_client
    lazy_setup(function()
      helpers.get_db_utils(nil, {})
      assert(helpers.start_kong {
        status_listen = "127.0.0.1:8100",
        plugins = "admin-api-method",
        database = strategy,
        nginx_worker_processes = 8,
      })
      status_client = helpers.http_client("127.0.0.1", 8100, 20000)

      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if status_client then
        status_client:close()
      end
      assert(helpers.stop_kong())
    end)

    describe("status readiness endpoint", function()

      it("should return 200 in db mode", function()
        local res = assert(status_client:send {
          method = "GET",
          path = "/status/ready",
        })
        assert.res_status(200, res)

      end)

      it("should return 200 after loading an invalid config following a previously uploaded valid config.", function()
        local res = assert(status_client:send {
          method = "GET",
          path = "/status/ready",
        })

        assert.res_status(200, res)

        local res = assert(admin_client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
              _format"\!@#$
            ]]
          },
          headers = {
            ["Content-Type"] = "multipart/form-data"
          },
        })

        assert.res_status(400, res)

        assert
          .with_timeout(5)
          .eventually(function()
            res = status_client:send {
              method = "GET",
              path = "/status/ready",
            }
            status_client:close()
            
            return res and res.status == 200
          end)
          .is_truthy()
      end)
    end)

  end)
end

describe("Status API - with strategy #off", function()
  local status_client
  local admin_client

  lazy_setup(function()
    helpers.get_db_utils(nil, {}) -- runs migrations
    assert(helpers.start_kong {
      status_listen = "127.0.0.1:8100",
      plugins = "admin-api-method",
      database = "off",
      nginx_worker_processes = 8,
    })
    status_client = helpers.http_client("127.0.0.1", 8100, 20000)

    admin_client = helpers.admin_client()
  end)

  lazy_teardown(function()
    if status_client then
      status_client:close()
    end
    assert(helpers.stop_kong())
  end)

  describe("status readiness endpoint", function()

    it("should return 503 when no config, and return 200 after a valid config is uploaded", function()
      local res = assert(status_client:send {
        method = "GET",
        path = "/status/ready",
      })
      
      assert.res_status(503, res)
      
      local res = assert(admin_client:send {
        method = "POST",
        path = "/config",
        body = {
          config = [[
          _format_version: "3.0"
          services:
            - name: test
              url: http://mockbin.org
          ]]
        },
        headers = {
          ["Content-Type"] = "multipart/form-data"
        },
      })
      
      assert.res_status(201, res)
      
      -- wait for the config to be loaded

      assert
        .with_timeout(5)
        .eventually(function()
          res = status_client:send {
            method = "GET",
            path = "/status/ready",
          }
          status_client:close()
          
          return res and res.status == 200
        end)
        .is_truthy()
    end)

    it("should return 200 after loading an invalid config following a previously uploaded valid config.", function()

      local res = assert(status_client:send {
        method = "GET",
        path = "/status/ready",
      })

      assert.res_status(200, res)

      -- upload a invalid config

      local res = assert(admin_client:send {
        method = "POST",
        path = "/config",
        body = {
          config = [[
            _format"\!@#$
          ]]
        },
        headers = {
          ["Content-Type"] = "multipart/form-data"
        },
      })

      assert.res_status(400, res)

      -- should still be 200 cause the invalid config is not loaded

      assert
        .with_timeout(5)
        .eventually(function()
          res = status_client:send {
            method = "GET",
            path = "/status/ready",
          }
          status_client:close()
          
          return res and res.status == 200
        end)
        .is_truthy()

    end)
  end)

end)
