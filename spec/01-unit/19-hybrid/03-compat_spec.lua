local compat = require("kong.clustering.compat")
local helpers = require ("spec.helpers")
local declarative = require("kong.db.declarative")
local inflate_gzip = require("kong.tools.gzip").inflate_gzip
local cjson_decode = require("cjson.safe").decode
local cjson_encode = require("cjson.safe").encode
local ssl_fixtures = require ("spec.fixtures.ssl")
local merge = kong.table.merge

local function reset_fields()
  compat._set_removed_fields(require("kong.clustering.compat.removed_fields"))
end

describe("kong.clustering.compat", function()
  -- The truncate() in the following teardown() will clean all tables' records,
  -- which may cause some other tests to fail because the number of records
  -- in the truncated table differs from the number of records after bootstrap.
  -- So we need this to reset schema.
  lazy_teardown(function()
    if _G.kong.db then
      _G.kong.db:schema_reset()
    end
  end)

  describe("calculating fields to remove", function()
    before_each(reset_fields)
    after_each(reset_fields)

    it("merges multiple versions together", function()
      compat._set_removed_fields({
        [200] = {
          my_plugin = {
            "a",
            "c",
          },
          my_other_plugin = {
            "my_field",
          },
        },
        [300] = {
          my_plugin = {
            "b",
          },
          my_other_plugin = {
            "my_extra_field",
          },
          my_third_plugin = {
            "my_new_field",
          },
        },
      })

      assert.same(
        {
          my_plugin = {
            "a",
            "b",
            "c",
          },
          my_other_plugin = {
            "my_extra_field",
            "my_field",
          },
          my_third_plugin = {
            "my_new_field",
          },
        },
        compat._get_removed_fields(100)
      )
    end)

    it("memoizes the result", function()
      compat._set_removed_fields({
        [200] = {
          my_plugin = {
            "a",
            "c",
          },
          my_other_plugin = {
            "my_field",
          },
        },
        [300] = {
          my_plugin = {
            "b",
          },
          my_other_plugin = {
            "my_extra_field",
          },
          my_third_plugin = {
            "my_new_field",
          },
        },
      })

      local fields = compat._get_removed_fields(100)
      -- sanity
      assert.same(
        {
          my_plugin = {
            "a",
            "b",
            "c",
          },
          my_other_plugin = {
            "my_extra_field",
            "my_field",
          },
          my_third_plugin = {
            "my_new_field",
          },
        },
        fields
      )

      local other = compat._get_removed_fields(100)
      assert.equals(fields, other)

      fields = compat._get_removed_fields(200)
      assert.same(
        {
          my_plugin = {
            "b",
          },
          my_other_plugin = {
            "my_extra_field",
          },
          my_third_plugin = {
            "my_new_field",
          },
        },
        fields
      )

      other = compat._get_removed_fields(200)
      assert.equals(fields, other)
    end)

  end)

  describe("update_compatible_payload()", function()
    local test_with

    lazy_setup(function()
      test_with = function(plugins, dp_version)
        local has_update, new_conf = compat.update_compatible_payload(
          { config_table = { plugins = plugins } }, dp_version, ""
        )

        if has_update then
          new_conf = cjson_decode(inflate_gzip(new_conf))
          return new_conf.config_table.plugins
        end

        return plugins
      end

      compat._set_removed_fields({
        [2000000000] = {
          my_plugin = {
            "delete_me",
          }
        },
        [3000000000] = {
          my_plugin = {
            "delete_me_too",
          },
          other_plugin = {
            "goodbye",
            "my.nested.field",
          },
          session = {
            "anything",
          },
        },
      })
    end)

    lazy_teardown(reset_fields)

    local cases = {
      {
        name = "empty",
        version = "3.0.0",
        plugins = {},
        expect = {}
      },

      {
        name = "merged",
        version = "1.0.0",
        plugins = {
          {
            name = "my-plugin",
            config = {
              do_not_delete = true,
              delete_me = false,
              delete_me_too = ngx.null,
            },
          },
          {
            name = "other-plugin",
            config = {
              hello = { a = 1 },
            },
          },
        },
        expect = {
          {
            name = "my-plugin",
            config = {
              do_not_delete = true,
            },
          },
          {
            name = "other-plugin",
            config = {
              hello = { a = 1 },
            },
          },
        },
      },

      {
        name = "nested fields",
        version = "1.0.0",
        plugins = {
          {
            name = "other-plugin",
            config = {
              do_not_delete = 1,
              my = 123,
            },
          },

          {
            name = "other-plugin",
            config = {
              do_not_delete = 1,
              my = {
                nested = "not a table",
              },
            },
          },

          {
            name = "other-plugin",
            config = {
              do_not_delete = 1,
              my = {
                nested = {
                  field = "this one",
                  stay = "I'm still here",
                }
              },
            },
          },
        },
        expect = {
          {
            name = "other-plugin",
            config = {
              do_not_delete = 1,
              my = 123,
            },
          },

          {
            name = "other-plugin",
            config = {
              do_not_delete = 1,
              my = {
                nested = "not a table",
              },
            },
          },

          {
            name = "other-plugin",
            config = {
              do_not_delete = 1,
              my = {
                nested = {
                  -- deleted
                  -- field = "this one",
                  stay = "I'm still here",
                }
              },
            },
          },
        },
      },

      {
        name = "renamed fields",
        version = "1.0.0",
        plugins = {
          {
            name = "session",
            config = {
              idling_timeout = 60,
              rolling_timeout = 60,
              stale_ttl = 60,
              cookie_same_site = "Default",
              cookie_http_only = false,
              remember = true,
            },
          },
        },
        expect = {
          {
            name = "session",
            config = {
              cookie_idletime = 60,
              cookie_lifetime = 60,
              cookie_discard = 60,
              cookie_samesite = "Lax",
              cookie_httponly = false,
              cookie_persistent = true,
            },
          },
        },
      },
    }

    for _, case in ipairs(cases) do
      it(case.name, function()
        local result = test_with(case.plugins, case.version)
        assert.same(case.expect, result)
      end)
    end
  end)

  describe("check_kong_version_compatibility()", function()
    local check = compat.check_kong_version_compatibility

    it("permits matching major and minor versions", function()
      assert.truthy(check("1.1.2", "1.1.2"))
      assert.truthy(check("1.1.999", "1.1.2222"))
    end)

    it("permits the DP minor version to be less than the CP", function()
      assert.truthy(check("1.2.0", "1.1.0"))
      assert.truthy(check("1.9999.0", "1.1.33"))
    end)

    it("forbids mismatching major versions", function()
      assert.falsy(check("1.0.0", "2.0.0"))
      assert.falsy(check("2.0.0", "1.0.0"))
    end)

    it("forbids a DP minor version higher than the CP minor version", function()
      assert.falsy(check("1.0.0", "1.1.0"))
    end)
  end)


  for _, strategy in helpers.each_strategy() do

    describe("[#" .. strategy .. "]: check compat for entities those have `updated_at` field", function()
      local bp, db, entity_names

      setup(function()
        -- excludes entities not exportable: clustering_data_planes,
        entity_names = {
          "services",
          "routes",
          "ca_certificates",
          "certificates",
          "consumers",
          "targets",
          "upstreams",
          "plugins",
          "workspaces",
          "snis",
        }

        local plugins_enabled = { "key-auth" }
        bp, db = helpers.get_db_utils(strategy, entity_names, plugins_enabled)

        for _, name in ipairs(entity_names) do
          if name == "plugins" then
            local plugin = {
              name = "key-auth",
              config = {
                -- key_names has default value so we don't have to provide it
                -- key_names = {}
              }
            }
            bp[name]:insert(plugin)
          elseif name == "routes" then
            bp[name]:insert({ hosts = { "test1.test" }, })
          else
            bp[name]:insert()
          end
        end
      end)

      teardown(function()
        for _, entity_name in ipairs(entity_names) do
          db[entity_name]:truncate()
        end
      end)

      it("has_update", function()
        local config = { config_table = declarative.export_config() }
        local has_update = compat.update_compatible_payload(config, "3.0.0", "test_")
        assert.truthy(has_update)
      end)
  end)
  end

  describe("core entities compatible changes", function()
    local config, db

    lazy_setup(function()
      local _
      _, db = helpers.get_db_utils(nil, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "upstreams",
        "keys",
      })
      _G.kong.db = db

      local certificate_def = {
        _tags = ngx.null,
        created_at = 1541088353,
        id = "f6c12564-47c8-48b4-b171-0a0d9dbf7cb0",
        cert  = ssl_fixtures.cert,
        key   = ssl_fixtures.key,
      }

      local ca_certificate_def = {
        _tags = ngx.null,
        created_at = 1541088353,
        id = "f6c12564-47c8-48b4-b171-0a0d9dbf7cb1",
        cert  = ssl_fixtures.cert_ca,
      }

      local jwk_pub, jwk_priv = helpers.generate_keys("JWK")
      local pem_pub, pem_priv = helpers.generate_keys("PEM")
      local jwk = merge(cjson_decode(jwk_pub), cjson_decode(jwk_priv))
      jwk.x5t = "x5t1"


      assert(declarative.load_into_db({
        ca_certificates = { [ca_certificate_def.id] = ca_certificate_def },
        certificates = { [certificate_def.id] = certificate_def },
        keys = {
          key1 = {
            id = "f0383152-a6b4-4351-983b-1844b14170c1",
            kid = jwk.kid,
            name = "key1",
            x5t = jwk.x5t,
            jwk = cjson_encode(jwk)
          },
          key2 = {
            id = "f0383152-a6b4-4351-983b-1844b14170c2",
            kid = "kid2",
            name = "key2",
            x5t = "x5t2",
            pem = {
              public_key = pem_pub,
              private_key = pem_priv
            }
          }
        },
        upstreams = {
          upstreams1 = {
            id = "01a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5c6",
            name = "upstreams1",
            slots = 10,
            use_srv_name = true,
          },
          upstreams2 = {
            id = "01a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5c7",
            name = "upstreams2",
            slots = 10,
          },
          upstreams3 = {
            id = "01a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5c8",
            name = "upstreams3",
            slots = 10,
            use_srv_name = false,
          },
          upstreams4 = {
            id = "01a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5c9",
            name = "upstreams4",
            slots = 10,
            algorithm = "latency",
          },
          upstreams5 = {
            id = "01a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5d0",
            name = "upstreams5",
            slots = 10,
            algorithm = "round-robin",
          },
        },
        plugins = {
          plugin1 = {
            id = "00000000-0000-0000-0000-000000000001",
            name = "cors",
            instance_name = "my-cors"
          },
          plugin2 = {
            id = "00000000-0000-0000-0000-000000000002",
            name = "correlation-id",
            instance_name = "my-correlation-id"
          },
          plugin3 = {
            id = "00000000-0000-0000-0000-000000000003",
            name = "statsd",
            config = {
              queue = {
                max_batch_size = 9,
                max_coalescing_delay = 9,
              },
            },
          },
          plugin4 = {
            id = "00000000-0000-0000-0000-000000000004",
            name = "datadog",
            config = {
              queue = {
                max_batch_size = 9,
                max_coalescing_delay = 9,
              },
            },
          },
          plugin5 = {
            id = "00000000-0000-0000-0000-000000000005",
            name = "opentelemetry",
            config = {
              traces_endpoint = "http://example.com",
              queue = {
                max_batch_size = 9,
                max_coalescing_delay = 9,
              },
            },
          },
        },
        services = {
          service1 = {
            connect_timeout = 60000,
            created_at = 1234567890,
            host = "example.test",
            id = "123e4567-e89b-12d3-a456-426655440000",
            name = "foo1",
            port = 3000,
            read_timeout = 60000,
            retries = 5,
            updated_at = 1234567890,
            write_timeout = 60000,
            protocol = "tls",
            client_certificate = { id = certificate_def.id },
            tls_verify_depth = 1,
            tls_verify = true,
            ca_certificates = { ca_certificate_def.id },
            enabled = true,
          },
          service2 = {
            connect_timeout = 60000,
            created_at = 1234567890,
            host = "example.com",
            id = "123e4567-e89b-12d3-a456-426655440001",
            name = "foo2",
            port = 80,
            read_timeout = 60000,
            retries = 5,
            updated_at = 1234567890,
            write_timeout = 60000,
            protocol = "https",
            client_certificate = { id = certificate_def.id },
            tls_verify_depth = 1,
            tls_verify = true,
            ca_certificates = { ca_certificate_def.id },
            enabled = true,
          },
          service3 = {
            connect_timeout = 60000,
            created_at = 1234567890,
            host = "example.com",
            id = "123e4567-e89b-12d3-a456-426655440002",
            name = "foo3",
            port = 80,
            protocol = "tls",
            read_timeout = 60000,
            retries = 5,
            updated_at = 1234567890,
            write_timeout = 60000,
            enabled = true,
          },
        },
      }, { _transform = true }))

      config = { config_table = declarative.export_config() }
    end)
    it("plugin.use_srv_name", function()
      local has_update, result = compat.update_compatible_payload(config, "3.0.0", "test_")
      assert.truthy(has_update)
      result = cjson_decode(inflate_gzip(result)).config_table

      local upstreams = assert(assert(assert(result).upstreams))
      assert.is_nil(assert(upstreams[1]).use_srv_name)
      assert.is_nil(assert(upstreams[2]).use_srv_name)
      assert.is_nil(assert(upstreams[3]).use_srv_name)
    end)

    it("plugin.instance_name", function()
      local has_update, result = compat.update_compatible_payload(config, "3.1.0", "test_")
      assert.truthy(has_update)
      result = cjson_decode(inflate_gzip(result)).config_table
      local plugins = assert(assert(assert(result).plugins))
      assert.is_nil(assert(plugins[1]).instance_name)
      assert.is_nil(assert(plugins[2]).instance_name)
    end)

    it("plugin.queue_parameters", function()
      local has_update, result = compat.update_compatible_payload(config, "3.2.0", "test_")
      assert.truthy(has_update)
      result = cjson_decode(inflate_gzip(result)).config_table
      local plugins = assert(assert(assert(result).plugins))
      for _, plugin in ipairs(plugins) do
        if plugin.name == "statsd" then
          assert.equals(10, plugin.config.retry_count)
          assert.equals(9, plugin.config.queue_size)
          assert.equals(9, plugin.config.flush_timeout)
        elseif plugin.name == "datadog" then
          assert.equals(10, plugin.config.retry_count)
          assert.equals(9, plugin.config.queue_size)
          assert.equals(9, plugin.config.flush_timeout)
        elseif plugin.name == "opentelemetry" then
          assert.equals(9, plugin.config.batch_span_count)
          assert.equals(9, plugin.config.batch_flush_delay)
        end
      end
    end)

    it("upstream.algorithm", function()
      local has_update, result = compat.update_compatible_payload(config, "3.1.0", "test_")
      assert.truthy(has_update)
      result = cjson_decode(inflate_gzip(result)).config_table
      local upstreams = assert(assert(assert(result).upstreams))
      assert.equals(assert(upstreams[4]).algorithm, "round-robin")
      assert.equals(assert(upstreams[5]).algorithm, "round-robin")
    end)

    it("service.protocol", function()
      local has_update, result = compat.update_compatible_payload(config, "3.1.0", "test_")
      assert.truthy(has_update)
      result = cjson_decode(inflate_gzip(result)).config_table
      local services = assert(assert(assert(result).services))
      assert.is_nil(assert(services[1]).client_certificate)
      assert.is_nil(assert(services[1]).tls_verify)
      assert.is_nil(assert(services[1]).tls_verify_depth)
      assert.is_nil(assert(services[1]).ca_certificates)
      assert.not_nil(assert(services[2]).client_certificate)
      assert.not_nil(assert(services[2]).tls_verify)
      assert.not_nil(assert(services[2]).tls_verify_depth)
      assert.not_nil(assert(services[2]).ca_certificates)
      assert.is_nil(assert(services[3]).client_certificate)
      assert.is_nil(assert(services[3]).tls_verify)
      assert.is_nil(assert(services[3]).tls_verify_depth)
      assert.is_nil(assert(services[3]).ca_certificates)
    end)

    it("key.x5t", function()
      local has_update, result = compat.update_compatible_payload(config, "3.9.0", "test_")
      assert.truthy(has_update)
      result = cjson_decode(inflate_gzip(result)).config_table

      local keys = assert(assert(assert(result).keys))
      assert.is_nil(assert(keys[1]).x5t)
      assert.is_nil(assert(keys[2]).x5t)
    end)
  end)  -- describe

  describe("route entities compatible changes", function()
    local function reload_modules(flavor)
      _G.kong = { configuration = { router_flavor = flavor } }
      _G.kong.db = nil

      package.loaded["kong.db.schema.entities.routes"] = nil
      package.loaded["kong.db.schema.entities.routes_subschemas"] = nil
      package.loaded["spec.helpers"] = nil
      package.loaded["kong.clustering.compat"] = nil
      package.loaded["kong.db.declarative"] = nil

      require("kong.db.schema.entities.routes")
      require("kong.db.schema.entities.routes_subschemas")

      compat = require("kong.clustering.compat")
      helpers = require ("spec.helpers")
      declarative = require("kong.db.declarative")
    end

    lazy_setup(function()
      reload_modules("expressions")
    end)

    lazy_teardown(function()
      reload_modules()
    end)

    it("won't update with mixed mode routes in expressions flavor lower than 3.7", function()
      local _, db = helpers.get_db_utils(nil, {
        "routes",
      })
      _G.kong.db = db

      -- mixed mode routes
      assert(declarative.load_into_db({
        routes = {
          route1 = {
            protocols = { "http" },
            id = "00000000-0000-0000-0000-000000000001",
            hosts = { "example.com" },
            expression = ngx.null,
          },
          route2 = {
            protocols = { "http" },
            id = "00000000-0000-0000-0000-000000000002",
            expression = [[http.path == "/foo"]],
          },
        },
      }, { _transform = true }))

      local config = { config_table = declarative.export_config() }

      local ok, err = compat.check_mixed_route_entities(config, "3.6.0", "expressions")
      assert.is_false(ok)
      assert(string.find(err, "does not support mixed mode route"))

      local ok, err = compat.check_mixed_route_entities(config, "3.7.0", "expressions")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("updates with all traditional routes in expressions flavor", function()
      local _, db = helpers.get_db_utils(nil, {
        "routes",
      })
      _G.kong.db = db

      assert(declarative.load_into_db({
        routes = {
          route1 = {
            protocols = { "http" },
            id = "00000000-0000-0000-0000-000000000001",
            hosts = { "example.com" },
            expression = ngx.null,
          },
        },
      }, { _transform = true }))

      local config = { config_table = declarative.export_config() }

      local ok, err = compat.check_mixed_route_entities(config, "3.6.0", "expressions")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("updates with all expression routes in expressions flavor", function()
      local _, db = helpers.get_db_utils(nil, {
        "routes",
      })
      _G.kong.db = db

      assert(declarative.load_into_db({
        routes = {
          route1 = {
            protocols = { "http" },
            id = "00000000-0000-0000-0000-000000000001",
            expression = [[http.path == "/foo"]],
          },
          route2 = {
            protocols = { "http" },
            id = "00000000-0000-0000-0000-000000000002",
            expression = [[http.path == "/bar"]],
          },
        },
      }, { _transform = true }))

      local config = { config_table = declarative.export_config() }

      local ok, err = compat.check_mixed_route_entities(config, "3.6.0", "expressions")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

  end)  -- describe

end)
