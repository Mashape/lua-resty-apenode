local helpers = require "spec.helpers"
local uuid = require "kong.tools.uuid"

local fmt = string.format

local FILTER_PATH = assert(helpers.test_conf.wasm_filters_path)

local function json(body)
  return {
    headers = { ["Content-Type"] = "application/json" },
    body = body,
  }
end


-- no cassandra support
for _, strategy in helpers.each_strategy({ "postgres" }) do

describe("#wasm admin API [#" .. strategy .. "]", function()
  local admin
  local bp, db
  local service, route

  lazy_setup(function()
    require("kong.runloop.wasm").enable({
      { name = "tests",
        path = FILTER_PATH .. "/tests.wasm",
      },
      { name = "response_transformer",
        path = FILTER_PATH .. "/response_transformer.wasm",
      },
    })

    bp, db = helpers.get_db_utils(strategy, {
      "routes",
      "services",
      "filter_chains",
    })

    service = assert(db.services:insert {
      name = "wasm-test",
      url = "http://wasm.test",
    })

    route = assert(db.routes:insert {
      service = { id = service.id },
      hosts = { "wasm.test" },
      paths = { "/" },
    })


    assert(helpers.start_kong({
      database = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      wasm = true,
    }))


    admin = helpers.admin_client()
  end)

  lazy_teardown(function()
    if admin then admin:close() end
    helpers.stop_kong()
  end)


  local function reset_filter_chains()
    db.filter_chains:truncate()
  end


  local function unsupported(method, path)
    describe(method, function()
      it("is not supported", function()
        local res = assert(admin:send {
          method = method,
          path = path,
        })
        assert.response(res).has.status(405)
      end)
    end)
  end


  describe("/filter-chains", function()

    describe("POST", function()
      lazy_setup(reset_filter_chains)

      it("creates a filter chain", function()
        local res = admin:post("/filter-chains", json({
            filters = { { name = "tests" } },
            service = { id = service.id },
          })
        )

        assert.response(res).has.status(201)
        local body = assert.response(res).has.jsonbody()

        assert.is_string(body.id)
        assert.truthy(uuid.is_valid_uuid(body.id))

        assert.equals(1, #body.filters)
        assert.equals("tests", body.filters[1].name)
      end)
    end)

    describe("GET", function()
      lazy_setup(reset_filter_chains)

      it("returns a collection of filter chains", function()
        local res = admin:get("/filter-chains")
        assert.response(res).has.status(200)

        local body = assert.response(res).has.jsonbody()
        assert.same({ data = {}, next = ngx.null }, body)

        local chain = assert(bp.filter_chains:insert({
          filters = { { name = "tests" } },
          service = { id = service.id },
          tags = { "a" },
        }, { nulls = true }))

        res = admin:get("/filter-chains")
        assert.response(res).has.status(200)

        body = assert.response(res).has.jsonbody()
        assert.equals(1, #body.data, "unexpected number of filter chain entities")
        assert.same(chain, body.data[1])

        assert.response(
          admin:post("/filter-chains", json {
            filters = { { name = "tests" } },
            route = { id = route.id },
            tags = { "b" },
          })
        ).has.status(201)

        res = admin:get("/filter-chains")
        assert.response(res).has.status(200)

        body = assert.response(res).has.jsonbody()
        assert.equals(2, #body.data, "unexpected number of filter chain entities")
      end)
    end)

    unsupported("PATCH",  "/filter-chains")
    unsupported("PUT",    "/filter-chains")
    unsupported("DELETE", "/filter-chains")
  end)

  for _, key in ipairs({ "id", "name" }) do

  describe("/filter-chains/:" .. key, function()
    describe("GET", function()
      local chain

      lazy_setup(function()
        chain = bp.filter_chains:insert({
          service = assert(bp.services:insert({})),
          filters = { { name = "tests" } },
        }, { nulls = true })
      end)

      it("fetches a filter chain", function()
        local res = admin:get("/filter-chains/" .. chain[key])
        assert.response(res).has.status(200)
        local got = assert.response(res).has.jsonbody()
        assert.same(chain, got)
      end)

      it("returns 404 if not found", function()
        assert.response(
          admin:get("/filter-chains/" .. uuid.uuid())
        ).has.status(404)
      end)
    end)

    describe("PATCH", function()
      local chain

      lazy_setup(function()
        chain = bp.filter_chains:insert({
          service = assert(bp.services:insert({})),
          filters = { { name = "tests" } },
        }, { nulls = true })
      end)

      it("updates a filter chain in-place", function()
        assert.equals(ngx.null, chain.tags)
        assert.is_true(chain.enabled)

        local res = admin:patch("/filter-chains/" .. chain[key], json {
          tags = { "foo", "bar" },
          enabled = false,
          filters = {
            { name = "tests", config = "123", enabled = true },
            { name = "tests", config = "456", enabled = false },
          },
        })

        assert.response(res).has.status(200)
        local patched = assert.response(res).has.jsonbody()

        assert.same({ "foo", "bar" }, patched.tags)
        assert.is_false(patched.enabled)
        assert.equals(2, #patched.filters)
        assert.same({ name = "tests", config = "123", enabled = true },
                    patched.filters[1])
        assert.same({ name = "tests", config = "456", enabled = false },
                    patched.filters[2])
      end)
    end)

    describe("DELETE", function()
      local chain

      lazy_setup(function()
        chain = bp.filter_chains:insert({
          service = assert(bp.services:insert({})),
          filters = { { name = "tests" } },
        }, { nulls = true })
      end)

      it("removes a filter chain", function()
        local res = admin:delete("/filter-chains/" .. chain[key])
        assert.response(res).has.status(204)

        assert.response(
          admin:get("/filter-chains/" .. chain[key])
        ).has.status(404)
      end)

    end)

    unsupported("POST", "/filter-chains/" .. uuid.uuid())
  end)

  end -- each { "id", "name" }


  -- * /services/:service/filter-chains
  -- * /services/:service/filter-chains/:chain
  -- * /routes/:route/filter-chains
  -- * /routes/:route/filter-chains/:chain
  for _, rel in ipairs({ "service", "route" }) do

  describe(fmt("/%ss/:%s/filter-chains", rel, rel), function()
    local path, entity

    before_each(function()
      if rel == "service" then
        entity = assert(bp.services:insert({}))
      else
        entity = assert(bp.routes:insert({ hosts = { "wasm.test" } }))
      end

      path = fmt("/%ss/%s/filter-chains", rel, entity.id)
    end)

    describe("POST", function()
      it("creates a " .. rel .. " filter chain", function()
        local res = admin:post(path, json({
            filters = { { name = "tests" } },
          })
        )

        assert.response(res).has.status(201)
        local body = assert.response(res).has.jsonbody()

        assert.is_string(body.id)
        assert.truthy(uuid.is_valid_uuid(body.id))

        assert.equals(1, #body.filters)
        assert.equals("tests", body.filters[1].name)
      end)
    end)

    describe("GET", function()
      it("returns existing " .. rel .. " filter chains", function()
        local res = admin:get(path)
        assert.response(res).has.status(200)

        local body = assert.response(res).has.jsonbody()
        assert.same({ data = {}, next = ngx.null }, body)

        res = admin:post(path, json {
          filters = { { name = "tests" } },
          tags = { "a" },
        })

        assert.response(res).has.status(201)
        local chain = assert.response(res).has.jsonbody()

        res = admin:get(path)
        assert.response(res).has.status(200)

        body = assert.response(res).has.jsonbody()
        assert.equals(1, #body.data, "unexpected number of filter chain entities")
        assert.same(chain, body.data[1])
      end)
    end)

    unsupported("PATCH",  path)
    unsupported("PUT",    path)
    unsupported("DELETE", path)
  end)

  describe(fmt("/%ss/:%s/filter-chains/:chain", rel, rel), function()
    local path, entity
    local chain

    before_each(function()
      if rel == "service" then
        entity = assert(bp.services:insert({}))
        chain = assert(bp.filter_chains:insert({
          service = entity,
          filters = { { name = "tests" } },
        }, { nulls = true }))

      else
        entity = assert(bp.routes:insert({ hosts = { "wasm.test" } }))
        chain = assert(bp.filter_chains:insert({
          route = entity,
          filters = { { name = "tests" } },
        }, { nulls = true }))
      end

      path = fmt("/%ss/%s/filter-chains/", rel, entity.id)
    end)

    describe("GET", function()
      it("fetches a filter chain", function()
        local res = admin:get(path .. chain.id)
        assert.response(res).has.status(200)
        local got = assert.response(res).has.jsonbody()
        assert.same(chain, got)
      end)

      it("returns 404 if not found", function()
        assert.response(
          admin:get(path .. uuid.uuid())
        ).has.status(404)
      end)
    end)

    describe("PATCH", function()
      it("updates a filter chain in-place", function()
        assert.equals(ngx.null, chain.tags)
        assert.is_true(chain.enabled)

        local res = admin:patch(path .. chain.id, json {
          tags = { "foo", "bar" },
          enabled = false,
          filters = {
            { name = "tests", config = "123", enabled = true },
            { name = "tests", config = "456", enabled = false },
          },
        })

        assert.response(res).has.status(200)
        local patched = assert.response(res).has.jsonbody()

        assert.same({ "foo", "bar" }, patched.tags)
        assert.is_false(patched.enabled)
        assert.equals(2, #patched.filters)
        assert.same({ name = "tests", config = "123", enabled = true },
                    patched.filters[1])
        assert.same({ name = "tests", config = "456", enabled = false },
                    patched.filters[2])
      end)
    end)

    describe("DELETE", function()
      it("removes a filter chain", function()
        local res = admin:delete(path .. chain.id)
        assert.response(res).has.status(204)

        assert.response(
          admin:get(path .. chain.id)
        ).has.status(404)
      end)

    end)
  end)

  end -- each relation (service, route)

  local function build_filters_response_from_fixtures(mode, fcs)
    local filters = {}
    for _, fc in ipairs(fcs) do
      for _, f in ipairs(fc.filters) do
        if (mode == "all") or
           (f.enabled == true and mode == "enabled") or
           (f.enabled == false and mode == "disabled") then

          table.insert(filters, {
            config = f.config,
            enabled = f.enabled,
            filter_chain = {
              id = fc.id,
              name = fc.name,
            },
            from = (fc.service ~= ngx.null) and "service" or "route",
            name = f.name,
          })

        end
      end
    end
    return filters
  end

  describe("/routes/:routes/filters with chains from service and route", function()
    local path, service, route, fcs

    lazy_setup(function()
      reset_filter_chains()

      service = assert(bp.services:insert({}))
      route = assert(bp.routes:insert({
        hosts = { "wasm.test" },
        service = { id = service.id },
      }))

      fcs = {
        assert(bp.filter_chains:insert({
          filters = {
            { name = "tests", config = nil, enabled = true },
            { name = "response_transformer", config = "{}", enabled = false },
          },
          service = { id = service.id },
          name = "fc1",
        }, { nulls = true })),

        assert(bp.filter_chains:insert({
          filters = {
            { name = "tests", config = ngx.null, enabled = false },
            { name = "response_transformer", config = ngx.null, enabled = true }
          },
          route = { id = route.id },
        }, { nulls = true })),
      }

      path = fmt("/routes/%s/filters", route.id)
    end)

    for _, mode in ipairs({"enabled", "disabled", "all"}) do
      it(fmt("/routes/:routes/filters/%s GET returns 200", mode), function()
        local filters = build_filters_response_from_fixtures(mode, fcs)
        assert.equal(mode == "all" and 4 or 2, #filters)

        local res = admin:get(fmt("%s/%s", path, mode))
        assert.response(res).has.status(200)
        local got = assert.response(res).has.jsonbody()
        assert.same({ filters = filters }, got)
      end)
    end
  end)

  describe("/routes/:routes/filters with chains from service only", function()
    local path, service, route, fcs

    lazy_setup(function()
      reset_filter_chains()

      service = assert(bp.services:insert({}))
      route = assert(bp.routes:insert({
        hosts = { "wasm.test" },
        service = { id = service.id },
      }))

      fcs = {
        assert(bp.filter_chains:insert({
          filters = {
            { name = "tests", enabled = true },
            { name = "response_transformer", config = "{}", enabled = false },
          },
          service = { id = service.id },
          name = "fc1",
        }, { nulls = true })),
      }

      path = fmt("/routes/%s/filters", route.id)
    end)

    for _, mode in ipairs({"enabled", "disabled", "all"}) do
      it(fmt("/routes/:routes/filters/%s GET returns 200", mode), function()
        local filters = build_filters_response_from_fixtures(mode, fcs)
        assert.equal(mode == "all" and 2 or 1, #filters)

        local res = admin:get(fmt("%s/%s", path, mode))
        assert.response(res).has.status(200)
        local got = assert.response(res).has.jsonbody()
        assert.same({ filters = filters }, got)
      end)
    end
  end)

  describe("/routes/:routes/filters with chains from route only", function()
    local path, service, route, fcs

    lazy_setup(function()
      reset_filter_chains()

      service = assert(bp.services:insert({}))
      route = assert(bp.routes:insert({
        hosts = { "wasm.test" },
        service = { id = service.id },
      }))

      fcs = {
        assert(bp.filter_chains:insert({
          filters = {
            { name = "tests", enabled = true },
            { name = "response_transformer", config = "{}", enabled = false },
            { name = "tests", enabled = true },
          },
          route = { id = route.id },
          name = "fc1",
        }, { nulls = true })),
      }

      path = fmt("/routes/%s/filters", route.id)
    end)

    for _, mode in ipairs({"enabled", "disabled", "all"}) do
      it(fmt("/routes/:routes/filters/%s GET returns 200", mode), function()
        local filters = build_filters_response_from_fixtures(mode, fcs)
        assert.equal(mode == "all" and 3
                     or mode == "enabled" and 2
                     or mode == "disabled" and 1, #filters)

        local res = admin:get(fmt("%s/%s", path, mode))
        assert.response(res).has.status(200)
        local got = assert.response(res).has.jsonbody()
        assert.same({ filters = filters }, got)
      end)
    end
  end)
end)

describe("#wasm admin API - wasm = off [#" .. strategy .. "]", function()
  local admin
  local bp, db
  local service

  lazy_setup(function()
    bp, db = helpers.get_db_utils(strategy, {
      "routes",
      "services",
    })

    service = assert(db.services:insert {
      name = "wasm-test",
      url = "http://wasm.test",
    })

    assert(helpers.start_kong({
      database = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      wasm = "off",
    }))

    admin = helpers.admin_client()
  end)

  lazy_teardown(function()
    if admin then admin:close() end
    helpers.stop_kong()
  end)

  describe("/filter-chains", function()

    describe("POST", function()
      it("returns 400", function()
        local res = admin:post("/filter-chains", json({
            filters = { { name = "tests" } },
            service = { id = service.id },
          })
        )

        assert.response(res).has.status(400)
      end)
    end)

    describe("GET", function()
      it("returns 400", function()
        local res = admin:get("/filter-chains")
        assert.response(res).has.status(400)
      end)
    end)

    describe("PATCH", function()
      it("returns 400", function()
        local res = admin:patch("/filter-chains/a-name", json {
          tags = { "foo", "bar" },
          enabled = false,
          filters = {
            { name = "tests", config = "123", enabled = true },
            { name = "tests", config = "456", enabled = false },
          },
        })
        assert.response(res).has.status(400)
      end)
    end)

    describe("PUT", function()
      it("returns 400", function()
        local res = admin:put("/filter-chains/another-name", json {
          tags = { "foo", "bar" },
          enabled = false,
          filters = {
            { name = "tests", config = "123", enabled = true },
            { name = "tests", config = "456", enabled = false },
          },
        })
        assert.response(res).has.status(400)
      end)
    end)

    describe("DELETE", function()
      it("returns 400", function()
        local res = admin:delete("/filter-chains/even-another-name")
        assert.response(res).has.status(400)
      end)
    end)

  end)

  -- * /services/:service/filter-chains
  -- * /services/:service/filter-chains/:chain
  -- * /routes/:route/filter-chains
  -- * /routes/:route/filter-chains/:chain
  for _, rel in ipairs({ "service", "route" }) do

  describe(fmt("/%ss/:%s/filter-chains", rel, rel), function()
    local path, entity

    before_each(function()
      if rel == "service" then
        entity = assert(bp.services:insert({}))
      else
        entity = assert(bp.routes:insert({ hosts = { "wasm.test" } }))
      end

      path = fmt("/%ss/%s/filter-chains", rel, entity.id)
    end)

    it("GET returns 400", function()
      assert.response(
        admin:get(path)
      ).has.status(400)
    end)

    it("POST returns 400", function()
      assert.response(
        admin:post(path, json({
            filters = { { name = "tests" } },
            service = { id = service.id },
          })
        )
      ).has.status(400)
    end)

    it("PATCH returns 400", function()
      assert.response(
        admin:patch(path .. "/" .. uuid.uuid()), json({
          filters = { { name = "tests" } },
          service = { id = service.id },
        })
      ).has.status(400)
    end)

    it("PUT returns 400", function()
      assert.response(
        admin:put(path .. "/" .. uuid.uuid()), json({
          filters = { { name = "tests" } },
          service = { id = service.id },
        })
      ).has.status(400)
    end)

    it("DELETE returns 400", function()
      assert.response(
        admin:delete(path .. "/" .. uuid.uuid())
      ).has.status(400)
    end)

  end)

  end -- each relation (service, route)

  for _, mode in ipairs({"enabled", "disabled", "all"}) do

  describe(fmt("/routes/:routes/filters/%s", mode), function()
    local path, route

    before_each(function()
      route = assert(bp.routes:insert({ hosts = { "wasm.test" } }))
      path = fmt("/routes/%s/filters/%s", route.id, mode)
    end)

    it("GET returns 400", function()
      assert.response(
        admin:get(path)
      ).has.status(400)
    end)
  end)

  end -- each mode (enabled, disabled, all)

end)

end -- each strategy
