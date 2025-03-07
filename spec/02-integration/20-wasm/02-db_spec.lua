local helpers = require "spec.helpers"
local uuid = require "kong.tools.uuid"
local schema_lib = require "kong.db.schema.json"

local FILTER_PATH = assert(helpers.test_conf.wasm_filters_path)

-- no cassandra support
for _, strategy in helpers.each_strategy({ "postgres" }) do

describe("#wasm DB entities [#" .. strategy .. "]", function()
  local db

  local function reset_db()
    if not db then return end
    db.filter_chains:truncate()
    db.routes:truncate()
    db.services:truncate()
    db.workspaces:truncate()
  end


  lazy_setup(function()
    require("kong.runloop.wasm").enable({
      { name = "test",
        path = FILTER_PATH .. "/test.wasm",
      },
      { name = "other",
        path = FILTER_PATH .. "/other.wasm",
      },
    })

    local _
    _, db = helpers.get_db_utils(strategy, {
      "workspaces",
      "routes",
      "services",
      "filter_chains",
    })
  end)

  lazy_teardown(reset_db)

  describe("filter_chains", function()
    local dao

    lazy_setup(function()
      dao = db.filter_chains
    end)

    local function make_service()
      local service = assert(db.services:insert({
        url = "http://wasm.test/",
      }))
      return { id = service.id }
    end

    describe(".id", function()
      it("is auto-generated", function()
        local chain = assert(dao:insert({
          id = nil,
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_string(chain.id)
        assert.truthy(uuid.is_valid_uuid(chain.id))
      end)

      it("can be user-generated", function()
        local id = uuid.uuid()
        local chain = assert(dao:insert({
          id = id,
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_string(chain.id)
        assert.equals(id, chain.id)
        assert.truthy(uuid.is_valid_uuid(chain.id))
      end)

      it("must be a valid uuid", function()
        local chain, err, err_t = dao:insert({
          id = "nope!",
          service = make_service(),
          filters = { { name = "test" } },
        })

        assert.is_nil(chain, err)
        assert.is_string(err)
        assert.is_table(err_t)

        assert.same({ id = "expected a valid UUID" }, err_t.fields)
        assert.equals("schema violation", err_t.name)
      end)
    end)

    describe(".name", function()
      it("is optional", function()
        local chain = assert(dao:insert({
          name = nil,
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_nil(chain.name)
      end)

      it("must be unique", function()
        local name = "my-unique-filter"

        assert(dao:insert({
          name = name,
          service = make_service(),
          filters = { { name = "test" } },
        }))

        local other, err, err_t = dao:insert({
          name = name,
          service = make_service(),
          filters = { { name = "test" } },
        })

        assert.is_string(err)
        assert.is_table(err_t)
        assert.is_nil(other)

        assert.equals("unique constraint violation", err_t.name)
        assert.same({ name = name }, err_t.fields)
      end)
    end)

    describe(".enabled", function()
      it("defaults to 'true'", function()
        local chain = assert(dao:insert({
          enabled = nil,
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_true(chain.enabled)
      end)

      it("must be a boolean", function()
        local chain, err, err_t = dao:insert({
          enabled = "nope!",
          service = make_service(),
          filters = { { name = "test" } },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)

        assert.equals("schema violation", err_t.name)
        assert.same({ enabled = "expected a boolean" }, err_t.fields)
      end)
    end)

    describe(".route", function()
      it("references a route", function()
        local route = assert(db.routes:insert({
          protocols = { "http" },
          methods = { "GET" },
          paths = { "/" },
        }))

        local chain, err = dao:insert({
          filters = { { name = "test" } },
          route = { id = route.id },
        })

        assert.is_table(chain, err)
        assert.is_nil(err)
        assert.equals(route.id, chain.route.id)
      end)

      it("requires the route to exist", function()
        local chain, err, err_t = dao:insert({
          filters = { { name = "test" } },
          route = { id = uuid.uuid() },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)

        assert.equals("foreign key violation", err_t.name)
        assert.is_table(err_t.fields)
        assert.is_table(err_t.fields.route)
      end)
    end)

    describe(".service", function()
      it("references a service", function()
        local service = assert(db.services:insert({
          url = "http://wasm.test/",
        }))

        local chain, err = dao:insert({
          filters = { { name = "test" } },
          service = { id = service.id },
        })

        assert.is_table(chain, err)
        assert.is_nil(err)
        assert.equals(service.id, chain.service.id)
      end)

      it("requires the service to exist", function()
        local chain, err, err_t = dao:insert({
          filters = { { name = "test" } },
          service = { id = uuid.uuid() },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)

        assert.equals("foreign key violation", err_t.name)
        assert.is_table(err_t.fields)
        assert.is_table(err_t.fields.service)
      end)
    end)

    describe(".created_at", function()
      it("is auto-generated", function()
        local chain = assert(dao:insert({
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_number(chain.created_at)
        assert.truthy(math.abs(ngx.now() - chain.created_at) < 5)
      end)
    end)

    describe(".updated_at", function()
      it("is updated when the entity is updated", function()
        local chain = assert(dao:insert({
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_number(chain.updated_at)

        helpers.wait_until(function()
          local updated = assert(dao:update(
            { id = chain.id },
            { tags = { uuid.uuid() } }
          ))

          return updated.updated_at > chain.updated_at
        end, 5, 0.1)
      end)
    end)

    describe(".tags", function()
      it("has tags", function()
        local chain = assert(dao:insert({
          service = make_service(),
          filters = { { name = "test" } },
        }))

        assert.is_nil(chain.tags)

        chain = assert(dao:update(chain, { tags = { "foo" } }))
        assert.same({ "foo" }, chain.tags)
      end)
    end)

    describe(".filters", function()
      it("are required", function()
        local chain, err, err_t = dao:insert({
          service = make_service(),
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)
        assert.same({ filters = "required field missing" }, err_t.fields)
      end)

      it("cannot be empty", function()
        local chain, err, err_t = dao:insert({
          service = make_service(),
          filters = {},
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)
        assert.same({ filters = "length must be at least 1" }, err_t.fields)
      end)

      describe(".name", function()
        it("is required", function()
          local chain, err, err_t = dao:insert({
            service = make_service(),
            filters = { { config = "config" } },
          })

          assert.is_nil(chain)
          assert.is_string(err)
          assert.is_table(err_t)
          assert.is_table(err_t.fields)
          assert.is_table(err_t.fields.filters)
          assert.same({ [1] = { name = "required field missing" } }, err_t.fields.filters)
        end)

        it("must be a valid, enabled filter name", function()
          local chain, err, err_t = dao:insert({
            service = make_service(),
            filters = {
              { name = "test" },
              { name = "missing" },
              { name = "other" },
              { name = "also-missing" },
            },
          })

          assert.is_nil(chain)
          assert.is_string(err)
          assert.is_table(err_t)
          assert.is_table(err_t.fields)
          assert.same({
            filters = {
              [2] = { name = "no such filter" },
              [4] = { name = "no such filter" },
            },
          }, err_t.fields)

          assert(dao:insert({
            service = make_service(),
            filters = { { name = "test" } },
          }))

          chain, err, err_t = dao:insert({
            service = make_service(),
            filters = {
              { name = "test" },
              { name = "missing" },
              { name = "other" },
              { name = "also-missing" },
            },
          })

          assert.is_nil(chain)
          assert.is_string(err)
          assert.is_table(err_t)
          assert.is_table(err_t.fields)
          assert.same({
            filters = {
              [2] = { name = "no such filter" },
              [4] = { name = "no such filter" },
            },
          }, err_t.fields)

        end)
      end)

      describe(".enabled", function()
        it("defaults to 'true'", function()
          local chain = assert(dao:insert({
            service = make_service(),
            filters = { { name = "test" } },
          }))

          assert.is_true(chain.filters[1].enabled)
        end)
      end)

      describe(".config", function()
        local schema_name = "proxy-wasm-filters/test"

        lazy_teardown(function()
          schema_lib.remove_schema(schema_name)
        end)

        it("is an optional string when no json schema exists", function()
          local service = assert(db.services:insert({
            url = "http://example.test",
          }))

          assert.truthy(dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = nil,
              }
            }
          }))

          service = assert(db.services:insert({
            url = "http://example.test",
          }))

          assert.truthy(dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = "my config",
              }
            }
          }))

          assert.falsy(dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = 123,
              }
            }
          }))

          assert.falsy(dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = true,
              }
            }
          }))

          assert.falsy(dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = { a = 1, b = 2 },
              }
            }
          }))
        end)

        it("is validated against user schema", function()
          local service = assert(db.services:insert({
            url = "http://example.test",
          }))

          schema_lib.add_schema(schema_name, {
            type = "object",
            properties = {
              foo = { type = "string" },
              bar = { type = "object" },
            },
            required = { "foo", "bar" },
            additionalProperties = false,
          })

          assert.truthy(dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = {
                  foo = "foo string",
                  bar = { a = 1, b = 2 },
                },
              }
            }
          }))

          service = assert(db.services:insert({
            url = "http://example.test",
          }))

          local chain, err = dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = {
                  foo = 123,
                  bar = { a = 1, b = 2 },
                },
              }
            }
          })
          assert.is_nil(chain)
          assert.matches("property foo validation failed", err)

          service = assert(db.services:insert({
            url = "http://example.test",
          }))

          chain, err = dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = ngx.null,
              }
            }
          })
          assert.is_nil(chain)
          assert.matches("expected object, got null", err)

          service = assert(db.services:insert({
            url = "http://example.test",
          }))

          chain, err = dao:insert({
            service = { id = service.id },
            filters = {
              {
                name = "test",
                config = nil,
              }
            }
          })
          assert.is_nil(chain)
          assert.matches("expected object, got null", err)

        end)
      end)
    end)

    describe("entity checks", function()
      it("service and route are mutually exclusive", function()
        local route = assert(db.routes:insert({
          protocols = { "http" },
          methods = { "GET" },
          paths = { "/" },
        }))

        local service = assert(db.services:insert({
          url = "http://example.test",
        }))


        local chain, err, err_t = dao:insert({
          route = { id = route.id },
          service = { id = service.id },
          filters = { { name = "test" } },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)
        assert.same({
          ["@entity"] = {
            "only one or none of these fields must be set: 'service', 'route'",
          },
        }, err_t.fields)
      end)

      it("allows only one chain per service", function()
        local service = assert(db.services:insert({
          url = "http://example.test",
        }))

        assert(dao:insert({
          service = { id = service.id },
          filters = { { name = "test" } },
          tags = { "original" },
        }))

        local chain, err, err_t = dao:insert({
          service = { id = service.id },
          filters = { { name = "test" } },
          tags = { "new" },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)
        assert.equals("unique constraint violation", err_t.name)
        assert.is_table(err_t.fields.service)
      end)

      it("allows only one chain per route", function()
        local route = assert(db.routes:insert({
          protocols = { "http" },
          methods = { "GET" },
          paths = { "/" },
        }))


        assert(dao:insert({
          route = { id = route.id },
          filters = { { name = "test" } },
          tags = { "original" },
        }))

        local chain, err, err_t = dao:insert({
          route = { id = route.id },
          filters = { { name = "test" } },
          tags = { "new" },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)
        assert.equals("unique constraint violation", err_t.name)
        assert.is_table(err_t.fields.route)
      end)

      it("requires a service or a route", function()
        local chain, err, err_t = dao:insert({
          filters = { { name = "test" } },
        })

        assert.is_nil(chain)
        assert.is_string(err)
        assert.is_table(err_t)
        assert.is_table(err_t.fields)
        assert.same(
          {
            ["@entity"] = {
              [1] = [[at least one of these fields must be non-empty: 'service', 'route']]
            },
          },
          err_t.fields
        )
      end)
    end)
  end)
end)

end -- each strategy
