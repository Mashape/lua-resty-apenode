local cjson         = require "cjson"
local helpers       = require "spec.helpers"
local pl_file       = require "pl.file"
local pl_path       = require "pl.path"
local fmt           = string.format
local random_string = require("kong.tools.rand").random_string
local uuid          = require("kong.tools.uuid").uuid
local strip         = require("kong.tools.string").strip


local FILE_LOG_PATH = os.tmpname()


local function substr(needle, haystack)
  return string.find(haystack, needle, 1, true) ~= nil
end


local function check_log(contains, not_contains, file)
  if type(contains) ~= "table" then
    contains = { contains }
  end

  if type(not_contains) ~= "table" then
    not_contains = { not_contains }
  end

  if #contains == 0 and #not_contains == 0 then
    error("log file assertion without any contains/not_contains check", 2)
  end


  local fh = assert(io.open(file or FILE_LOG_PATH, "r"))

  local should_find = {}
  local should_not_find = {}

  for line in fh:lines() do
    for i, s in ipairs(contains) do
      should_find[i] = should_find[i] or substr(s, line)
    end

    for i, s in ipairs(not_contains) do
      should_not_find[i] = should_not_find[i] or substr(s, line)
    end
  end

  local errors = {}

  for i, s in ipairs(contains) do
    if not should_find[i] then
      table.insert(errors, fmt("expected to find '%s' in the log file", s))
    end
  end

  for i, s in ipairs(not_contains) do
    if should_not_find[i] then
      table.insert(errors, fmt("expected not to find '%s' in the log file", s))
    end
  end

  if #errors > 0 then
    return false, table.concat(errors, ",\n")
  end

  return true
end


local function wait_for_log_content(contains, not_contains, msg, file)
  assert
    .with_timeout(10)
    .ignore_exceptions(true)
    .eventually(function() return check_log(contains, not_contains, file) end)
    .is_truthy(msg or "log file contains expected content")
end


local function wait_for_json_log_entry()
  local json

  assert
    .with_timeout(10)
    .ignore_exceptions(true)
    .eventually(function()
      local data = assert(pl_file.read(FILE_LOG_PATH))

      data = strip(data)
      assert(#data > 0, "log file is empty")

      data = data:match("%b{}")
      assert(data, "log file does not contain JSON")

      json = cjson.decode(data)
    end)
    .has_no_error("log file contains a valid JSON entry")

  return json
end



for _, strategy in helpers.each_strategy() do
  describe("Plugin: file-log (log) [#" .. strategy .. "]", function()
    local proxy_client
    local proxy_client_grpc, proxy_client_grpcs

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      })

      local route = bp.routes:insert {
        hosts = { "file_logging.test" },
      }

      bp.plugins:insert {
        route = { id = route.id },
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = true,
        },
      }

      local grpc_service = assert(bp.services:insert {
        name = "grpc-service",
        url = helpers.grpcbin_url,
      })

      local route2 = assert(bp.routes:insert {
        service = grpc_service,
        protocols = { "grpc" },
        hosts = { "tcp_logging_grpc.test" },
      })

      bp.plugins:insert {
        route = { id = route2.id },
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = true,
        },
      }

      local grpcs_service = assert(bp.services:insert {
        name = "grpcs-service",
        url = helpers.grpcbin_ssl_url,
      })

      local route3 = assert(bp.routes:insert {
        service = grpcs_service,
        protocols = { "grpcs" },
        hosts = { "tcp_logging_grpcs.test" },
      })

      bp.plugins:insert {
        route = { id = route3.id },
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = true,
        },
      }

      local route4 = bp.routes:insert {
        hosts = { "file_logging_by_lua.test" },
      }

      bp.plugins:insert {
        route = { id = route4.id },
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = true,
          custom_fields_by_lua = {
            new_field = "return 123",
            ["nested.keys"] = "return 456",
            ["escape\\.dots"] = "return 789",
            ["nested.escape\\.dots"] = "return 135",
            route = "return nil", -- unset route field
          },
        },
      }

      local route5 = bp.routes:insert {
        hosts = { "file_logging2.test" },
      }

      bp.plugins:insert {
        route = { id = route5.id },
        name     = "file-log",
        config   = {
          path   = helpers.test_conf.prefix .. "/dir/file",
          reopen = true,
        },
      }

      local route6 = bp.routes:insert {
        hosts = { "file_logging3.test" },
      }

      bp.plugins:insert {
        route = { id = route6.id },
        name     = "file-log",
        config   = {
          path   = helpers.test_conf.prefix .. "/dir/",
          reopen = true,
        },
      }

      local route7 = bp.routes:insert {
        hosts = { "file_logging4.test" },
      }

      bp.plugins:insert {
        route = { id = route7.id },
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = false,
        },
      }

      local route8 = bp.routes:insert {
        hosts = { "file_logging5.test" },
      }

      bp.plugins:insert {
        route = { id = route8.id },
        name     = "file-log",
        config   = {
          path   = "/etc/shadow",
          reopen = true,
        },
      }

      local route9 = bp.routes:insert {
        hosts = { "file_logging6.test" },
      }

      bp.plugins:insert {
        route = { id = route9.id },
        name     = "file-log",
        config   = {
          path   = "/dev/null",
          reopen = true,
        },
      }

      local route10 = bp.routes:insert {
        hosts = { "file_logging10.test" },
        response_buffering = true,
      }

      bp.plugins:insert({
        name = "pre-function",
        route = { id = route10.id },
        config = {
          access = {
            [[
              kong.service.request.enable_buffering()
            ]],
          },
        }
      })

      bp.plugins:insert {
        route = { id = route10.id },
        name     = "file-log",
        config   = {
          path   = FILE_LOG_PATH,
          reopen = true,
          custom_fields_by_lua = {
            new_field = "return 123",
            ["nested.keys"] = "return 456",
            ["escape\\.dots"] = "return 789",
            ["nested.escape\\.dots"] = "return 135",
            route = "return nil", -- unset route field
          },
        },
      }

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))

      proxy_client_grpc = helpers.proxy_client_grpc()
      proxy_client_grpcs = helpers.proxy_client_grpcs()
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
      os.remove(FILE_LOG_PATH)
    end)
    after_each(function()
      if proxy_client then
        proxy_client:close()
      end

      os.remove(FILE_LOG_PATH)
    end)

    it("logs to file", function()
      local uuid = random_string()

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid,
          ["Host"] = "file_logging.test"
        }
      }))
      assert.res_status(200, res)

      local log_message = wait_for_json_log_entry()
      assert.same("127.0.0.1", log_message.client_ip)
      assert.same(uuid, log_message.request.headers["file-log-uuid"])
      assert.is_number(log_message.request.size)
      assert.is_number(log_message.response.size)
    end)

    describe("custom log values by lua", function()
      it("logs custom values to file", function()
        local uuid = random_string()

        -- Making the request
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/status/200",
          headers = {
            ["file-log-uuid"] = uuid,
            ["Host"] = "file_logging_by_lua.test"
          }
        }))
        assert.res_status(200, res)

        local log_message = wait_for_json_log_entry()
        assert.same("127.0.0.1", log_message.client_ip)
        assert.same(uuid, log_message.request.headers["file-log-uuid"])
        assert.is_number(log_message.request.size)
        assert.is_number(log_message.response.size)
        assert.same(123, log_message.new_field)
        assert.same(456, log_message.nested.keys)
        assert.same(789, log_message["escape.dots"])
        assert.same(135, log_message.nested["escape.dots"])
      end)

      it("unsets existing log values", function()
        local uuid = random_string()

        -- Making the request
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/status/200",
          headers = {
            ["file-log-uuid"] = uuid,
            ["Host"] = "file_logging_by_lua.test"
          }
        }))
        assert.res_status(200, res)

        local log_message = wait_for_json_log_entry()
        assert.same("127.0.0.1", log_message.client_ip)
        assert.same(uuid, log_message.request.headers["file-log-uuid"])
        assert.is_number(log_message.request.size)
        assert.is_number(log_message.response.size)
        assert.same(nil, log_message.route)
      end)
      it("correct upstream status when we use response phase", function()
        local uuid = random_string()

        -- Making the request
        local res = assert(proxy_client:send({
          method = "GET",
          path = "/status/200",
          headers = {
            ["file-log-uuid"] = uuid,
            ["Host"] = "file_logging10.test"
          }
        }))
        assert.res_status(200, res)

        local log_message = wait_for_json_log_entry()
        assert.same("127.0.0.1", log_message.client_ip)
        assert.same(uuid, log_message.request.headers["file-log-uuid"])
        assert.is_number(log_message.request.size)
        assert.is_number(log_message.response.size)
        assert.same(nil, log_message.route)
        assert.same(200, log_message.upstream_status)
      end)
    end)

    it("logs to file #grpc", function()
      local uuid = random_string()

      -- Making the request
      local ok, resp = proxy_client_grpc({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-H"] = "'file-log-uuid: " .. uuid .. "'",
          ["-authority"] = "tcp_logging_grpc.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      local log_message = wait_for_json_log_entry()
      assert.same("127.0.0.1", log_message.client_ip)
      assert.same(uuid, log_message.request.headers["file-log-uuid"])
    end)

    it("logs to file #grpcs", function()
      local uuid = random_string()

      -- Making the request
      local ok, resp = proxy_client_grpcs({
        service = "hello.HelloService.SayHello",
        body = {
          greeting = "world!"
        },
        opts = {
          ["-H"] = "'file-log-uuid: " .. uuid .. "'",
          ["-authority"] = "tcp_logging_grpcs.test",
        }
      })
      assert.truthy(ok)
      assert.truthy(resp)

      local log_message = wait_for_json_log_entry()
      assert.same("127.0.0.1", log_message.client_ip)
      assert.same(uuid, log_message.request.headers["file-log-uuid"])
    end)

    it("reopens file on each request", function()
      local uuid1 = uuid()

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid1,
          ["Host"] = "file_logging.test"
        }
      }))
      assert.res_status(200, res)

      wait_for_log_content(uuid1, nil, "log file contains 1st request ID")

      -- remove the file to see whether it gets recreated
      os.remove(FILE_LOG_PATH)

      -- Making the next request
      local uuid2 = uuid()
      res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid2,
          ["Host"] = "file_logging.test"
        }
      }))
      assert.res_status(200, res)

      local uuid3 = uuid()
      res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid3,
          ["Host"] = "file_logging.test"
        }
      }))
      assert.res_status(200, res)

      wait_for_log_content(
        { uuid2, uuid3 },
        { uuid1 },
        "log file contains 2nd and 3rd request IDs but not the 1st"
      )
    end)

    it("does not create log file if directory doesn't exist", function()
      local uuid = random_string()

      helpers.clean_logfile()

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid,
          ["Host"] = "file_logging2.test"
        }
      }))
      assert.res_status(200, res)

      assert.logfile().has.line("\\[file-log\\] failed to open the file: " ..
      "No such file or directory.*while logging request", false, 30)
    end)

    it("the given path is not a file but a directory", function()
      local uuid = random_string()

      helpers.clean_logfile()

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid,
          ["Host"] = "file_logging3.test"
        }
      }))
      assert.res_status(200, res)

      assert.logfile().has.line("\\[file-log\\] failed to open the file: " ..
      "Is a directory.*while logging request", false, 30)
    end)

    it("logs are lost if reopen = false and file doesn't exist", function()
      local uuid1 = uuid()

      os.remove(FILE_LOG_PATH)

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid1,
          ["Host"] = "file_logging4.test"
        }
      }))
      assert.res_status(200, res)

      assert.is_false(pl_path.exists(FILE_LOG_PATH))
    end)

    it("does not log if Kong has no write permissions to the file", function()
      local uuid = random_string()

      helpers.clean_logfile()

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid,
          ["Host"] = "file_logging5.test"
        }
      }))
      assert.res_status(200, res)

      assert.logfile().has.line("\\[file-log\\] failed to open the file: " ..
      "Permission denied.*while logging request", false, 30)
    end)

    it("the given path is a character device file", function()
      local uuid = random_string()

      helpers.clean_logfile()

      -- Making the request
      local res = assert(proxy_client:send({
        method = "GET",
        path = "/status/200",
        headers = {
          ["file-log-uuid"] = uuid,
          ["Host"] = "file_logging6.test"
        }
      }))
      assert.res_status(200, res)

      -- file can be opened and written to without errors
      assert.logfile().has.no.line("[file-log] failed to open the file", true, 7)

      -- but no actual content is written to the file
      wait_for_log_content(nil, uuid, "no content", "/dev/null")
    end)
  end)
end
