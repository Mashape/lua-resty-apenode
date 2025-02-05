local helpers = require "spec.helpers"
local cjson = require "cjson"


local function post_config(client, config)
  config._format_version = config._format_version or "3.0"

  local res = client:post("/config?flatten_errors=1", {
    body = config,
    headers = {
      ["Content-Type"] = "application/json"
    },
  })

  assert.response(res).has.jsonbody()

  assert.logfile().has.no.line("[emerg]", true, 0)
  assert.logfile().has.no.line("[crit]",  true, 0)
  assert.logfile().has.no.line("[alert]", true, 0)
  assert.logfile().has.no.line("[error]", true, 0)
  assert.logfile().has.no.line("[warn]",  true, 0)

  return res
end


local function expect_entity_error(res, err)
  assert.response(res).has.status(400)

  local json = assert.response(res).has.jsonbody()
  assert.is_table(json.flattened_errors)

  local found = false


  for _, entity in ipairs(json.flattened_errors) do
    assert.is_table(entity.errors)
    for _, elem in ipairs(entity.errors) do
      if elem.type == "entity" then
        assert.same(err, elem.message)
        found = true
        break
      end
    end
  end

  assert.is_true(found, "expected '" .. err .. "' message in response")
end

local function expect_field_error(res, field, err)
  assert.response(res).has.status(400)

  local json = assert.response(res).has.jsonbody()
  assert.is_table(json.flattened_errors)

  local found = false

  for _, entity in ipairs(json.flattened_errors) do
    assert.is_table(entity.errors)
    for _, elem in ipairs(entity.errors) do
      if elem.type == "field"
        and elem.field == field
        and elem.message == err
      then
        found = true
        break
      end
    end
  end

  assert.is_true(found, "expected '" .. err .. "' for field " .. field .. " in response")
end


describe("#wasm declarative config (db = #off)", function()
  local admin
  local proxy
  local header_name = "x-wasm-dbless"

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      wasm = true,
    }))

    admin = helpers.admin_client()
    proxy = helpers.proxy_client()
  end)

  lazy_teardown(function()
    if admin then admin:close() end
    if proxy then proxy:close() end
    helpers.stop_kong()
  end)

  it("permits valid filter chain entities", function()
    local res = post_config(admin, {
      services = {
        { name = "test",
          url = helpers.mock_upstream_url,
          routes = {
            { name = "test",
              hosts = { "wasm.test" }
            },
          },
          filter_chains = {
            { name = "test",
              filters = {
                { name = "response_transformer",
                  config = cjson.encode {
                    append = {
                      headers = {
                        header_name .. ":hello!"
                      },
                    },
                  },
                }
              },
            },
          },
        },
      },
    })

    assert.response(res).has.status(201)

    assert
      .eventually(function()
        res = proxy:get("/status/200", {
          headers = { host = "wasm.test" },
        })

        res:read_body()

        if res.status ~= 200 then
          return nil, { exp = 200, got = res.status }
        end

        local header = res.headers[header_name]

        if header == nil then
          return nil, header_name ..  " header not present in the response"

        elseif header ~= "hello!" then
          return nil, { exp = "hello!", got = header }
        end

        return true
      end)
      .is_truthy("filter-chain created by POST /config is active")
  end)

  it("rejects filter chains with non-existent filters", function()
    local res = post_config(admin, {
      services = {
        { name = "test",
          url = "http://wasm.test/",
          filter_chains = {
            { name = "test",
              filters = {
                { name = "i_do_not_exist" }
              },
            },
          },
        },
      },
    })

    expect_field_error(res, "filters.1.name", "no such filter")
  end)
end)


describe("#wasm declarative config (no installed filters) (db = #off)", function()
  local tmp_dir

  lazy_setup(function()
    tmp_dir = helpers.make_temp_dir()
  end)

  lazy_teardown(function()
    helpers.dir.rmtree(tmp_dir)
  end)

  describe("POST /config", function()
    local client

    lazy_setup(function()
      assert(helpers.start_kong({
        database = "off",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = true,
        wasm_filters_path = tmp_dir,
        wasm_filters = "user",
      }))

      client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if client then client:close() end
      helpers.stop_kong()
    end)

    it("warns clients that no filters are installed", function()
      local res = post_config(client, {
        services = {
          { name = "test",
            url = "http://wasm.test/",
            filter_chains = {
              { name = "test",
                filters = {
                  { name = "i_do_not_exist" }
                },
              },
            },
          },
        },
      })

      expect_entity_error(res, "no wasm filters are available")
    end)
  end)

  describe("kong start", function()
    local kong_yaml

    lazy_teardown(function()
      if kong_yaml then
        helpers.file.delete(kong_yaml)
      end
    end)

    it("fails when attempting to use a filter chain", function()
      kong_yaml = helpers.make_yaml_file([[
        _format_version: "3.0"
        services:
          - name: test
            url: http://127.0.0.1/
            routes:
              - name: test
                hosts:
                  - wasm.test
            filter_chains:
              - name: test
                filters:
                  - name: i_do_not_exist
      ]])

      local ok, err = helpers.start_kong({
        database = "off",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = true,
        wasm_filters_path = tmp_dir,
        wasm_filters = "user",
        declarative_config = kong_yaml,
      })

      assert.falsy(ok)
      assert.is_string(err)
      assert.matches("no wasm filters are available", err)
    end)

  end)
end)

describe("#wasm declarative config (wasm = off) (db = #off)", function()
  describe("POST /config", function()
    local client

    lazy_setup(function()
      assert(helpers.start_kong({
        database = "off",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = "off",
      }))

      client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if client then client:close() end
      helpers.stop_kong()
    end)

    it("warns clients that wasm is disabled", function()
      local res = post_config(client, {
        services = {
          { name = "test",
            url = "http://wasm.test/",
            filter_chains = {
              { name = "test",
                filters = {
                  { name = "i_do_not_exist" }
                },
              },
            },
          },
        },
      })

      expect_entity_error(res, "wasm support is not enabled")
    end)
  end)

  describe("kong start", function()
    local kong_yaml

    lazy_teardown(function()
      if kong_yaml then
        helpers.file.delete(kong_yaml)
      end
    end)

    it("fails when attempting to use a filter chain", function()
      kong_yaml = helpers.make_yaml_file([[
        _format_version: "3.0"
        services:
          - name: test
            url: http://127.0.0.1/
            routes:
              - name: test
                hosts:
                  - wasm.test
            filter_chains:
              - name: test
                filters:
                  - name: i_do_not_exist
      ]])

      local ok, err = helpers.start_kong({
        database = "off",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = "off",
        declarative_config = kong_yaml,
      })

      assert.falsy(ok)
      assert.is_string(err)
      assert.matches("wasm support is not enabled", err)
    end)
  end)
end)
