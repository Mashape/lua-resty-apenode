local cjson    = require "cjson"
local lyaml    = require "lyaml"
local kong_table = require "kong.tools.table"
local pl_utils = require "pl.utils"
local helpers  = require "spec.helpers"
local Errors   = require "kong.db.errors"
local mocker   = require("spec.fixtures.mocker")
local ssl_fixtures = require "spec.fixtures.ssl"
local deepcompare  = require("pl.tablex").deepcompare
local inspect = require "inspect"
local nkeys = require "table.nkeys"
local typedefs = require "kong.db.schema.typedefs"
local schema = require "kong.db.schema"
local uuid = require("kong.tools.uuid").uuid

local WORKER_SYNC_TIMEOUT = 10
local LMDB_MAP_SIZE = "10m"
local TEST_CONF = helpers.test_conf


-- XXX: Kong EE supports more service/route protocols than OSS, so we must
-- calculate the expected error message at runtime
local SERVICE_PROTOCOL_ERROR
do
  local proto = assert(schema.new({
                                    type = "record",
                                    fields = {
                                      { protocol = typedefs.protocol }
                                    }
                                  }))

  local _, err = proto:validate({ protocol = "no" })
  assert(type(err) == "table")
  assert(type(err.protocol) == "string")
  SERVICE_PROTOCOL_ERROR = err.protocol
end


local function it_content_types(title, fn)
  local test_form_encoded = fn("application/x-www-form-urlencoded")
  local test_multipart = fn("multipart/form-data")
  local test_json = fn("application/json")

  it(title .. " with application/www-form-urlencoded", test_form_encoded)
  it(title .. " with multipart/form-data", test_multipart)
  it(title .. " with application/json", test_json)
end

describe("Admin API #off", function()
  local client

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      lmdb_map_size = LMDB_MAP_SIZE,
      stream_listen = "127.0.0.1:9011",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong()
  end)

  before_each(function()
    client = assert(helpers.admin_client())
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)

  describe("/routes", function()
    describe("POST", function()
      it_content_types("doesn't allow to creates a route", function(content_type)
        return function()
          if content_type == "multipart/form-data" then
            -- the client doesn't play well with this
            return
          end

          local res = client:post("/routes", {
            body = {
              protocols = { "http" },
              hosts     = { "my.route.test" },
              service   = { id = uuid() },
            },
            headers = { ["Content-Type"] = content_type }
          })
          local body = assert.res_status(405, res)
          local json = cjson.decode(body)
          assert.same({
            code    = Errors.codes.OPERATION_UNSUPPORTED,
            name    = Errors.names[Errors.codes.OPERATION_UNSUPPORTED],
            message = "cannot create 'routes' entities when not using a database",
          }, json)
        end
      end)

      it_content_types("doesn't allow to creates a complex route", function(content_type)
        return function()
          if content_type == "multipart/form-data" then
            -- the client doesn't play well with this
            return
          end

          local res = client:post("/routes", {
            body    = {
              protocols = { "http" },
              methods   = { "GET", "POST", "PATCH" },
              hosts     = { "foo.api.test", "bar.api.test" },
              paths     = { "/foo", "/bar" },
              service   = { id =  uuid() },
            },
            headers = { ["Content-Type"] = content_type }
          })

          local body = assert.res_status(405, res)
          local json = cjson.decode(body)
          assert.same({
            code    = Errors.codes.OPERATION_UNSUPPORTED,
            name    = Errors.names[Errors.codes.OPERATION_UNSUPPORTED],
            message = "cannot create 'routes' entities when not using a database",
          }, json)
        end
      end)
    end)

    describe("GET", function()
      describe("errors", function()
        it("handles invalid offsets", function()
          local res  = client:get("/routes", { query = { offset = "x" } })
          local body = assert.res_status(400, res)
          assert.same({
            code    = Errors.codes.INVALID_OFFSET,
            name    = "invalid offset",
            message = "'x' is not a valid offset: bad base64 encoding"
          }, cjson.decode(body))

          res  = client:get("/routes", { query = { offset = "|potato|" } })
          body = assert.res_status(400, res)

          local json = cjson.decode(body)
          json.message = nil

          assert.same({
            code = Errors.codes.INVALID_OFFSET,
            name = "invalid offset",
          }, json)
        end)
      end)
    end)

    it("returns HTTP 405 on invalid method", function()
      local methods = { "DELETE", "PUT", "PATCH", "POST" }
      for i = 1, #methods do
        local res = assert(client:send {
          method = methods[i],
          path = "/routes",
          body = {
            paths = { "/" },
            service = { id = uuid() }
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        local body = assert.response(res).has.status(405)
        local json = cjson.decode(body)
        if methods[i] == "POST" then
          assert.same({
            code    = Errors.codes.OPERATION_UNSUPPORTED,
            name    = Errors.names[Errors.codes.OPERATION_UNSUPPORTED],
            message = "cannot create 'routes' entities when not using a database",
          }, json)

        else
          assert.same({ message = "Method not allowed" }, json)
        end
      end
    end)
  end)

  describe("/routes/{route}", function()
    it("returns HTTP 405 on invalid method", function()
      local methods = { "PUT", "POST" }
      for i = 1, #methods do
        local res = assert(client:send {
          method = methods[i],
          path = "/routes/" .. uuid(),
          body = {
            paths = { "/" },
            service = { id = uuid() }
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(405)
        local json = cjson.decode(body)
        if methods[i] ~= "POST" then
          assert.same({
            code    = Errors.codes.OPERATION_UNSUPPORTED,
            name    = Errors.names[Errors.codes.OPERATION_UNSUPPORTED],
            message = "cannot create or update 'routes' entities when not using a database",
          }, json)

        else
          assert.same({ message = "Method not allowed" }, json)
        end
      end
    end)
  end)

  describe("/config", function()
    describe("POST", function()
      it("accepts configuration as JSON body", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            _format_version = "1.1",
            consumers = {
              {
                username = "bobby_in_json_body",
              },
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          },
        })

        assert.response(res).has.status(201)
      end)

      it("accepts configuration as YAML body", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = helpers.unindent([[
            _format_version: "1.1"
            consumers:
              - username: "bobby_in_yaml_body"
          ]]),
          headers = {
            ["Content-Type"] = "application/yaml"
          },
        })

        assert.response(res).has.status(201)
      end)

      it("accepts configuration as a JSON string under `config` JSON key", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            {
              "_format_version" : "1.1",
              "consumers" : [
                {
                  "username" : "bobby_in_json_under_config"
                }
              ]
            }
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          },
        })

        assert.response(res).has.status(201)
      end)

      it("accepts configuration as a YAML string under `config` JSON key", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = helpers.unindent([[
              _format_version: "1.1"
              consumers:
                - username: "bobby_in_yaml_under_config"
            ]]),
          },
          headers = {
            ["Content-Type"] = "application/json"
          },
        })

        assert.response(res).has.status(201)
      end)

      it("fails with 413 and preserves previous cache if config does not fit in cache", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            {
              "_format_version" : "1.1",
              "consumers" : [
                {
                  "username" : "previous"
                }
              ]
            }
            ]],
            type = "json",
          },
          headers = {
            ["Content-Type"] = "application/json"
          },
        })

        assert.response(res).has.status(201)

        helpers.wait_until(function()
          res = assert(client:send {
            method = "GET",
            path = "/consumers/previous",
            headers = {
              ["Content-Type"] = "application/json"
            }
          })

          local body = res:read_body()
          local json = cjson.decode(body)
          if res.status == 200 and json.username == "previous" then
            return true
          end
        end, WORKER_SYNC_TIMEOUT)

        client:close()
        client = assert(helpers.admin_client())

        local consumers = {}
        for i = 1, 20000 do
          table.insert(consumers, [[
            {
              "username" : "bobby-]] .. i .. [["
            }
          ]])
        end
        local config = [[
        {
          "_format_version" : "1.1",
          "consumers" : [
        ]] .. table.concat(consumers, ", ") .. [[
          ]
        }
        ]]
        res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = config,
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(413)

        helpers.wait_until(function()
          client:close()
          client = assert(helpers.admin_client())
          res = assert(client:send {
            method = "GET",
            path = "/consumers/previous",
            headers = {
              ["Content-Type"] = "application/json"
            }
          })

          local body = res:read_body()
          local json = cjson.decode(body)
          if res.status == 200 and json.username == "previous" then
            return true
          end
        end, WORKER_SYNC_TIMEOUT)

      end)

      it("accepts configuration containing null as a YAML string", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            _format_version: "1.1"
            routes:
            - paths:
              - "/"
              service: null
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(201)
      end)

      it("hides workspace related fields from /config response", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            _format_version: "1.1"
            services:
            - name: my-service
              id: 0855b320-0dd2-547d-891d-601e9b38647f
              url: https://example.com
              plugins:
              - name: file-log
                id: 0611a5a9-de73-5a2d-a4e6-6a38ad4c3cb2
                config:
                  path: /tmp/file.log
              - name: key-auth
                id: 661199ff-aa1c-5498-982c-d57a4bd6e48b
              routes:
              - name: my-route
                id: 481a9539-f49c-51b6-b2e2-fe99ee68866c
                paths:
                - /
            consumers:
            - username: my-user
              id: 4b1b701d-de2b-5588-9aa2-3b97061d9f52
              keyauth_credentials:
              - key: my-key
                id: 487ab43c-b2c9-51ec-8da5-367586ea2b61
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(201)
        local entities = cjson.decode(body)

        assert.is_nil(entities.workspaces)
        assert.is_nil(entities.consumers["4b1b701d-de2b-5588-9aa2-3b97061d9f52"].ws_id)
        assert.is_nil(entities.keyauth_credentials["487ab43c-b2c9-51ec-8da5-367586ea2b61"].ws_id)
        assert.is_nil(entities.plugins["0611a5a9-de73-5a2d-a4e6-6a38ad4c3cb2"].ws_id)
        assert.is_nil(entities.plugins["661199ff-aa1c-5498-982c-d57a4bd6e48b"].ws_id)

        local services = entities.services["0855b320-0dd2-547d-891d-601e9b38647f"]
        local routes = entities.routes["481a9539-f49c-51b6-b2e2-fe99ee68866c"]

        assert.is_not_nil(services)
        assert.is_not_nil(routes)
        assert.is_nil(services.ws_id)
        assert.is_nil(routes.ws_id)
        assert.equals(routes.service.id, services.id)
      end)

      it("certificates should be auto-related with attach snis from /config response", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {    
            _format_version = "1.1",
            certificates = {
              {
                cert = ssl_fixtures.cert,
                id = "d83994d2-c24c-4315-b431-ee76b6611dcb",
                key = ssl_fixtures.key,
                snis = {
                  {
                    name = "foo.example",
                    id = "1c6e83b7-c9ad-40ac-94e8-52f5ee7bde44",
                  },
                }
              }
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(201)
        local entities = cjson.decode(body)
        local certificates = entities.certificates["d83994d2-c24c-4315-b431-ee76b6611dcb"]
        local snis = entities.snis["1c6e83b7-c9ad-40ac-94e8-52f5ee7bde44"]
        assert.is_not_nil(certificates)
        assert.is_not_nil(snis)
        assert.equals(snis.certificate.id, certificates.id)
      end)

      it("certificates should be auto-related with separate snis from /config response", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            _format_version = "1.1",
            certificates = {
              {
                cert = ssl_fixtures.cert,
                id = "d83994d2-c24c-4315-b431-ee76b6611dcb",
                key = ssl_fixtures.key,
              },
            },
            snis = {
              {
                name = "foo.example",
                id = "1c6e83b7-c9ad-40ac-94e8-52f5ee7bde44",
                certificate = {
                  id = "d83994d2-c24c-4315-b431-ee76b6611dcb"
                }
              },
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(201)
        local entities = cjson.decode(body)
        local certificates = entities.certificates["d83994d2-c24c-4315-b431-ee76b6611dcb"]
        local snis = entities.snis["1c6e83b7-c9ad-40ac-94e8-52f5ee7bde44"]
        assert.is_not_nil(certificates)
        assert.is_not_nil(snis)
        assert.equals(snis.certificate.id, certificates.id)
      end)

      it("can reload upstreams (regression test)", function()
        local config = [[
          _format_version: "1.1"
          services:
          - host: foo
            routes:
            - paths:
              - "/"
          upstreams:
          - name: "foo"
            targets:
            - target: 10.20.30.40
        ]]
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = config,
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(201)

        client:close()
        client = helpers.admin_client()

        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = config,
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(201)
      end)

      it("returns 304 if checking hash and configuration is identical", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config?check_hash=1",
          body = {
            config = [[
            _format_version: "1.1"
            consumers:
            - username: bobby_tables
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(201)

        client:close()
        client = helpers.admin_client()

        res = assert(client:send {
          method = "POST",
          path = "/config?check_hash=1",
          body = {
            config = [[
            _format_version: "1.1"
            consumers:
            - username: bobby_tables
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(304)
      end)

      it("returns 400 on an invalid config string", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = "bobby tables",
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(400)
        local json = cjson.decode(body)
        assert.same({
          code = 14,
          fields = {
            error ="failed parsing declarative configuration: expected an object",
          },
          message = [[declarative config is invalid: ]] ..
                    [[{error="failed parsing declarative configuration: ]] ..
                    [[expected an object"}]],
          name = "invalid declarative configuration",
        }, json)
      end)

      it("returns 400 on a validation error", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            _format_version: "1.1"
            services:
            - port: -12
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(400)
        local json = cjson.decode(body)
        assert.same({
          code = 14,
          fields = {
            services = {
              {
                host = "required field missing",
                port = "value should be between 0 and 65535",
              }
            }
          },
          message = [[declarative config is invalid: ]] ..
                    [[{services={{host="required field missing",]] ..
                    [[port="value should be between 0 and 65535"}}}]],
          name = "invalid declarative configuration",
        }, json)
      end)

      it("returns 400 on an primary key uniqueness error", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            _format_version: "1.1"
            services:
            - id: 0855b320-0dd2-547d-891d-601e9b38647f
              name: foo
              host: example.com
              protocol: https
              routes:
              - name: foo
                methods: ["GET"]
                plugins:
                  - name: key-auth
                  - name: http-log
                    config:
                      http_endpoint: https://example.com
            - id: 0855b320-0dd2-547d-891d-601e9b38647f
              name: bar
              host: example.test
              port: 3000
              routes:
              - name: bar
                paths:
                - /
                plugins:
                - name: basic-auth
                - name: tcp-log
                  config:
                    host: 127.0.0.1
                    port: 10000
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(400)
        local json = cjson.decode(body)
        assert.same({
          code = 14,
          fields = {
            services = {
              cjson.null,
              "uniqueness violation: 'services' entity with primary key set to '0855b320-0dd2-547d-891d-601e9b38647f' already declared",
            }
          },
          message = [[declarative config is invalid: ]] ..
                    [[{services={[2]="uniqueness violation: 'services' entity with primary key set to '0855b320-0dd2-547d-891d-601e9b38647f' already declared"}}]],
          name = "invalid declarative configuration",
        }, json)
      end)

      it("returns 400 on an endpoint key uniqueness error", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            _format_version: "1.1"
            services:
            - name: foo
              host: example.com
              protocol: https
              routes:
              - name: foo
                methods: ["GET"]
                plugins:
                  - name: key-auth
                  - name: http-log
                    config:
                      http_endpoint: https://example.com
            - name: foo
              host: example.test
              port: 3000
              routes:
              - name: bar
                paths:
                - /
                plugins:
                - name: basic-auth
                - name: tcp-log
                  config:
                    host: 127.0.0.1
                    port: 10000
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(400)
        local json = cjson.decode(body)
        assert.same({
          code = 14,
          fields = {
            services = {
              cjson.null,
              "uniqueness violation: 'services' entity with name set to 'foo' already declared",
            }
          },
          message = [[declarative config is invalid: ]] ..
                    [[{services={[2]="uniqueness violation: 'services' entity with name set to 'foo' already declared"}}]],
          name = "invalid declarative configuration",
        }, json)
      end)

      it("returns 400 on a regular key uniqueness error", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            _format_version: "1.1"
            consumers:
            - username: foo
              custom_id: conflict
            - username: bar
              custom_id: conflict
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        local body = assert.response(res).has.status(400)
        local json = cjson.decode(body)
        assert.same({
          code = 14,
          fields = {
            consumers = {
              bar = "uniqueness violation: 'consumers' entity with custom_id set to 'conflict' already declared",
            }
          },
          message = [[declarative config is invalid: ]] ..
                    [[{consumers={bar="uniqueness violation: 'consumers' entity with custom_id set to 'conflict' already declared"}}]],
          name = "invalid declarative configuration",
        }, json)
      end)

      it("returns 400 when given no input", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
        })

        local body = assert.response(res).has.status(400)
        local json = cjson.decode(body)
        assert.same({
          message = "expected a declarative configuration",
        }, json)
      end)

      it("sparse responses are correctly generated", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            config = [[
            {
              "_format_version" : "1.1",
              "plugins": [{
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "key-auth",
                "enabled": true,
                "protocols": ["http", "https"]
              }, {
                "name": "cors",
                "config": {
                  "credentials": true,
                  "exposed_headers": ["*"],
                  "headers": ["*"],
                  "methods": ["*"],
                  "origins": ["*"],
                  "preflight_continue": true
                },
                "enabled": true,
                "protocols": ["http", "https"]
              }]
            }
            ]],
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(400)
      end)
    end)

    describe("GET", function()
      it("returns back the configuration", function()
        local res = assert(client:send {
          method = "POST",
          path = "/config",
          body = {
            _format_version = "1.1",
            consumers = {
              {
                username = "bobo",
                id = "d885e256-1abe-5e24-80b6-8f68fe59ea8e",
                created_at = 1566863706,
              },
            },
          },
          headers = {
            ["Content-Type"] = "application/json"
          }
        })

        assert.response(res).has.status(201)

        local res = assert(client:send {
          method = "GET",
          path = "/config",
        })

        local body = assert.response(res).has.status(200)
        local json = cjson.decode(body)
        local config = assert(lyaml.load(json.config))
        assert.same({
          _format_version = "3.0",
          _transform = false,
          consumers = {
            { id = "d885e256-1abe-5e24-80b6-8f68fe59ea8e",
              created_at = 1566863706,
              updated_at = config.consumers[1].updated_at,
              username = "bobo",
              custom_id = lyaml.null,
              tags = lyaml.null,
            },
          },
        }, config)
      end)
    end)

    it("can load large declarative config (regression test)", function()
      local config = assert(pl_utils.readfile("spec/fixtures/burst.yml"))
      local res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = config,
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)
    end)

    it("updates stream subsystem config", function()
      local res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = [[
          _format_version: "1.1"
          services:
          - connect_timeout: 60000
            host: 127.0.0.1
            name: mock
            port: 15557
            protocol: tcp
            routes:
            - name: mock_route
              protocols:
              - tcp
              destinations:
              - port: 9011
          ]],
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)

      helpers.wait_until(function()
        local sock = ngx.socket.tcp()
        assert(sock:connect("127.0.0.1", 9011))
        assert(sock:send("hi\n"))
        local pok = pcall(helpers.wait_until, function()
          return sock:receive() == "hi"
        end, 1)
        sock:close()
        return pok == true
      end)
    end)
  end)

  describe("/upstreams", function()
    it("can set target health without port", function()
      local config = [[
        _format_version: "1.1"
        services:
        - host: foo
          routes:
          - paths:
            - "/"
        upstreams:
        - name: "foo"
          targets:
            - target: 10.20.30.40
          healthchecks:
            passive:
              healthy:
                successes: 1
              unhealthy:
                http_failures: 1
      ]]

      local res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = config,
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)


      res = client:get("/upstreams/foo/targets")
      assert.response(res).has.status(200)

      local json = assert.response(res).has.jsonbody()
      assert.is_table(json.data)
      assert.same(1, #json.data)
      assert.is_table(json.data[1])

      local id = assert.is_string(json.data[1].id)

      helpers.wait_until(function()
        local res = assert(client:send {
          method = "PUT",
          path = "/upstreams/foo/targets/" .. id .. "/10.20.30.40/unhealthy",
        })

        return pcall(function()
          assert.response(res).has.status(204)
        end)
      end, 10)

      client:close()
    end)

    it("targets created missing ports listed with ports", function()
      local config = [[
        _format_version: "1.1"
        services:
        - host: foo
          routes:
          - paths:
            - "/"
        upstreams:
        - name: "foo"
          targets:
          - target: 10.20.30.40
          - target: 50.60.70.80:90
      ]]

      local res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = config,
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)

      local res = assert(client:send {
        method = "GET",
        path = "/upstreams/foo/targets/all",
      })

      local body = assert.response(res).has.status(200)
      local json = cjson.decode(body)

      table.sort(json.data, function(t1, t2)
        return t1.target < t2.target
      end)

      assert.same("10.20.30.40:8000", json.data[1].target)
      assert.same("50.60.70.80:90", json.data[2].target)

      client:close()
    end)
  end)
end)


describe("Admin API #off /config [flattened errors]", function()
  local client
  local tags

  local function make_tag_t(name)
    return setmetatable({
      name = name,
      count = 0,
      last = nil,
    }, {
      __index = function(self, k)
        if k == "next" then
          self.count = self.count + 1
          local tag = ("%s-%02d"):format(self.name, self.count)
          self.last = tag
          return tag
        else
          error("unknown key: " .. k)
        end
      end,
    })
  end

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      lmdb_map_size = LMDB_MAP_SIZE,
      stream_listen = "127.0.0.1:9011",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      plugins = "bundled",
      vaults = "bundled",
      log_level = "warn",
    }))
  end)


  lazy_teardown(function()
    helpers.stop_kong()
  end)

  before_each(function()
    client = assert(helpers.admin_client())
    helpers.clean_logfile()

    tags = setmetatable({}, {
      __index = function(self, k)
        self[k] = make_tag_t(k)
        return self[k]
      end,
    })
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)

  local function sort_errors(t)
    if type(t) ~= "table" then
      return
    end
    table.sort(t, function(a, b)
      if a.type ~= b.type then
        return a.type < b.type
      end

      if a.field ~= b.field then
        return a.field < b.field
      end

      return a.message < b.message
    end)
  end


  local function is_fk(value)
    return type(value) == "table"
       and nkeys(value) == 1
       and value.id ~= nil
  end

  local compare_entity

  local function compare_field(field, exp, got, diffs)
    -- Entity IDs are a special case
    --
    -- In general, we don't want to bother comparing them because they
    -- are going to be auto-generated at random for each test run. The
    -- exception to this rule is that when the expected data explicitly
    -- specifies an ID, we want to compare it.
    if field == "entity_id" or field == "id" or is_fk(got) then
      if exp == nil then
        got = nil

      elseif exp == ngx.null then
        exp = nil
      end

    elseif field == "entity" then
      return compare_entity(exp, got, diffs)

    -- sort the errors array; its order is not guaranteed and does not
    -- really matter, so sorting is just for ease of deep comparison
    elseif field == "errors" then
      sort_errors(exp)
      sort_errors(got)
    end

    if not deepcompare(exp, got) then
      if diffs then
        table.insert(diffs, field)
      end
      return false
    end

    return true
  end

  function compare_entity(exp, got, diffs)
    local seen = {}

    for field in pairs(exp) do
      if not compare_field(field, exp[field], got[field])
      then
        table.insert(diffs, "entity." .. field)
      end
      seen[field] = true
    end

    for field in pairs(got) do
      -- NOTE: certain fields may be present in the actual response
      -- but missing from the expected response (e.g. `id`)
      if not seen[field] and
         not compare_field(field, exp[field], got[field])
      then
        table.insert(diffs, "entity." .. field)
      end
    end
  end

  local function compare(exp, got, diffs)
    if type(exp) ~= "table" or type(got) ~= "table" then
      return exp == got
    end

    local seen = {}

    for field in pairs(exp) do
      seen[field] = true
      compare_field(field, exp[field], got[field], diffs)
    end

    for field in pairs(got) do
      if not seen[field] then
        compare_field(field, exp[field], got[field], diffs)
      end
    end

    return #diffs == 0
  end

  local function get_by_tag(tag, haystack)
    if type(tag) == "table" then
      tag = tag[1]
    end

    for i = 1, #haystack do
      local item = haystack[i]
      if item.entity.tags and
         item.entity.tags[1] == tag
      then
        return table.remove(haystack, i)
      end
    end
  end

  local function find(needle, haystack)
    local tag = needle.entity
            and needle.entity.tags
            and needle.entity.tags[1]
    if not tag then
      return
    end

    return get_by_tag(tag, haystack)
  end


  local function post_config(config, debug)
    config._format_version = config._format_version or "3.0"

    local res = client:post("/config?flatten_errors=1", {
      body = config,
      headers = {
        ["Content-Type"] = "application/json"
      },
    })

    assert.response(res).has.status(400)
    local body = assert.response(res).has.jsonbody()

    local errors = body.flattened_errors

    assert.not_nil(errors, "`flattened_errors` is missing from the response")
    assert.is_table(errors, "`flattened_errors` is not a table")

    if debug then
      helpers.intercept(body)
    end

    assert.logfile().has.no.line("[emerg]", true, 0)
    assert.logfile().has.no.line("[crit]",  true, 0)
    assert.logfile().has.no.line("[alert]", true, 0)
    assert.logfile().has.no.line("[error]", true, 0)
    assert.logfile().has.no.line("[warn]",  true, 0)

    return errors
  end


  -- Testing Methodology:
  --
  -- 1. Iterate through each array (expected, received)
  -- 2. Correlate expected and received entries by comparing the first
  --    entity tag of each
  -- 3. Compare the two entries

  local function validate(expected, received)
    local errors = {}

    while #expected > 0 do
      local exp = table.remove(expected)
      local got = find(exp, received)
      local diffs = {}
      if not compare(exp, got, diffs) then
        table.insert(errors, { exp = exp, got = got, diffs = diffs })
      end
    end

    -- everything left in flattened is an unexpected, extra entry
    for _, got in ipairs(received) do
      assert.is_nil(find(got, expected))
      table.insert(errors, { got = got })
    end

    if #errors > 0 then
      local msg = {}

      for i, err in ipairs(errors) do
        local exp, got = err.exp, err.got

        table.insert(msg, ("\n======== Error #%00d ========\n"):format(i))

        if not exp then
          table.insert(msg, "Unexpected entry:\n")
          table.insert(msg, inspect(got))
          table.insert(msg, "\n")

        elseif not got then
          table.insert(msg, "Missing entry:\n")
          table.insert(msg, inspect(exp))
          table.insert(msg, "\n")

        else
          table.insert(msg, "Expected:\n\n")
          table.insert(msg, inspect(exp))
          table.insert(msg, "\n\n")
          table.insert(msg, "Got:\n\n")
          table.insert(msg, inspect(got))
          table.insert(msg, "\n\n")

          table.insert(msg, "Unmatched Fields:\n")
          for _, field in ipairs(err.diffs) do
            table.insert(msg, ("  - %s\n"):format(field))
          end
        end

        table.insert(msg, "\n")
      end

      assert.equals(0, #errors, table.concat(msg))
    end
  end



  it("sanity", function()
    -- Test Cases
    --
    -- The first tag string in the entity tags table is a unique ID for
    -- that entity. This allows the test code to locate and correlate
    -- each item in the actual response to one in the expected response
    -- when deepcompare() will not consider the entries to be equivalent.
    --
    -- Use the tag helper table to generate this tag for each entity you
    -- add to the input (`tag.ENTITY_NAME.next`):
    --
    -- tags = { tags.consumer.next } -> { "consumer-01" }
    -- tags = { tags.consumer.next } -> { "consumer-02" }
    --
    -- You can use `tag.ENTITY_NAME.last` if you want to refer to the last
    -- ID that was generated for an entity type. This has no special
    -- meaning in the tests, but it can be helpful in correlating an entity
    -- with its parent when debugging:
    --
    -- services = {
    --   {
    --     name = "foo",
    --     tags = { tags.service.next }, -- > "service-01",
    --     routes = {
    --       tags = {
    --         tags.route_service.next,  -- > "route_service-01",
    --         tags.service.last         -- > "service-01",
    --       },
    --     }
    --   }
    -- }
    --
    -- Additional tags can be added after the first one, and they will be
    -- deepcompare()-ed when error-checking is done.
    local input = {
      consumers = {
        { username = "valid_user",
          tags = { tags.consumer.next },
        },

        { username = "bobby_in_json_body",
          not_allowed = true,
          tags = { tags.consumer.next },
        },

        { username = "super_valid_user",
          tags = { tags.consumer.next },
        },

        { username = "credentials",
          tags = { tags.consumer.next },
          basicauth_credentials = {
            { username = "superduper",
              password = "hard2guess",
              tags = { tags.basicauth_credentials.next, tags.consumer.last },
            },

            { username = "dont-add-extra-fields-yo",
              password = "12354",
              extra_field = "NO!",
              tags = { tags.basicauth_credentials.next, tags.consumer.last },
            },
          },
        },
      },

      plugins = {
        { name = "http-log",
          config = { http_endpoint = "invalid::#//url", },
          tags = { tags.global_plugin.next },
        },
      },

      certificates = {
        {
          cert = [[-----BEGIN CERTIFICATE-----
MIICIzCCAYSgAwIBAgIUUMiD8e3GDZ+vs7XBmdXzMxARUrgwCgYIKoZIzj0EAwIw
IzENMAsGA1UECgwES29uZzESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTIyMTIzMDA0
MDcwOFoXDTQyMTIyNTA0MDcwOFowIzENMAsGA1UECgwES29uZzESMBAGA1UEAwwJ
bG9jYWxob3N0MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQBxSldGzzRAtjt825q
Uwl+BNgxecswnvbQFLiUDqJjVjCfs/B53xQfV97ddxsRymES2viC2kjAm1Ete4TH
CQmVltUBItHzI77HB+UsfqHoUdjl3lC/HC1yDSPBp5wd9eRRSagdl0eiJwnB9lof
MEnmOQLg177trb/YPz1vcCCZj7ikhzCjUzBRMB0GA1UdDgQWBBSUI6+CKqKFz/Te
ZJppMNl/Dh6d9DAfBgNVHSMEGDAWgBSUI6+CKqKFz/TeZJppMNl/Dh6d9DAPBgNV
HRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA4GMADCBiAJCAZL3qX21MnGtQcl9yOMr
hNR54VrDKgqLR+ChU7/358n/sK/sVOjmrwVyQ52oUyqaQlfBQS2EufQVO/01+2sx
86gzAkIB/4Ilf4RluN2/gqHYlVEDRZzsqbwVJBHLeNKsZBSJkhNNpJBwa2Ndl9/i
u2tDk0KZFSAvRnqRAo9iDBUkIUI1ahA=
-----END CERTIFICATE-----]],
          key = [[-----BEGIN EC PRIVATE KEY-----
MIHcAgEBBEIARPKnAYLB54bxBvkDfqV4NfZ+Mxl79rlaYRB6vbWVwFpy+E2pSZBR
doCy1tHAB/uPo+QJyjIK82Zwa3Kq0i1D2QigBwYFK4EEACOhgYkDgYYABAHFKV0b
PNEC2O3zbmpTCX4E2DF5yzCe9tAUuJQOomNWMJ+z8HnfFB9X3t13GxHKYRLa+ILa
SMCbUS17hMcJCZWW1QEi0fMjvscH5Sx+oehR2OXeUL8cLXINI8GnnB315FFJqB2X
R6InCcH2Wh8wSeY5AuDXvu2tv9g/PW9wIJmPuKSHMA==
-----END EC PRIVATE KEY-----]],
          tags = { tags.certificate.next },
        },

        {
          cert = [[-----BEGIN CERTIFICATE-----
MIICIzCCAYSgAwIBAgIUUMiD8e3GDZ+vs7XBmdXzMxARUrgwCgYIKoZIzj0EAwIw
IzENMAsGA1UECgwES29uZzESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTIyMTIzMDA0
MDcwOFoXDTQyohnoooooooooooooooooooooooooooooooooooooooooooasdfa
Uwl+BNgxecswnvbQFLiUDqJjVjCfs/B53xQfV97ddxsRymES2viC2kjAm1Ete4TH
CQmVltUBItHzI77AAAAAAAAAAAAAAAC/HC1yDSBBBBBBBBBBBBBdl0eiJwnB9lof
MEnmOQLg177trb/AAAAAAAAAAAAAAACjUzBRMBBBBBBBBBBBBBBUI6+CKqKFz/Te
ZJppMNl/Dh6d9DAAAAAAAAAAAAAAAASUI6+CKqBBBBBBBBBBBBB/Dh6d9DAPBgNV
HRMBAf8EBTADAQHAAAAAAAAAAAAAAAMCA4GMADBBBBBBBBBBBBB1MnGtQcl9yOMr
hNR54VrDKgqLR+CAAAAAAAAAAAAAAAjmrwVyQ5BBBBBBBBBBBBBEufQVO/01+2sx
86gzAkIB/4Ilf4RluN2/gqHYlVEDRZzsqbwVJBHLeNKsZBSJkhNNpJBwa2Ndl9/i
u2tDk0KZFSAvRnqRAo9iDBUkIUI1ahA=
-----END CERTIFICATE-----]],
          key = [[-----BEGIN EC PRIVATE KEY-----
MIHcAgEBBEIARPKnAYLB54bxBvkDfqV4NfZ+Mxl79rlaYRB6vbWVwFpy+E2pSZBR
doCy1tHAB/uPo+QJyjIK82Zwa3Kq0i1D2QigBwYFK4EEACOhgYkDgYYABAHFKV0b
PNEC2O3zbmpTCX4E2DF5yzCe9tAUuJQOomNWMJ+z8HnfFB9X3t13GxHKYRLa+ILa
SMCbUS17hMcJCZWW1QEi0fMjvscH5Sx+oehR2OXeUL8cLXINI8GnnB315FFJqB2X
R6InCcH2Wh8wSeY5AuDXvu2tv9g/PW9wIJmPuKSHMA==
-----END EC PRIVATE KEY-----]],
          tags = { tags.certificate.next },
        },

      },

      services = {
        { name = "nope",
          host = "localhost",
          port = 1234,
          protocol = "nope",
          tags = { tags.service.next },
          routes = {
            { name = "valid.route",
              protocols = { "http", "https" },
              methods = { "GET" },
              hosts = { "test" },
              tags = { tags.route_service.next, tags.service.last },
            },

            { name = "nope.route",
              protocols = { "tcp" },
              tags = { tags.route_service.next, tags.service.last },
            }
          },
        },

        { name = "mis-matched",
          host = "localhost",
          protocol = "tcp",
          path = "/path",
          tags = { tags.service.next },

          routes = {
            { name = "invalid",
              protocols = { "http", "https" },
              hosts = { "test" },
              methods = { "GET" },
              tags = { tags.route_service.next, tags.service.last },
            },
          },
        },

        { name = "okay",
          url = "http://localhost:1234",
          tags = { tags.service.next },
          routes = {
            { name = "probably-valid",
              protocols = { "http", "https" },
              methods = { "GET" },
              hosts = { "test" },
              tags = { tags.route_service.next, tags.service.last },
              plugins = {
                { name = "http-log",
                  config = { not_endpoint = "anything" },
                  tags = { tags.route_service_plugin.next,
                           tags.route_service.last,
                           tags.service.last, },
                },
              },
            },
          },
        },

        { name = "bad-service-plugins",
          url = "http://localhost:1234",
          tags = { tags.service.next },
          plugins = {
            { name = "i-dont-exist",
              config = {},
              tags = { tags.service_plugin.next, tags.service.last },
            },

            { name = "tcp-log",
              config = {
                deeply = { nested = { undefined = true } },
                port = 1234,
              },
              tags = { tags.service_plugin.next, tags.service.last },
            },
          },
        },

        { name = "bad-client-cert",
          url = "https://localhost:1234",
          tags = { tags.service.next },
          client_certificate = {
            cert = "",
            key = "",
            tags = { tags.service_client_certificate.next,
                     tags.service.last, },
          },
        },

        {
          name = "invalid-id",
          id = 123456,
          url = "https://localhost:1234",
          tags = { tags.service.next, "invalid-id" },
        },

        {
          name = "invalid-tags",
          url = "https://localhost:1234",
          tags = { tags.service.next, "invalid-tags", {1,2,3}, true },
        },

        {
          name = "",
          url = "https://localhost:1234",
          tags = { tags.service.next, tags.invalid_service_name.next },
        },

        {
          name = 1234,
          url = "https://localhost:1234",
          tags = { tags.service.next, tags.invalid_service_name.next },
        },

      },

      upstreams = {
        { name = "ok",
          tags = { tags.upstream.next },
          hash_on = "ip",
        },

        { name = "bad",
          tags = { tags.upstream.next },
          hash_on = "ip",
          healthchecks = {
            active = {
              type = "http",
              http_path = "/",
              https_verify_certificate = true,
              https_sni = "example.com",
              timeout = 1,
              concurrency = -1,
              healthy = {
                interval = 0,
                successes = 0,
              },
              unhealthy = {
                interval = 0,
                http_failures = 0,
              },
            },
          },
          host_header = 123,
        },

        {
          name = "ok-bad-targets",
          tags = { tags.upstream.next },
          targets = {
            { target = "127.0.0.1:99",
              tags = { tags.upstream_target.next,
                       tags.upstream.last, },
            },
            { target = "hostname:1.0",
              tags = { tags.upstream_target.next,
                       tags.upstream.last, },
            },
          },
        }
      },

      vaults = {
        {
          name = "env",
          prefix = "test",
          config = { prefix = "SSL_" },
          tags = { tags.vault.next },
        },

        {
          name = "vault-not-installed",
          prefix = "env",
          config = { prefix = "SSL_" },
          tags = { tags.vault.next, "vault-not-installed" },
        },

      },
    }

    local expect = {
      {
        entity = {
          extra_field = "NO!",
          password = "12354",
          tags = { "basicauth_credentials-02", "consumer-04", },
          username = "dont-add-extra-fields-yo",
        },
        entity_tags = { "basicauth_credentials-02", "consumer-04", },
        entity_type = "basicauth_credential",
        errors = { {
          field = "extra_field",
          message = "unknown field",
          type = "field"
        } }
      },

      {
        entity = {
          config = {
            prefix = "SSL_"
          },
          name = "vault-not-installed",
          prefix = "env",
          tags = { "vault-02", "vault-not-installed" }
        },
        entity_name = "vault-not-installed",
        entity_tags = { "vault-02", "vault-not-installed" },
        entity_type = "vault",
        errors = { {
            field = "name",
            message = "vault 'vault-not-installed' is not installed",
            type = "field"
          } }
      },

      {
        -- note entity_name is nil, but entity.name is not
        entity_name = nil,
        entity = {
          name = "",
          tags = { "service-08", "invalid_service_name-01" },
          url = "https://localhost:1234"
        },
        entity_tags = { "service-08", "invalid_service_name-01" },
        entity_type = "service",
        errors = { {
            field = "name",
            message = "length must be at least 1",
            type = "field"
          } }
      },

      {
        -- note entity_name is nil, but entity.name is not
        entity_name = nil,
        entity = {
          name = 1234,
          tags = { "service-09", "invalid_service_name-02" },
          url = "https://localhost:1234"
        },
        entity_tags = { "service-09", "invalid_service_name-02" },
        entity_type = "service",
        errors = { {
            field = "name",
            message = "expected a string",
            type = "field"
          } }
      },

      {
        -- note entity_tags is nil, but entity.tags is not
        entity_tags = nil,
        entity = {
          name = "invalid-tags",
          tags = { "service-07", "invalid-tags", { 1, 2, 3 }, true },
          url = "https://localhost:1234"
        },
        entity_name = "invalid-tags",
        entity_type = "service",
        errors = { {
            field = "tags.3",
            message = "expected a string",
            type = "field"
          }, {
            field = "tags.4",
            message = "expected a string",
            type = "field"
          } }
      },

      {
        entity_id = ngx.null,
        entity = {
          name = "invalid-id",
          id = 123456,
          tags = { "service-06", "invalid-id" },
          url = "https://localhost:1234"
        },
        entity_name = "invalid-id",
        entity_tags = { "service-06", "invalid-id" },
        entity_type = "service",
        errors = { {
            field = "id",
            message = "expected a string",
            type = "field"
          } }
      },

      {
        entity = {
          cert = "-----BEGIN CERTIFICATE-----\nMIICIzCCAYSgAwIBAgIUUMiD8e3GDZ+vs7XBmdXzMxARUrgwCgYIKoZIzj0EAwIw\nIzENMAsGA1UECgwES29uZzESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTIyMTIzMDA0\nMDcwOFoXDTQyohnoooooooooooooooooooooooooooooooooooooooooooasdfa\nUwl+BNgxecswnvbQFLiUDqJjVjCfs/B53xQfV97ddxsRymES2viC2kjAm1Ete4TH\nCQmVltUBItHzI77AAAAAAAAAAAAAAAC/HC1yDSBBBBBBBBBBBBBdl0eiJwnB9lof\nMEnmOQLg177trb/AAAAAAAAAAAAAAACjUzBRMBBBBBBBBBBBBBBUI6+CKqKFz/Te\nZJppMNl/Dh6d9DAAAAAAAAAAAAAAAASUI6+CKqBBBBBBBBBBBBB/Dh6d9DAPBgNV\nHRMBAf8EBTADAQHAAAAAAAAAAAAAAAMCA4GMADBBBBBBBBBBBBB1MnGtQcl9yOMr\nhNR54VrDKgqLR+CAAAAAAAAAAAAAAAjmrwVyQ5BBBBBBBBBBBBBEufQVO/01+2sx\n86gzAkIB/4Ilf4RluN2/gqHYlVEDRZzsqbwVJBHLeNKsZBSJkhNNpJBwa2Ndl9/i\nu2tDk0KZFSAvRnqRAo9iDBUkIUI1ahA=\n-----END CERTIFICATE-----",
          key = "-----BEGIN EC PRIVATE KEY-----\nMIHcAgEBBEIARPKnAYLB54bxBvkDfqV4NfZ+Mxl79rlaYRB6vbWVwFpy+E2pSZBR\ndoCy1tHAB/uPo+QJyjIK82Zwa3Kq0i1D2QigBwYFK4EEACOhgYkDgYYABAHFKV0b\nPNEC2O3zbmpTCX4E2DF5yzCe9tAUuJQOomNWMJ+z8HnfFB9X3t13GxHKYRLa+ILa\nSMCbUS17hMcJCZWW1QEi0fMjvscH5Sx+oehR2OXeUL8cLXINI8GnnB315FFJqB2X\nR6InCcH2Wh8wSeY5AuDXvu2tv9g/PW9wIJmPuKSHMA==\n-----END EC PRIVATE KEY-----",
          tags = { "certificate-02", }
        },
        entity_tags = { "certificate-02", },
        entity_type = "certificate",
        errors = { {
            field = "cert",
            message = "invalid certificate: x509.new: error:688010A:asn1 encoding routines:asn1_item_embed_d2i:nested asn1 error:asn1/tasn_dec.c:349:",
            type = "field"
          } }
      },

      {
        entity = {
          hash_on = "ip",
          healthchecks = {
            active = {
              concurrency = -1,
              healthy = {
                interval = 0,
                successes = 0
              },
              http_path = "/",
              https_sni = "example.com",
              https_verify_certificate = true,
              timeout = 1,
              type = "http",
              unhealthy = {
                http_failures = 0,
                interval = 0
              }
            }
          },
          host_header = 123,
          name = "bad",
          tags = {
            "upstream-02"
          }
        },
        entity_name = "bad",
        entity_tags = {
          "upstream-02"
        },
        entity_type = "upstream",
        errors = {
          {
            field = "host_header",
            message = "expected a string",
            type = "field"
          },
          {
            field = "healthchecks.active.concurrency",
            message = "value should be between 1 and 2147483648",
            type = "field"
          },
        }
      },

      {
        entity = {
          config = {
            http_endpoint = "invalid::#//url"
          },
          name = "http-log",
          tags = {
            "global_plugin-01",
          }
        },
        entity_name = "http-log",
        entity_tags = {
          "global_plugin-01",
        },
        entity_type = "plugin",
        errors = {
          {
            field = "config.http_endpoint",
            message = "missing host in url",
            type = "field"
          }
        }
      },

      {
        entity = {
          not_allowed = true,
          tags = {
            "consumer-02"
          },
          username = "bobby_in_json_body"
        },
        entity_tags = {
          "consumer-02"
        },
        entity_type = "consumer",
        errors = {
          {
            field = "not_allowed",
            message = "unknown field",
            type = "field"
          }
        }
      },

      {
        entity = {
          name = "nope.route",
          protocols = {
            "tcp"
          },
          tags = {
            "route_service-02",
            "service-01",
          }
        },
        entity_name = "nope.route",
        entity_tags = {
          "route_service-02",
          "service-01",
        },
        entity_type = "route",
        errors = {
          {
            message = "must set one of 'sources', 'destinations', 'snis' when 'protocols' is 'tcp', 'tls' or 'udp'",
            type = "entity"
          }
        }
      },

      {
        entity = {
          host = "localhost",
          name = "nope",
          port = 1234,
          protocol = "nope",
          tags = {
            "service-01"
          }
        },
        entity_name = "nope",
        entity_tags = {
          "service-01"
        },
        entity_type = "service",
        errors = {
          {
            field = "protocol",
            message = SERVICE_PROTOCOL_ERROR,
            type = "field"
          }
        }
      },

      {
        entity = {
          host = "localhost",
          name = "mis-matched",
          path = "/path",
          protocol = "tcp",
          tags = {
            "service-02"
          }
        },
        entity_name = "mis-matched",
        entity_tags = {
          "service-02"
        },
        entity_type = "service",
        errors = {
          {
            field = "path",
            message = "value must be null",
            type = "field"
          },
          {
            message = "failed conditional validation given value of field 'protocol'",
            type = "entity"
          }
        }
      },

      {
        entity = {
          config = {
            not_endpoint = "anything"
          },
          name = "http-log",
          tags = {
            "route_service_plugin-01",
            "route_service-04",
            "service-03",
          }
        },
        entity_name = "http-log",
        entity_tags = {
          "route_service_plugin-01",
          "route_service-04",
          "service-03",
        },
        entity_type = "plugin",
        errors = {
          {
            field = "config.not_endpoint",
            message = "unknown field",
            type = "field"
          },
          {
            field = "config.http_endpoint",
            message = "required field missing",
            type = "field"
          }
        }
      },

      {
        entity = {
          config = {},
          name = "i-dont-exist",
          tags = {
            "service_plugin-01",
            "service-04",
          }
        },
        entity_name = "i-dont-exist",
        entity_tags = {
          "service_plugin-01",
          "service-04",
        },
        entity_type = "plugin",
        errors = {
          {
            field = "name",
            message = "plugin 'i-dont-exist' not enabled; add it to the 'plugins' configuration property",
            type = "field"
          }
        }
      },

      {
        entity = {
          config = {
            deeply = {
              nested = {
                undefined = true
              }
            },
            port = 1234
          },
          name = "tcp-log",
          tags = {
            "service_plugin-02",
            "service-04",
          }
        },
        entity_name = "tcp-log",
        entity_tags = {
          "service_plugin-02",
          "service-04",
        },
        entity_type = "plugin",
        errors = {
          {
            field = "config.deeply",
            message = "unknown field",
            type = "field"
          },
          {
            field = "config.host",
            message = "required field missing",
            type = "field"
          }
        }
      },

      {
        entity = {
          cert = "",
          key = "",
          tags = {
            "service_client_certificate-01",
            "service-05",
          }
        },
        entity_tags = {
          "service_client_certificate-01",
          "service-05",
        },
        entity_type = "certificate",
        errors = {
          {
            field = "key",
            message = "length must be at least 1",
            type = "field"
          },
          {
            field = "cert",
            message = "length must be at least 1",
            type = "field"
          },
        },
      },

      {
        entity = {
          tags = {
            "upstream_target-02",
            "upstream-03",
          },
          target = "hostname:1.0"
        },
        entity_tags = {
          "upstream_target-02",
          "upstream-03",
        },
        entity_type = "target",
        errors = { {
            field = "target",
            message = "Invalid target ('hostname:1.0'); not a valid hostname or ip address",
            type = "field"
          } }
      },

    }

    validate(expect, post_config(input))
  end)

  it("flattens nested, non-entity field errors", function()
    local upstream = {
      name = "bad",
      tags = { tags.upstream.next },
      hash_on = "ip",
      healthchecks = {
        active = {
          type = "http",
          http_path = "/",
          https_verify_certificate = true,
          https_sni = "example.com",
          timeout = 1,
          concurrency = -1,
          healthy = {
            interval = 0,
            successes = 0,
          },
          unhealthy = {
            interval = 0,
            http_failures = 0,
          },
        },
      },
      host_header = 123,
    }

    validate({
      {
        entity_type = "upstream",
        entity_name = "bad",
        entity_tags = { tags.upstream.last },
        entity = upstream,
        errors = {
          {
            field = "healthchecks.active.concurrency",
            message = "value should be between 1 and 2147483648",
            type = "field"
          },
          {
            field = "host_header",
            message = "expected a string",
            type = "field"
          },
        },
      },
    }, post_config({ upstreams = { upstream } }))
  end)

  it("flattens nested, entity field errors", function()
    local input = {
      services = {
        { name = "bad-client-cert",
          url = "https://localhost:1234",
          tags = { tags.service.next },
          -- error
          client_certificate = {
            cert = "",
            key = "",
            tags = { tags.service_client_certificate.next,
                     tags.service.last, },
          },

          routes = {
            { hosts = { "test" },
              paths = { "/" },
              protocols = { "http" },
              tags = { tags.service_route.next },
              plugins = {
                -- error
                {
                  name = "http-log",
                  config = { a = { b = { c = "def" } } },
                  tags = { tags.route_service_plugin.next },
                },
              },
            },

            -- error
            { hosts = { "invalid" },
              paths = { "/" },
              protocols = { "nope" },
              tags = { tags.service_route.next },
            },
          },

          plugins = {
            -- error
            {
              name = "i-do-not-exist",
              config = {},
              tags = { tags.service_plugin.next },
            },
          },
        },
      }
    }

    validate({
      {
        entity = {
          cert = "",
          key = "",
          tags = { "service_client_certificate-01", "service-01" }
        },
        entity_tags = { "service_client_certificate-01", "service-01" },
        entity_type = "certificate",
        errors = { {
            field = "cert",
            message = "length must be at least 1",
            type = "field"
          }, {
            field = "key",
            message = "length must be at least 1",
            type = "field"
          } }
      },

      {
        entity = {
          hosts = { "invalid" },
          paths = { "/" },
          protocols = { "nope" },
          tags = { "service_route-02" }
        },
        entity_tags = { "service_route-02" },
        entity_type = "route",
        errors = { {
            field = "protocols",
            message = "unknown type: nope",
            type = "field"
          } }
      },

      {
        entity = {
          config = { a = { b = { c = "def" } } },
          name = "http-log",
          tags = { "route_service_plugin-01" },
        },
        entity_name = "http-log",
        entity_type = "plugin",
        entity_tags = { "route_service_plugin-01" },
        errors = { {
          field = "config.a",
          message = "unknown field",
          type = "field"
        }, {
          field = "config.http_endpoint",
          message = "required field missing",
          type = "field"
        } }

      },

      {
        entity = {
          config = {},
          name = "i-do-not-exist",
          tags = { "service_plugin-01" }
        },
        entity_name = "i-do-not-exist",
        entity_tags = { "service_plugin-01" },
        entity_type = "plugin",
        errors = { {
          field = "name",
          message = "plugin 'i-do-not-exist' not enabled; add it to the 'plugins' configuration property",
          type = "field"
        } }
      },
    }, post_config(input))
  end)

  it("snis in certificates without certificate", function()
    local res = assert(client:send {
      method = "POST",
      path = "/config?flatten_errors=1",
      body = {
        _format_version = "1.1",
        consumers = {
          {
            username = "x",
            basicauth_credentials = {
              username = "x",
              password = "x",
            }
          }
        },
        certificates = {
          {
            cert = ssl_fixtures.cert,
            id = "d83994d2-c24c-4315-b431-ee76b6611dcb",
            key = ssl_fixtures.key,
            snis = {
              {
                name = "foo.example",
                id = "1c6e83b7-c9ad-40ac-94e8-52f5ee7bde44",
              },
            }
          }
        },
      },
      headers = {
        ["Content-Type"] = "application/json"
      }
    })
    
    local body = assert.response(res).has.status(400)
    local entities = cjson.decode(body)
    assert.equals("snis:required field missing:certificate", entities.flattened_errors[1].errors[1].message)
  end)

  it("flatten_errors1 when conflicting inputs", function()
    local conflicting_input = {
      _format_version = "3.0",
      consumers = {
        {
          username = "username1",
          tags = {
            "k8s-group:configuration.konghq.com",
            "k8s-version:v1",
            "k8s-kind:KongConsumer",
            "k8s-namespace:default",
            "k8s-name:consumer1"
          },
          basicauth_credentials = {
            {
              username = "username1",
              password = "password",
              tags = {
                "k8s-group:",
                "k8s-version:v1",
                "k8s-kind:Secret",
                "k8s-namespace:default",
                "k8s-name:basic-1"
              }
            },
            {
              username = "username1",
              password = "password",
              tags = {
                "k8s-group:",
                "k8s-version:v1",
                "k8s-kind:Secret",
                "k8s-namespace:default",
                "k8s-name:basic-2"
              }
            },
          }
        }
      }
    }
    validate({
      {
        entity = {
          username = "username1",
          password = "password",
          tags = {
            "k8s-group:",
            "k8s-version:v1",
            "k8s-kind:Secret",
            "k8s-namespace:default",
            "k8s-name:basic-2"
          }
        },
        entity_tags = {
          "k8s-group:",
          "k8s-version:v1",
          "k8s-kind:Secret",
          "k8s-namespace:default",
          "k8s-name:basic-2"
        },
        entity_type = "basicauth_credential",
        errors = { {
          message = "uniqueness violation: 'basicauth_credentials' entity with username set to 'username1' already declared",
          type = "entity",
          }
        }
      },
    }, post_config(conflicting_input))
  end)

  it("correctly handles nested entity errors", function()
    local consumers = {
      {
        id = "cdac30ee-cd7e-465c-99b6-84f3e4e17015",
        username = "consumer-01",
        tags = { "consumer-01" },
        basicauth_credentials = {
          {
            id = "089091f4-cb8b-48f5-8463-8319097be716",
            username = "user-01", password = "pwd",
            tags = { "consumer-01-credential-01" },
          },
          {
            id = "b1443d61-ccd9-4359-b82a-f37515442295",
            username = "user-11", password = "pwd",
            tags = { "consumer-01-credential-02" },
          },
          {
            id = "2603d010-edbe-4713-94ef-145e281cbf4c",
            username = "user-02", password = "pwd",
            tags = { "consumer-01-credential-03" },
          },
          {
            id = "760cf441-613c-48a2-b377-36aebc9f9ed0",
            -- unique violation!
            username = "user-11", password = "pwd",
            tags = { "consumer-01-credential-04" },
          }
        },
      },
      {
        id = "c0c021f5-dae1-4031-bcf6-42e3c4d9ced9",
        username = "consumer-02",
        tags = { "consumer-02" },
        basicauth_credentials = {
          {
            id = "d0cd1919-bb07-4c85-b407-f33feb74f6e2",
            username = "user-99", password = "pwd",
            tags = { "consumer-02-credential-01" },
          }
        },
      },
      {
        id = "9acb0270-73aa-4968-b9e4-a4924e4aced5",
        username = "consumer-03",
        tags = { "consumer-03" },
        basicauth_credentials = {
          {
            id = "7e8bcd10-cdcd-41f1-8c4d-9790d34aa67d",
            -- unique violation!
            username = "user-01", password = "pwd",
            tags = { "consumer-03-credential-01" },
          },
          {
            id = "7fe186bd-44e5-4b97-854d-85a24929889d",
            username = "user-33", password = "pwd",
            tags = { "consumer-03-credential-02" },
          },
          {
            id = "6547c325-5332-41fc-a954-d4972926cdb5",
            -- unique violation!
            username = "user-02", password = "pwd",
            tags = { "consumer-03-credential-03" },
          },
          {
            id = "e091a955-9ee1-4403-8d0a-a7f1f8bafaca",
            -- unique violation!
            username = "user-33", password = "pwd",
            tags = { "consumer-03-credential-04" },
          }
        },
      }
    }

    local input = {
      _format_version = "3.0",
      consumers = consumers,
    }

    validate({
      -- consumer 1 / credential 4
      {
        entity = {
          consumer = { id = consumers[1].id },
          id = consumers[1].basicauth_credentials[4].id,
          tags = consumers[1].basicauth_credentials[4].tags,
          password = "pwd",
          username = "user-11"
        },
        entity_id = consumers[1].basicauth_credentials[4].id,
        entity_tags = consumers[1].basicauth_credentials[4].tags,
        entity_type = "basicauth_credential",
        errors = { {
          message = "uniqueness violation: 'basicauth_credentials' entity with username set to 'user-11' already declared",
          type = "entity"
        } }
      },

      -- consumer 3 / credential 1
      {
        entity = {
          consumer = { id = consumers[3].id },
          id = consumers[3].basicauth_credentials[1].id,
          tags = consumers[3].basicauth_credentials[1].tags,
          password = "pwd",
          username = "user-01"
        },
        entity_id = consumers[3].basicauth_credentials[1].id,
        entity_tags = consumers[3].basicauth_credentials[1].tags,
        entity_type = "basicauth_credential",
        errors = { {
          message = "uniqueness violation: 'basicauth_credentials' entity with username set to 'user-01' already declared",
          type = "entity"
        } }
      },

      -- consumer 3 / credential 3
      {
        entity = {
          consumer = { id = consumers[3].id },
          id = consumers[3].basicauth_credentials[3].id,
          tags = consumers[3].basicauth_credentials[3].tags,
          password = "pwd",
          username = "user-02"
        },
        entity_id = consumers[3].basicauth_credentials[3].id,
        entity_tags = consumers[3].basicauth_credentials[3].tags,
        entity_type = "basicauth_credential",
        errors = { {
          message = "uniqueness violation: 'basicauth_credentials' entity with username set to 'user-02' already declared",
          type = "entity"
        } }
      },

      -- consumer 3 / credential 4
      {
        entity = {
          consumer = { id = consumers[3].id },
          id = consumers[3].basicauth_credentials[4].id,
          tags = consumers[3].basicauth_credentials[4].tags,
          password = "pwd",
          username = "user-33"
        },
        entity_id = consumers[3].basicauth_credentials[4].id,
        entity_tags = consumers[3].basicauth_credentials[4].tags,
        entity_type = "basicauth_credential",
        errors = { {
          message = "uniqueness violation: 'basicauth_credentials' entity with username set to 'user-33' already declared",
          type = "entity"
        } }
      },


    }, post_config(input))
  end)

  it("preserves IDs from the input", function()
    local id = "0175e0e8-3de9-56b4-96f1-b12dcb4b6691"
    local service = {
      id = id,
      name = "nope",
      host = "localhost",
      port = 1234,
      protocol = "nope",
      tags = { tags.service.next },
    }

    local flattened = post_config({ services = { service } })
    local got = get_by_tag(tags.service.last, flattened)
    assert.not_nil(got)

    assert.equals(id, got.entity_id)
    assert.equals(id, got.entity.id)
  end)

  it("preserves foreign keys from nested entity collections", function()
    local id = "cb019421-62c2-47a8-b714-d7567b114037"

    local service = {
      id = id,
      name = "test",
      host = "localhost",
      port = 1234,
      protocol = "nope",
      tags = { tags.service.next },
      routes = {
        {
          super_duper_invalid = true,
          tags = { tags.route.next },
        }
      },
    }

    local flattened = post_config({ services = { service } })
    local got = get_by_tag(tags.route.last, flattened)
    assert.not_nil(got)
    assert.is_table(got.entity)
    assert.is_table(got.entity.service)
    assert.same({ id = id }, got.entity.service)
  end)

  it("omits top-level entity_* fields if they are invalid", function()
    local service = {
      id = 1234,
      name = false,
      tags = { tags.service.next, { 1.5 }, },
      url = "http://localhost:1234",
    }

    local flattened = post_config({ services = { service } })
    local got = get_by_tag(tags.service.last, flattened)
    assert.not_nil(got)

    assert.is_nil(got.entity_id)
    assert.is_nil(got.entity_name)
    assert.is_nil(got.entity_tags)

    assert.equals(1234, got.entity.id)
    assert.equals(false, got.entity.name)
    assert.same({ tags.service.last, { 1.5 }, }, got.entity.tags)
  end)


  it("drains errors from the top-level fields object", function()
    local function post(config, flatten)
      config._format_version = config._format_version or "3.0"

      local path = ("/config?flatten_errors=%s"):format(flatten or "off")

      local res = client:post(path, {
        body = config,
        headers = {
          ["Content-Type"] = "application/json"
        },
      })

      assert.response(res).has.status(400)
      return assert.response(res).has.jsonbody()
    end

    local input = {
      _format_version = "3.0",
      abnormal_extra_field = 123,
      services = {
        { name = "nope",
          host = "localhost",
          port = 1234,
          protocol = "nope",
          tags = { tags.service.next },
          routes = {
            { name = "valid.route",
              protocols = { "http", "https" },
              methods = { "GET" },
              hosts = { "test" },
              tags = { tags.route_service.next, tags.service.last },
            },

            { name = "nope.route",
              protocols = { "tcp" },
              tags = { tags.route_service.next, tags.service.last },
            }
          },
        },

        { name = "mis-matched",
          host = "localhost",
          protocol = "tcp",
          path = "/path",
          tags = { tags.service.next },

          routes = {
            { name = "invalid",
              protocols = { "http", "https" },
              hosts = { "test" },
              methods = { "GET" },
              tags = { tags.route_service.next, tags.service.last },
            },
          },
        },

        { name = "okay",
          url = "http://localhost:1234",
          tags = { tags.service.next },
          routes = {
            { name = "probably-valid",
              protocols = { "http", "https" },
              methods = { "GET" },
              hosts = { "test" },
              tags = { tags.route_service.next, tags.service.last },
              plugins = {
                { name = "http-log",
                  config = { not_endpoint = "anything" },
                  tags = { tags.route_service_plugin.next,
                           tags.route_service.last,
                           tags.service.last, },
                },
              },
            },
          },
        },
      },
    }

    local original = post(input, false)
    assert.same({
      abnormal_extra_field = "unknown field",
      services = {
        {
          protocol = "expected one of: grpc, grpcs, http, https, tcp, tls, tls_passthrough, udp",
          routes = {
            ngx.null,
            {
              ["@entity"] = {
                "must set one of 'sources', 'destinations', 'snis' when 'protocols' is 'tcp', 'tls' or 'udp'"
              }
            }
          }
        },
        {
          ["@entity"] = {
            "failed conditional validation given value of field 'protocol'"
          },
          path = "value must be null"
        },
        {
          routes = {
            {
              plugins = {
                {
                  config = {
                    http_endpoint = "required field missing",
                    not_endpoint = "unknown field"
                  }
                }
              }
            }
          }
        }
      }
    }, original.fields)
    assert.is_nil(original.flattened_errors)

    -- XXX: top-level fields are not currently flattened because they don't
    -- really have an `entity_type` that we can use... maybe something that
    -- we'll address later on.
    local flattened = post(input, true)
    assert.same({ abnormal_extra_field = "unknown field" }, flattened.fields)
    assert.equals(4, #flattened.flattened_errors,
                  "unexpected number of flattened errors")
  end)

  it("does not throw for invalid input - (#10767)", function()
    -- The problem with this input is that the user has attempted to associate
    -- two different plugin instances with the same `consumer.username`. The
    -- final error that is returned ("consumer.id / missing primary key") is
    -- somewhat nonsensical. That is okay, because the purpose of this test is
    -- really just to ensure that we don't throw a 500 error for this kind of
    -- input.
    --
    -- If at some later date we improve the flattening logic of the
    -- declarative config parser, this test may fail and require an update,
    -- as the "shape" of the error will likely be changed--hopefully to
    -- something that is more helpful to the end user.


    -- NOTE: the fact that the username is a UUID *should not* be assumed to
    -- have any real significance here. It was chosen to keep the test input
    -- 1-1 with the github issue that resulted this test. As of this writing,
    -- the test behaves exactly the same with any random string as it does
    -- with a UUID.
    local username      = "774f8446-6427-43f9-9962-ce7ab8097fe4"
    local consumer_id   = "68d5de9f-2211-5ed8-b827-22f57a492d0f"
    local service_name  = "default.nginx-sample-1.nginx-sample-1.80"
    local upstream_name = "nginx-sample-1.default.80.svc"

    local plugin = {
      name = "rate-limiting",
      consumer = username,
      config = {
        error_code = 429,
        error_message = "API rate limit exceeded",
        fault_tolerant = true,
        hide_client_headers = false,
        limit_by = "consumer",
        policy = "local",
        second = 2000,
      },
      enabled = true,
      protocols = {
        "grpc",
        "grpcs",
        "http",
        "https",
      },
      tags = {
        "k8s-name:nginx-sample-1-rate",
        "k8s-namespace:default",
        "k8s-kind:KongPlugin",
        "k8s-uid:5163972c-543d-48ae-b0f6-21701c43c1ff",
        "k8s-group:configuration.konghq.com",
        "k8s-version:v1",
      },
    }

    local input = {
      _format_version = "3.0",
      consumers = {
        {
          acls = {
            {
              group = "app",
              tags = {
                "k8s-name:app-acl",
                "k8s-namespace:default",
                "k8s-kind:Secret",
                "k8s-uid:f1c5661c-a087-4c4b-b545-2d8b3870d661",
                "k8s-version:v1",
              },
            },
          },

          basicauth_credentials = {
            {
              password = "6ef728de-ba68-4e59-acb9-6e502c28ae0b",
              tags = {
                "k8s-name:app-cred",
                "k8s-namespace:default",
                "k8s-kind:Secret",
                "k8s-uid:aadd4598-2969-49ea-82ac-6ab5159e2f2e",
                "k8s-version:v1",
              },
              username = username,
            },
          },

          id = consumer_id,
          tags = {
            "k8s-name:app",
            "k8s-namespace:default",
            "k8s-kind:KongConsumer",
            "k8s-uid:7ee19bea-72d5-402b-bf0f-f57bf81032bf",
            "k8s-group:configuration.konghq.com",
            "k8s-version:v1",
          },
          username = username,
        },
      },

      plugins = {
        plugin,

        {
          config = {
            error_code = 429,
            error_message = "API rate limit exceeded",
            fault_tolerant = true,
            hide_client_headers = false,
            limit_by = "consumer",
            policy = "local",
            second = 2000,
          },
          consumer = username,
          enabled = true,
          name = "rate-limiting",
          protocols = {
            "grpc",
            "grpcs",
            "http",
            "https",
          },
          tags = {
            "k8s-name:nginx-sample-2-rate",
            "k8s-namespace:default",
            "k8s-kind:KongPlugin",
            "k8s-uid:89fa1cd1-78da-4c3e-8c3b-32be1811535a",
            "k8s-group:configuration.konghq.com",
            "k8s-version:v1",
          },
        },

        {
          config = {
            allow = {
              "nginx-sample-1",
              "app",
            },
            hide_groups_header = false,
          },
          enabled = true,
          name = "acl",
          protocols = {
            "grpc",
            "grpcs",
            "http",
            "https",
          },
          service = service_name,
          tags = {
            "k8s-name:nginx-sample-1",
            "k8s-namespace:default",
            "k8s-kind:KongPlugin",
            "k8s-uid:b9373482-32e1-4ac3-bd2a-8926ab728700",
            "k8s-group:configuration.konghq.com",
            "k8s-version:v1",
          },
        },
      },

      services = {
        {
          connect_timeout = 60000,
          host = upstream_name,
          id = "8c17ab3e-b6bd-51b2-b5ec-878b4d608b9d",
          name = service_name,
          path = "/",
          port = 80,
          protocol = "http",
          read_timeout = 60000,
          retries = 5,

          routes = {
            {
              https_redirect_status_code = 426,
              id = "84d45463-1faa-55cf-8ef6-4285007b715e",
              methods = {
                "GET",
              },
              name = "default.nginx-sample-1.nginx-sample-1..80",
              path_handling = "v0",
              paths = {
                "/sample/1",
              },
              preserve_host = true,
              protocols = {
                "http",
                "https",
              },
              regex_priority = 0,
              request_buffering = true,
              response_buffering = true,
              strip_path = false,
              tags = {
                "k8s-name:nginx-sample-1",
                "k8s-namespace:default",
                "k8s-kind:Ingress",
                "k8s-uid:916a6e5a-eebe-4527-a78d-81963eb3e043",
                "k8s-group:networking.k8s.io",
                "k8s-version:v1",
              },
            },
          },
          tags = {
            "k8s-name:nginx-sample-1",
            "k8s-namespace:default",
            "k8s-kind:Service",
            "k8s-uid:f7cc87f4-d5f7-41f8-b4e3-70608017e588",
            "k8s-version:v1",
          },
          write_timeout = 60000,
        },
      },

      upstreams = {
        {
          algorithm = "round-robin",
          name = upstream_name,
          tags = {
            "k8s-name:nginx-sample-1",
            "k8s-namespace:default",
            "k8s-kind:Service",
            "k8s-uid:f7cc87f4-d5f7-41f8-b4e3-70608017e588",
            "k8s-version:v1",
          },
          targets = {
            {
              target = "nginx-sample-1.default.svc:80",
            },
          },
        },
      },
    }

    local flattened = post_config(input)
    validate({
      {
        entity_type = "plugin",
        entity_name = plugin.name,
        entity_tags = plugin.tags,
        entity      = plugin,

        errors = {
          {
            field   = "consumer.id",
            message = "missing primary key",
            type    = "field",
          }
        },
      },
    }, flattened)
  end)
  it("origin error do not loss when enable flatten_errors - (#12167)", function()
    local input = {
      _format_version = "3.0",
      consumers = {
        {
          id = "a73dc9a7-93df-584d-97c0-7f41a1bbce3d",
          username = "test-consumer-1",
          tags =  { "consumer-1" },
        },
        {
          id = "a73dc9a7-93df-584d-97c0-7f41a1bbce32",
          username = "test-consumer-1",
          tags =  { "consumer-2" },
        },
      },
    }
    local flattened = post_config(input)
    validate({
      {
        entity_type = "consumer",
        entity_id   = "a73dc9a7-93df-584d-97c0-7f41a1bbce32",
        entity_name = nil,
        entity_tags = { "consumer-2" },
        entity      =  {
          id = "a73dc9a7-93df-584d-97c0-7f41a1bbce32",
          username = "test-consumer-1",
          tags =  { "consumer-2" },
        },
        errors = {
          {
            type    = "entity",
            message = "uniqueness violation: 'consumers' entity with username set to 'test-consumer-1' already declared",
          }
        },
      },
    }, flattened)
  end)

  it("correctly handles duplicate upstream target errors", function()
    local target = {
      target = "10.244.0.12:80",
      weight = 1,
      tags   = { "target-1" },
    }
    -- this has the same <addr>:<port> tuple as the first target, so it will
    -- be assigned the same id
    local dupe_target = kong_table.deep_copy(target)
    dupe_target.tags = { "target-2" }

    local input = {
      _format_version = "3.0",
      services = {
        {
          connect_timeout = 60000,
          host = "httproute.default.httproute-testing.0",
          id = "4e3cb785-a8d0-5866-aa05-117f7c64f24d",
          name = "httproute.default.httproute-testing.0",
          port = 8080,
          protocol = "http",
          read_timeout = 60000,
          retries = 5,
          routes = {
            {
              https_redirect_status_code = 426,
              id = "073fc413-1c03-50b4-8f44-43367c13daba",
              name = "httproute.default.httproute-testing.0.0",
              path_handling = "v0",
              paths = {
                "~/httproute-testing$",
                "/httproute-testing/",
              },
              preserve_host = true,
              protocols = {
                "http",
                "https",
              },
              strip_path = true,
              tags = {},
            },
          },
          tags = {},
          write_timeout = 60000,
        },
      },
      upstreams = {
        {
          algorithm = "round-robin",
          name = "httproute.default.httproute-testing.0",
          id   = "e9792964-6797-482c-bfdf-08220a4f6832",
          tags = {
            "k8s-name:httproute-testing",
            "k8s-namespace:default",
            "k8s-kind:HTTPRoute",
            "k8s-uid:f9792964-6797-482c-bfdf-08220a4f6839",
            "k8s-group:gateway.networking.k8s.io",
            "k8s-version:v1",
          },
          targets = {
            {
              target = "10.244.0.11:80",
              weight = 1,
            },
            {
              target = "10.244.0.12:80",
              weight = 1,
            },
          },
        },
        {
          algorithm = "round-robin",
          name = "httproute.default.httproute-testing.1",
          id   = "f9792964-6797-482c-bfdf-08220a4f6839",
          tags = {
            "k8s-name:httproute-testing",
            "k8s-namespace:default",
            "k8s-kind:HTTPRoute",
            "k8s-uid:f9792964-6797-482c-bfdf-08220a4f6839",
            "k8s-group:gateway.networking.k8s.io",
            "k8s-version:v1",
          },
          targets = {
            target,
            dupe_target,
          },
        },
      },
    }

    local flattened = post_config(input)
    local entry = get_by_tag(dupe_target.tags[1], flattened)
    assert.not_nil(entry, "no error for duplicate target in the response")

    -- sanity
    assert.same(dupe_target.tags, entry.entity_tags)

    assert.is_table(entry.errors, "missing entity errors table")
    assert.equals(1, #entry.errors, "expected 1 entity error")
    assert.is_table(entry.errors[1], "entity error is not a table")

    local e = entry.errors[1]
    assert.equals("entity", e.type)

    local exp = string.format("uniqueness violation: 'targets' entity with primary key set to '%s' already declared", entry.entity_id)

    assert.equals(exp, e.message)
  end)
end)


describe("Admin API (concurrency tests) #off", function()
  local client

  before_each(function()
    assert(helpers.start_kong({
      database = "off",
      nginx_worker_processes = 8,
      lmdb_map_size = LMDB_MAP_SIZE,
    }))

    client = assert(helpers.admin_client())
  end)

  after_each(function()
    helpers.stop_kong()

    if client then
      client:close()
    end
  end)

  it("succeeds with 200 and replaces previous cache if config fits in cache", function()
    -- stress test to check for worker concurrency issues
    for k = 1, 100 do
      if client then
        client:close()
        client = helpers.admin_client()
      end
      local res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = [[
          {
            "_format_version" : "1.1",
            "consumers" : [
              {
                "username" : "previous",
              },
            ],
          }
          ]],
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)
      client:close()

      local consumers = {}
      for i = 1, 10 do
        table.insert(consumers, [[
          {
            "username" : "bobby-]] .. k .. "-" .. i .. [[",
          }
        ]])
      end
      local config = [[
      {
        "_format_version" : "1.1",
        "consumers" : [
      ]] .. table.concat(consumers, ", ") .. [[
        ]
      }
      ]]

      client = assert(helpers.admin_client())
      res = assert(client:send {
        method = "POST",
        path = "/config",
        body = {
          config = config,
        },
        headers = {
          ["Content-Type"] = "application/json"
        }
      })

      assert.response(res).has.status(201)

      client:close()

      helpers.wait_until(function()
        client = assert(helpers.admin_client())
        res = assert(client:send {
          method = "GET",
          path = "/consumers/previous",
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        client:close()

        return res.status == 404
      end, WORKER_SYNC_TIMEOUT)

      helpers.wait_until(function()
        client = assert(helpers.admin_client())

        res = assert(client:send {
          method = "GET",
          path = "/consumers/bobby-" .. k .. "-10",
          headers = {
            ["Content-Type"] = "application/json"
          }
        })
        local body = res:read_body()
        client:close()

        if res.status ~= 200 then
          return false
        end

        local json = cjson.decode(body)
        return "bobby-" .. k .. "-10" == json.username
      end, WORKER_SYNC_TIMEOUT)
    end
  end)
end)

describe("Admin API #off with Unique Foreign #unique", function()
  local client

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      plugins = "unique-foreign",
      nginx_worker_processes = 1,
      lmdb_map_size = LMDB_MAP_SIZE,
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong()
  end)

  before_each(function()
    client = assert(helpers.admin_client())
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)


  it("unique foreign works with dbless", function()
    local config = [[
        _format_version: "1.1"
        unique_foreigns:
        - name: name
          unique_references:
          - note: note
      ]]

    local res = assert(client:send {
      method = "POST",
      path = "/config",
      body = {
        config = config,
      },
      headers = {
        ["Content-Type"] = "application/json"
      }
    })
    assert.res_status(201, res)

    local res = assert(client:get("/unique-foreigns"))
    local body = assert.res_status(200, res)
    local foreigns = cjson.decode(body)


    assert.equal(foreigns.data[1].name, "name")

    local res = assert(client:get("/unique-references"))
    local body = assert.res_status(200, res)
    local references = cjson.decode(body)

    assert.equal(references.data[1].note, "note")
    assert.equal(references.data[1].unique_foreign.id, foreigns.data[1].id)

    -- get default workspace id in lmdb
    local cmd = string.format(
      [[resty --main-conf "lmdb_environment_path %s/%s;" spec/fixtures/dump_lmdb_key.lua %q]],
      TEST_CONF.prefix, TEST_CONF.lmdb_environment_path,
      require("kong.constants").DECLARATIVE_DEFAULT_WORKSPACE_KEY)

    local handle = io.popen(cmd)
    local ws_id = handle:read("*a")
    handle:close()

    -- get unique_field_key
    local declarative = require "kong.db.declarative"
    local key = declarative.unique_field_key("unique_references", ws_id, "unique_foreign",
                                             foreigns.data[1].id, true)

    local cmd = string.format(
      [[resty --main-conf "lmdb_environment_path %s/%s;" spec/fixtures/dump_lmdb_key.lua %q]],
      TEST_CONF.prefix, TEST_CONF.lmdb_environment_path, key)

    local handle = io.popen(cmd)
    local unique_field_key = handle:read("*a")
    handle:close()

    assert.is_string(unique_field_key, "non-string result from unique lookup")
    assert.not_equals("", unique_field_key, "empty result from unique lookup")

    -- get the entity value
    local cmd = string.format(
      [[resty --main-conf "lmdb_environment_path %s/%s;" spec/fixtures/dump_lmdb_key.lua %q]],
      TEST_CONF.prefix, TEST_CONF.lmdb_environment_path, unique_field_key)

    local handle = io.popen(cmd)
    local result = handle:read("*a")
    handle:close()

    assert.not_equals("", result, "empty result from unique lookup")

    local cached_reference = assert(require("kong.db.declarative.marshaller").unmarshall(result))

    -- NOTE: we have changed internl LDMB storage format, and dao does not has this field(ws_id)
    cached_reference.ws_id = nil

    assert.same(cached_reference, references.data[1])

    local cache = {
      get = function(_, k)
        if k ~= "unique_references|" ..ws_id .. "|unique_foreign:" .. foreigns.data[1].id then
          return nil
        end

        return cached_reference
      end
    }

    mocker.setup(finally, {
      kong = {
        core_cache = cache,
      }
    })

    local _, db = helpers.get_db_utils("off", {}, {
      "unique-foreign"
    })

    local i = 1
    while true do
      local n, v = debug.getupvalue(db.unique_references.strategy.select_by_field, i)
      if not n then
        break
      end

      if n == "select_by_key" then
        local j = 1
        while true do
          local n, v = debug.getupvalue(v, j)
          if not n then
            break
          end

          if n == "kong" then
            v.core_cache = cache
            break
          end

          j = j + 1
        end

        break
      end

      i = i + 1
    end

    -- TODO: figure out how to mock LMDB in busted
    -- local unique_reference, err, err_t = db.unique_references:select_by_unique_foreign({
    --   id = foreigns.data[1].id,
    -- })

    -- assert.is_nil(err)
    -- assert.is_nil(err_t)

    -- assert.equal(references.data[1].id, unique_reference.id)
    -- assert.equal(references.data[1].note, unique_reference.note)
    -- assert.equal(references.data[1].unique_foreign.id, unique_reference.unique_foreign.id)
  end)
end)

describe("Admin API #off with cache key vs endpoint key #unique", function()
  local client

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      plugins = "cache-key-vs-endpoint-key",
      nginx_worker_processes = 1,
      lmdb_map_size = LMDB_MAP_SIZE,
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong()
  end)

  before_each(function()
    client = assert(helpers.admin_client())
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)

  it("prefers cache key rather than endpoint key from primary key uniqueness", function()
    local res = assert(client:send {
      method = "POST",
      path = "/config",
      body = {
        config = [[
        _format_version: "1.1"
        ck_vs_ek_testcase:
        - name: foo
          service: my_service
        - name: bar
          service: my_service

        services:
        - name: my_service
          url: http://example.com
          path: /
        ]],
      },
      headers = {
        ["Content-Type"] = "application/json"
      }
    })

    local body = assert.response(res).has.status(400)
    local json = cjson.decode(body)
    assert.same(14, json.code)
    assert.same("invalid declarative configuration", json.name)
    assert.matches("uniqueness violation: 'ck_vs_ek_testcase' entity " ..
                   "with primary key set to '.*' already declared",
                   json.fields.ck_vs_ek_testcase[2])
    assert.matches([[declarative config is invalid: ]] ..
                   [[{ck_vs_ek_testcase={%[2%]="uniqueness violation: ]] ..
                   [['ck_vs_ek_testcase' entity with primary key set to ]] ..
                   [['.*' already declared"}}]],
                   json.message)
  end)

end)

describe("Admin API #off worker_consistency=eventual", function()

  local client
  local WORKER_STATE_UPDATE_FREQ = 0.1

  lazy_setup(function()
    assert(helpers.start_kong({
      database = "off",
      lmdb_map_size = LMDB_MAP_SIZE,
      worker_consistency = "eventual",
      worker_state_update_frequency = WORKER_STATE_UPDATE_FREQ,
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong()
  end)

  before_each(function()
    client = assert(helpers.admin_client())
  end)

  after_each(function()
    if client then
      client:close()
    end
  end)

  it("does not increase timer usage (regression)", function()
    -- 1. configure a simple service
    local res = assert(client:send {
      method = "POST",
      path = "/config",
      body = helpers.unindent([[
        _format_version: '1.1'
        services:
        - name: konghq
          url: http://konghq.com
          path: /
        plugins:
        - name: prometheus
      ]]),
      headers = {
        ["Content-Type"] = "application/yaml"
      },
    })
    assert.response(res).has.status(201)

    -- 2. check the timer count
    res = assert(client:send {
      method  = "GET",
      path    = "/metrics",
    })
    local res_body = assert.res_status(200, res)
    local req1_pending_timers = assert.matches('kong_nginx_timers{state="pending"} %d+', res_body)
    local req1_running_timers = assert.matches('kong_nginx_timers{state="running"} %d+', res_body)
    req1_pending_timers = assert(tonumber(string.match(req1_pending_timers, "%d+")))
    req1_running_timers = assert(tonumber(string.match(req1_running_timers, "%d+")))

    -- 3. update the service
    res = assert(client:send {
      method = "POST",
      path = "/config",
      body = helpers.unindent([[
        _format_version: '1.1'
        services:
        - name: konghq
          url: http://konghq.com
          path: /install#kong-community
        plugins:
        - name: prometheus
      ]]),
      headers = {
        ["Content-Type"] = "application/yaml"
      },
    })
    assert.response(res).has.status(201)

    -- 4. check if timer count is still the same
    res = assert(client:send {
      method  = "GET",
      path    = "/metrics",
    })
    local res_body = assert.res_status(200, res)
    local req2_pending_timers = assert.matches('kong_nginx_timers{state="pending"} %d+', res_body)
    local req2_running_timers = assert.matches('kong_nginx_timers{state="running"} %d+', res_body)
    req2_pending_timers = assert(tonumber(string.match(req2_pending_timers, "%d+")))
    req2_running_timers = assert(tonumber(string.match(req2_running_timers, "%d+")))

    assert.equal(req1_pending_timers, req2_pending_timers)
    assert.equal(req1_running_timers, req2_running_timers)
  end)

end)
