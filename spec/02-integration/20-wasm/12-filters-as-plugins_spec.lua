local helpers = require "spec.helpers"
local cjson = require "cjson"
local rand = require "kong.tools.rand"
local uuid = require "kong.tools.uuid"

local FILTER_HEADER = "X-Wasm-Filter-Plugin"
local PLUGIN_HEADER = "X-Lua-Plugin"
local FILTER_CHAIN_HEADER = "X-Wasm-Filter-Chain"

local FILTER_PATH = assert(helpers.test_conf.wasm_filters_path)

local function json_request(data)
  return {
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = cjson.encode(data),
  }
end

local function rt_config(header, value)
  value = value or rand.random_string()
  return {
      append = {
        headers = {
          header .. ":" .. value,
        },
      },
    }
end

local function new_filter(value)
  return {
    name = "response_transformer",
    config = cjson.encode(rt_config(FILTER_HEADER, value)),
  }
end

local function new_plugin(value)
  return {
    name = "response-transformer",
    config = rt_config(PLUGIN_HEADER, value),
  }
end

local function new_filter_chain(value)
  return {
    filters = {
      {
        name = "response_transformer",
        config = cjson.encode(rt_config(FILTER_CHAIN_HEADER, value)),
      },
    },
  }
end

for _, strategy in helpers.each_strategy({ "postgres" }) do

describe("#wasm filters as plugins (#" .. strategy .. ")", function()
  local bp, db
  local admin, proxy
  local service, route

  local function assert_bad_response(res)
    assert.response(res).has.status(400)
    return assert.response(res).has.jsonbody()
  end

  local function check_response(header_name, header_value, context)
    helpers.wait_for_all_config_update()

    local res, err = proxy:send({ path = "/status/200" })
    assert(res and err == nil, tostring(err) .. ": " .. context)

    assert.response(res).has.status(200)
    local got = assert.response(res).has.header(header_name)
    assert.equals(header_value, got, context)
  end

  local function check_filter_response(header_value, context)
    return check_response(FILTER_HEADER, header_value, context)
  end

  local function admin_request(method, path, data)
    local params = (data ~= nil and json_request(data)) or {}
    params.method = method
    params.path = path

    local res, err = admin:send(params)
    assert.is_nil(err)
    return res
  end

  local function create_plugin(plugin)
    local res = admin:post("/plugins", json_request(plugin))
    assert.response(res).has.status(201)
    return assert.response(res).has.jsonbody()
  end

  local function update_plugin(id, plugin)
    local res = admin:patch("/plugins/" .. id, json_request(plugin))
    assert.response(res).has.status(200)
    return assert.response(res).has.jsonbody()
  end

  local function get_plugin(endpoint, id)
    local res = admin:get("/plugins/" .. id)
    assert.response(res).has.status(200)
    return assert.response(res).has.jsonbody()
  end

  local function create_filter_chain(fc)
    local res = admin:post("/filter-chains", json_request(fc))
    assert.response(res).has.status(201)
    return assert.response(res).has.jsonbody()
  end


  lazy_setup(function()
    assert(helpers.file.copy(FILTER_PATH .. "/tests.wasm",
                             FILTER_PATH .. "/tests-01.wasm"))
    assert(helpers.file.copy(FILTER_PATH .. "/tests.wasm",
                             FILTER_PATH .. "/tests-02.wasm"))

    require("kong.runloop.wasm").enable({
      { name = "response_transformer",
        path = FILTER_PATH .. "/response_transformer.wasm",
      },
      {
        name = "tests-01",
        path = FILTER_PATH .. "/tests-01.wasm",
      },
      {
        name = "tests-02",
        path = FILTER_PATH .. "/tests-02.wasm",
      },
    })

    bp, db = helpers.get_db_utils(strategy, {
      "routes",
      "services",
      "filter_chains",
      "plugins",
    })

    assert(helpers.start_kong({
      database = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      nginx_main_worker_processes = "2",
      wasm = true,
      wasm_filters = "response_transformer,tests-01,tests-02",
      plugins = "response-transformer",
    }))

    admin = helpers.admin_client()
    proxy = helpers.proxy_client()
    proxy.reopen = true
  end)

  lazy_teardown(function()
    if admin then
      admin:close()
    end

    if proxy then
      proxy:close()
    end

    helpers.stop_kong()
    helpers.file.delete(FILTER_PATH .. "/tests-01.wasm")
    helpers.file.delete(FILTER_PATH .. "/tests-02.wasm")
  end)

  before_each(function()
    -- create a scratch service/route to use
    service = assert(bp.services:insert({}))
    route = assert(bp.routes:insert({
      paths = { "/" },
      service = service,
    }))
  end)

  after_each(function()
    bp.filter_chains:truncate()
    bp.plugins:truncate()

    db.routes:delete(route)
    db.services:delete(service)
  end)

  describe("/plugins", function()
    describe("POST", function()
      it("creates a plugin instance from a filter", function()
        local value = rand.random_string()
        local filter = new_filter(value)
        filter.route = { id = route.id }
        create_plugin(filter)
        check_filter_response(value, "POST /plugins")
      end)

      it("validates foreign references", function()
        local filter = new_filter()

        filter.route = { id = uuid.uuid() }
        local res = admin_request("POST", "/plugins", filter)
        local err = assert_bad_response(res)
        assert.equals("foreign key violation", err.name)
        assert.same({ route = filter.route }, err.fields)

        filter.route = nil
        filter.service = { id = uuid.uuid() }
        local res = admin_request("POST", "/plugins", filter)
        local err = assert_bad_response(res)
        assert.equals("foreign key violation", err.name)
        assert.same({ service = filter.service }, err.fields)
      end)
    end)

    describe("GET", function()
      it("returns both wasm filters and Lua plugins", function()
        local route_filter = new_filter()
        route_filter.route = { id = route.id }

        local service_filter = new_filter()
        service_filter.service = { id = service.id }

        local route_plugin = new_plugin()
        route_plugin.route = { id = route.id }

        local service_plugin = new_plugin()
        service_plugin.service = { id = service.id }

        route_filter = create_plugin(route_filter)
        service_filter = create_plugin(service_filter)

        route_plugin = create_plugin(route_plugin)
        service_plugin = create_plugin(service_plugin)

        local res = admin:get("/plugins")
        assert.response(res).has.status(200)
        local json = assert.response(res).has.jsonbody()
        assert.is_table(json)
        assert.is_table(json.data)

        local expected = 4
        assert.equals(expected, #json.data)
        local found = 0

        for _, plugin in ipairs(json.data) do
          if   plugin.id == route_filter.id
            or plugin.id == service_filter.id
            or plugin.id == route_plugin.id
            or plugin.id == service_plugin.id
          then
            found = found + 1
          end
        end

        assert.equals(expected, found, "GET /plugins didn't return expected entities")
      end)
    end)
  end)

  describe("/plugins/:id", function()
    local plugin
    local path

    before_each(function()
      local value = rand.random_string()
      local filter = new_filter(value)
      filter.route = { id = route.id }
      plugin = create_plugin(filter)
      path = "/plugins/" .. plugin.id
      check_filter_response(value, "POST /plugins")
    end)

    after_each(function()
      db.plugins:delete(plugin)
    end)

    describe("GET", function()
      it("retrieves a wasm filter plugin instance", function()
        local got = get_plugin("/plugins", plugin.id)
        assert.same(plugin, got)
      end)
    end)

    describe("PATCH", function()
      it("updates a wasm filter plugin instance", function()
        local value = rand.random_string()
        local updated = update_plugin(plugin.id, {
          config = cjson.encode(rt_config(FILTER_HEADER, value)),
        })

        assert.not_same(plugin, updated)
        check_filter_response(value, "PATCH /plugins/:id")
      end)
    end)

    describe("DELETE", function()
      it("removes a wasm filter plugin instance", function()
        local res = admin:delete(path)
        assert.response(res).has.status(204)

        res = admin:get(path)
        assert.response(res).status(404)
      end)
    end)
  end)

  describe("filter plugins and lua plugins", function()
    it("can coexist", function()
      local filter_value = rand.random_string()
      local filter = new_filter(filter_value)
      filter.route = { id = route.id }

      local plugin_value = rand.random_string()
      local plugin = new_plugin(plugin_value)
      plugin.route = { id = route.id }

      create_plugin(filter)
      create_plugin(plugin)

      helpers.wait_for_all_config_update()

      local res = proxy:get("/status/200")
      assert.response(res).has.status(200)

      assert.equals(filter_value, assert.response(res).has.header(FILTER_HEADER))
      assert.equals(plugin_value, assert.response(res).has.header(PLUGIN_HEADER))
    end)
  end)

  describe("filter plugins and filter chains", function()
    it("can coexist", function()
      local filter_value = rand.random_string()
      local filter = new_filter(filter_value)
      filter.route = { id = route.id }

      local fc_value = rand.random_string()
      local fc = new_filter_chain(fc_value)
      fc.route = { id = route.id }

      create_plugin(filter)
      create_filter_chain(fc)

      helpers.wait_for_all_config_update()

      local res = proxy:get("/status/200")
      assert.response(res).has.status(200)

      assert.equals(filter_value, assert.response(res).has.header(FILTER_HEADER))
      assert.equals(fc_value, assert.response(res).has.header(FILTER_CHAIN_HEADER))
    end)
  end)

  describe("order of execution", function()
    it("filter plugins execute at the end of any existing filter chain", function()
      local lua_plugin = {
        name = "response-transformer",
        route = { id = route.id },
        config = {
          add = {
            headers = {
              "X-Added-By-Lua-Plugin:1",
              "X-Replace-Me:lua",
              "X-Append-Me:lua",
              "X-Remove-Me:lua",
            },
          }
        }
      }

      local plugin = {
        name = "response_transformer",
        route = { id = route.id },
        config = cjson.encode({
          add = {
            headers = {
              "X-Added-First:plugin",
              "X-Added-By-Filter-Plugin:1",
              "X-Not-Removed-By-Filter-Chain:plugin",
            },
          },
          append = {
            headers = {
              "X-Append-Me:plugin",
            },
          },
          replace = {
            headers = {
              "X-Replace-Me:plugin",
              "X-Replaced-By-Filter-Plugin:plugin",
            },
          },
          remove = {
            headers = {
              "X-Remove-Me",
              "X-Removed-By-Filter-Plugin",
            },
          },
        }),
      }

      local res, header, assert_no_header
      do
        function header(name)
          return assert.response(res).has.header(name)
        end

        function assert_no_header(name)
          return assert.response(res).has.no.header(name)
        end
      end

      create_plugin(plugin)
      create_plugin(lua_plugin)

      helpers.wait_for_all_config_update()
      res = proxy:get("/status/200")
      assert.response(res).has.status(200)

      -- sanity
      assert.equals("1", header("X-Added-By-Filter-Plugin"))
      assert.equals("1", header("X-Added-By-Lua-Plugin"))
      assert_no_header("X-Remove-Me")

      assert.equals("plugin", header("X-Added-First"))

      -- added by Lua plugin, filter plugin appends
      assert.same({ "lua", "plugin" }, header("X-Append-Me"))

      -- replaced last by filter plugin
      assert.same("plugin", header("X-Replace-Me"))

      -- not replaced, because it was not added
      assert_no_header("X-Replaced-By-Filter-Plugin")

      local filter_chain = {
        route = { id = route.id },
        filters = {
          {
            name = "response_transformer",
            config = cjson.encode({
              add = {
                headers = {
                  "X-Added-First:filter-chain",
                  "X-Added-By-Filter-Chain:1",
                  "X-Removed-By-Filter-Plugin:filter-chain",
                  "X-Replaced-By-Filter-Plugin:filter-chain",
                },
              },
              append = {
                headers = {
                  "X-Append-Me:filter-chain",
                },
              },
              replace = {
                headers = {
                  "X-Replace-Me:filter-chain",
                  "X-Replaced-By-Filter-Chain:filter-chain",
                },
              },
              remove = {
                headers = {
                  "X-Not-Removed-By-Filter-Chain",
                },
              },
            }),
          }
        }
      }

      create_filter_chain(filter_chain)
      helpers.wait_for_all_config_update()
      res = proxy:get("/status/200")
      assert.response(res).has.status(200)

      -- sanity
      assert.equals("1", header("X-Added-By-Filter-Plugin"))
      assert.equals("1", header("X-Added-By-Lua-Plugin"))
      assert.equals("1", header("X-Added-By-Filter-Chain"))
      assert_no_header("X-Remove-Me")

      -- added first by the filter chain
      assert.equals("filter-chain", header("X-Added-First"))

      -- added by Lua, appended to by filter chain and filter plugin
      assert.same({ "lua", "filter-chain", "plugin" }, header("X-Append-Me"))
      -- added after the filter chain tried to remove it
      assert.same("plugin", header("X-Not-Removed-By-Filter-Chain"))

      -- replaced last by filter plugin
      assert.same("plugin", header("X-Replace-Me"))

      assert_no_header("X-Removed-By-Filter-Plugin")
      assert.same("plugin", header("X-Replaced-By-Filter-Plugin"))
    end)

    it("filter plugins execute in a consistent order", function()
      -- should always run first because `tests-01` < `tests-02`
      local plugin_1 = {
        name = "tests-01",
        config = "name=first",
        route = { id = route.id },
      }

      local plugin_2 = {
        name = "tests-02",
        config = "name=last",
        route = { id = route.id },
      }

      for _, order_added in ipairs({
        { plugin_1, plugin_2 },
        { plugin_2, plugin_1 },
      }) do
        bp.plugins:truncate()

        create_plugin(order_added[1])
        create_plugin(order_added[2])

        helpers.wait_for_all_config_update()
        local res = proxy:get("/status/200", {
          headers = {
            ["X-PW-Phase"] = "request_headers",
            ["X-PW-Test"] = "dump_config",
          }
        })

        local body = assert.res_status(200, res)
        assert.equals("name=first", body)
      end
    end)
  end)
end)

end -- each strategy
