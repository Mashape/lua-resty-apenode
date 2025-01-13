local helpers = require "spec.helpers"
local cjson = require "cjson"
local pl_file = require "pl.file"

local PLUGIN_NAME = "ai-proxy"
local MOCK_PORT = helpers.get_available_port()

for _, strategy in helpers.all_strategies() do
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy  .. "]", function()
    local client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

      -- set up azure mock fixtures
      local fixtures = {
        http_mock = {},
        dns_mock = helpers.dns_mock.new({
          mocks_only = true,      -- don't fallback to "real" DNS
        }),
      }

      fixtures.dns_mock:A {
        name = "001-kong-t.openai.azure.com",
        address = "127.0.0.1",
      }

      -- openai llm driver will always send to this port, if var is set
      helpers.setenv("OPENAI_TEST_PORT", tostring(MOCK_PORT))

      fixtures.http_mock.azure = [[
        server {
            server_name azure;
            listen ]]..MOCK_PORT..[[;

            default_type 'application/json';


            location = "/llm/v1/chat/good" {
              content_by_lua_block {
                local pl_file = require "pl.file"
                local json = require("cjson.safe")

                local token = ngx.req.get_headers()["api-key"]
                if token == "azure-key" then
                  ngx.req.read_body()
                  local body, err = ngx.req.get_body_data()
                  body, err = json.decode(body)

                  if err or (body.messages == ngx.null) then
                    ngx.status = 400
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/bad_request.json"))
                  else
                    ngx.status = 200
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/good.json"))
                  end
                else
                  ngx.status = 401
                  ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/unauthorized.json"))
                end
              }
            }

            location = "/llm/v1/chat/bad_upstream_response" {
              content_by_lua_block {
                local pl_file = require "pl.file"
                local json = require("cjson.safe")

                local token = ngx.req.get_headers()["api-key"]
                if token == "azure-key" then
                  ngx.req.read_body()
                  local body, err = ngx.req.get_body_data()
                  body, err = json.decode(body)

                  if err or (body.messages == ngx.null) then
                    ngx.status = 400
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/bad_request.json"))
                  else
                    ngx.status = 200
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/bad_upstream_response.json"))
                  end
                else
                  ngx.status = 401
                  ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/unauthorized.json"))
                end
              }
            }

            location = "/llm/v1/chat/bad_request" {
              content_by_lua_block {
                local pl_file = require "pl.file"

                ngx.status = 400
                ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/bad_request.json"))
              }
            }

            location = "/llm/v1/chat/internal_server_error" {
              content_by_lua_block {
                local pl_file = require "pl.file"

                ngx.status = 500
                ngx.header["content-type"] = "text/html"
                ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/internal_server_error.html"))
              }
            }


            location = "/llm/v1/completions/good" {
              content_by_lua_block {
                local pl_file = require "pl.file"
                local json = require("cjson.safe")

                local token = ngx.req.get_headers()["api-key"]
                if token == "azure-key" then
                  ngx.req.read_body()
                  local body, err = ngx.req.get_body_data()
                  body, err = json.decode(body)

                  if err or (body.messages == ngx.null) then
                    ngx.status = 400
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-completions/responses/bad_request.json"))
                  else
                    ngx.status = 200
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-completions/responses/good.json"))
                  end
                else
                  ngx.status = 401
                  ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-completions/responses/unauthorized.json"))
                end
              }
            }

            location = "/llm/v1/completions/bad_request" {
              content_by_lua_block {
                local pl_file = require "pl.file"

                ngx.status = 400
                ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-completions/responses/bad_request.json"))
              }
            }

            location = "/openai/deployments/azure-other-instance/other/operation" {
              content_by_lua_block {
                local pl_file = require "pl.file"
                local json = require("cjson.safe")

                local token = ngx.req.get_headers()["api-key"]
                if token == "azure-key" then
                  ngx.req.read_body()
                  local body, err = ngx.req.get_body_data()
                  body, err = json.decode(body)

                  if err or (body.messages == ngx.null) then
                    ngx.status = 400
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/bad_request.json"))
                  else
                    ngx.status = 200
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/good.json"))
                  end
                else
                  ngx.status = 401
                  ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/unauthorized.json"))
                end
              }
            }

            location = "/override/path/completely" {
              content_by_lua_block {
                local pl_file = require "pl.file"
                local json = require("cjson.safe")

                local token = ngx.req.get_headers()["api-key"]
                if token == "azure-key" then
                  ngx.req.read_body()
                  local body, err = ngx.req.get_body_data()
                  body, err = json.decode(body)

                  if err or (body.messages == ngx.null) then
                    ngx.status = 400
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/bad_request.json"))
                  else
                    ngx.status = 200
                    ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/good.json"))
                  end
                else
                  ngx.status = 401
                  ngx.print(pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/responses/unauthorized.json"))
                end
              }
            }

        }
      ]]

      local empty_service = assert(bp.services:insert {
        name = "empty_service",
        host = "localhost", --helpers.mock_upstream_host,
        port = 8080, --MOCK_PORT,
        path = "/",
      })

      -- 200 chat good with one option
      local chat_good = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/chat/good" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_good.id },
        config = {
          route_type = "llm/v1/chat",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
            allow_override = true,
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/chat/good",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }

      local chat_good_no_allow_override = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/chat/good-no-allow-override" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_good_no_allow_override.id },
        config = {
          route_type = "llm/v1/chat",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
            allow_override = false,
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/chat/good",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- 200 chat bad upstream response with one option
      local chat_good = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/chat/bad_upstream_response" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_good.id },
        config = {
          route_type = "llm/v1/chat",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/chat/bad_upstream_response",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- 200 completions good with one option
      local completions_good = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/completions/good" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = completions_good.id },
        config = {
          route_type = "llm/v1/completions",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo-instruct",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/completions/good",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- 401 unauthorized
      local chat_401 = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/chat/unauthorized" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_401.id },
        config = {
          route_type = "llm/v1/chat",
          auth = {
            header_name = "api-key",
            header_value = "wrong-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/chat/good",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- 400 bad request chat
      local chat_400 = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/chat/bad_request" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_400.id },
        config = {
          route_type = "llm/v1/chat",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/chat/bad_request",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- 400 bad request completions
      local chat_400 = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/completions/bad_request" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_400.id },
        config = {
          route_type = "llm/v1/completions",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo-instruct",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/completions/bad_request",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- 500 internal server error
      local chat_500 = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "/azure/llm/v1/chat/internal_server_error" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_500.id },
        config = {
          route_type = "llm/v1/chat",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              upstream_url = "http://"..helpers.mock_upstream_host..":"..MOCK_PORT.."/llm/v1/chat/internal_server_error",
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- Override path with unique Azure operations
      local chat_override_path_from_params = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "~/ai/openai/deployments/(?<azure_deployment>[^#?/]+)(?<operation_path>[^#?]+)$" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_override_path_from_params.id },
        config = {
          route_type = "preserve",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              azure_instance = "001-kong-t",
              upstream_path = "$(uri_captures.operation_path)",
              azure_deployment_id = "$(uri_captures.azure_deployment)",
            },
          },
        },
      }
      --

      -- Override path completely
      local chat_override_path_completely = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "~/override/path/completely$" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_override_path_completely.id },
        config = {
          route_type = "preserve",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --

      -- Override path and expect 404
      local chat_override_path_incorrectly = assert(bp.routes:insert {
        service = empty_service,
        protocols = { "http" },
        strip_path = true,
        paths = { "~/override/path/incorrectly$" }
      })
      bp.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = chat_override_path_incorrectly.id },
        config = {
          route_type = "preserve",
          auth = {
            header_name = "api-key",
            header_value = "azure-key",
          },
          model = {
            name = "gpt-3.5-turbo",
            provider = "azure",
            options = {
              max_tokens = 256,
              temperature = 1.0,
              azure_instance = "001-kong-t",
              azure_deployment_id = "gpt-3.5-custom",
            },
          },
        },
      }
      --



      -- start kong
      assert(helpers.start_kong({
        -- set the strategy
        database   = strategy,
        -- use the custom test template to create a local mock server
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- make sure our plugin gets loaded
        plugins = "bundled," .. PLUGIN_NAME,
        -- write & load declarative config, only if 'strategy=off'
        declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
      }, nil, nil, fixtures))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then client:close() end
    end)

    describe("azure general", function()
      it("internal_server_error request", function()
        local r = client:get("/azure/llm/v1/chat/internal_server_error", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        local body = assert.res_status(500 , r)
        assert.is_not_nil(body)
      end)

      it("unauthorized request", function()
        local r = client:get("/azure/llm/v1/chat/unauthorized", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        local body = assert.res_status(401 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.is_truthy(json.error)
        assert.equals(json.error.code, "invalid_api_key")
      end)
    end)

    describe("azure llm/v1/chat", function()
      it("good request", function()
        local r = client:get("/azure/llm/v1/chat/good", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        local body = assert.res_status(200 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.equals(json.id, "chatcmpl-8T6YwgvjQVVnGbJ2w8hpOA17SeNy2")
        assert.equals(json.model, "gpt-3.5-turbo-0613")
        assert.equals(json.object, "chat.completion")

        assert.is_table(json.choices)
        assert.is_table(json.choices[1].message)
        assert.same({
          content = "The sum of 1 + 1 is 2.",
          role = "assistant",
        }, json.choices[1].message)
      end)

      it("good request with client right auth", function()
        local r = client:get("/azure/llm/v1/chat/good", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
            ["api-key"] = "azure-key",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        local body = assert.res_status(200 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.equals(json.id, "chatcmpl-8T6YwgvjQVVnGbJ2w8hpOA17SeNy2")
        assert.equals(json.model, "gpt-3.5-turbo-0613")
        assert.equals(json.object, "chat.completion")

        assert.is_table(json.choices)
        assert.is_table(json.choices[1].message)
        assert.same({
          content = "The sum of 1 + 1 is 2.",
          role = "assistant",
        }, json.choices[1].message)
      end)

      it("good request with client wrong auth", function()
        local r = client:get("/azure/llm/v1/chat/good", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
            ["api-key"] = "wrong",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        local body = assert.res_status(401 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.is_truthy(json.error)
        assert.equals(json.error.code, "invalid_api_key")
      end)

      it("good request with client right auth and no allow_override", function()
        local r = client:get("/azure/llm/v1/chat/good-no-allow-override", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
            ["api-key"] = "azure-key",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        local body = assert.res_status(200 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.equals(json.id, "chatcmpl-8T6YwgvjQVVnGbJ2w8hpOA17SeNy2")
        assert.equals(json.model, "gpt-3.5-turbo-0613")
        assert.equals(json.object, "chat.completion")

        assert.is_table(json.choices)
        assert.is_table(json.choices[1].message)
        assert.same({
          content = "The sum of 1 + 1 is 2.",
          role = "assistant",
        }, json.choices[1].message)
      end)

      it("good request with client wrong auth and no allow_override", function()
        local r = client:get("/azure/llm/v1/chat/good-no-allow-override", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
            ["api-key"] = "wrong",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        local body = assert.res_status(200 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.equals(json.id, "chatcmpl-8T6YwgvjQVVnGbJ2w8hpOA17SeNy2")
        assert.equals(json.model, "gpt-3.5-turbo-0613")
        assert.equals(json.object, "chat.completion")

        assert.is_table(json.choices)
        assert.is_table(json.choices[1].message)
        assert.same({
          content = "The sum of 1 + 1 is 2.",
          role = "assistant",
        }, json.choices[1].message)
      end)

      it("bad upstream response", function()
        local r = client:get("/azure/llm/v1/chat/bad_upstream_response", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- check we got internal server error
        local body = assert.res_status(500 , r)  
        local json = cjson.decode(body) 
        assert.equals(json.error.message, "transformation failed from type azure://llm/v1/chat: 'choices' not in llm/v1/chat response")
      end)

      it("bad request", function()
        local r = client:get("/azure/llm/v1/chat/bad_request", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/bad_request.json"),
        })

        local body = assert.res_status(400 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.is_truthy(json.error)
        assert.equals(json.error.message, "request body doesn't contain valid prompts")
      end)
    end)

    describe("azure llm/v1/completions", function()
      it("good request", function()
        local r = client:get("/azure/llm/v1/completions/good", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-completions/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        local body = assert.res_status(200 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.equals("cmpl-8TBeaJVQIhE9kHEJbk1RnKzgFxIqN", json.id)
        assert.equals("gpt-3.5-turbo-instruct", json.model)
        assert.equals("text_completion", json.object)
        assert.equals(r.headers["X-Kong-LLM-Model"], "azure/gpt-3.5-turbo-instruct")

        assert.is_table(json.choices)
        assert.is_table(json.choices[1])
        assert.same("\n\nI am a language model AI created by OpenAI. I can answer questions", json.choices[1].text)
      end)

      it("bad request", function()
        local r = client:get("/azure/llm/v1/completions/bad_request", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-completions/requests/bad_request.json"),
        })

        local body = assert.res_status(400 , r)
        local json = cjson.decode(body)

        -- check this is in the 'kong' response format
        assert.is_truthy(json.error)
        assert.equals("request body doesn't contain valid prompts", json.error.message)
      end)
    end)

    describe("azure preserve", function()
      it("override path from path params", function()
        local r = client:get("/ai/openai/deployments/azure-other-instance/other/operation", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        assert.res_status(200 , r)
      end)

      it("override path completely", function()
        local r = client:get("/override/path/completely", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- validate that the request succeeded, response status 200
        assert.res_status(200 , r)
      end)

      it("override path incorrectly", function()
        local r = client:get("/override/path/incorrectly", {
          headers = {
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
          },
          body = pl_file.read("spec/fixtures/ai-proxy/openai/llm-v1-chat/requests/good.json"),
        })

        -- expect it to 404 from the backend
        assert.res_status(404 , r)
      end)
    end)
  end)

end