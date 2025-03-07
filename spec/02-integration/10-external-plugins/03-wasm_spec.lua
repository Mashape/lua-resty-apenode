local helpers = require "spec.helpers"

for _, strategy in helpers.each_strategy() do

describe("external plugins and #wasm #" .. strategy, function()
  describe("wasm enabled in conjunction with unused pluginservers", function()
    it("does not prevent kong from starting", function()
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
      }, { "response-transformer", "tests" }))

      local route = assert(bp.routes:insert({
        protocols = { "http" },
        paths = { "/" },
        service = assert(bp.services:insert({})),
      }))

      -- configure a wasm filter plugin
      assert(bp.plugins:insert({
        name = "tests",
        route = route,
        config = "",
      }))

      -- configure a lua plugin
      assert(bp.plugins:insert({
        name = "response-transformer",
        route = route,
        config = {
          add = {
            headers = {
              "X-Lua-Plugin:hello from response-transformer",
            },
          },
        },
      }))

      assert(helpers.start_kong({
        nginx_conf = "spec/fixtures/custom_nginx.template",
        database = strategy,

        wasm = true,
        wasm_filters = "tests",

        plugins = "response-transformer",

        -- this pluginserver does not exist, but we will validate that kong can
        -- start so long as there are no configured/enabled plugins that will
        -- require us to invoke it in any way
        --
        -- XXX: this configuration could be considered invalid, and future changes
        -- to plugin resolution/pluginserver code MAY opt to change this behavior
        pluginserver_names = "not-exists",
        pluginserver_not_exists_start_cmd = "/i/do/not/exist",
        pluginserver_not_exists_query_cmd = "/i/do/not/exist",
      }))

      local client

      finally(function()
        if client then
          client:close()
        end

        helpers.stop_kong()
      end)

      client = helpers.proxy_client()
      local res = client:get("/", {
        headers = {
          ["X-PW-Test"] = "local_response",
          ["X-PW-Input"] = "hello from wasm",
        },
      })

      -- verify that our wasm filter ran
      local body = assert.res_status(200, res)
      assert.equals("hello from wasm", body)

      -- verify that our lua plugin (response-transformer) ran
      local header = assert.response(res).has.header("X-Lua-Plugin")
      assert.equals("hello from response-transformer", header)
    end)
  end)
end)

end -- each strategy
