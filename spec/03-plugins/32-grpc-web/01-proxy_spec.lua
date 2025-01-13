local cjson = require "cjson"
local helpers = require "spec.helpers"

-- returns nth byte (0: LSB, 3: MSB if 32-bit)
local function nbyt(x, n)
  return bit.band(bit.rshift(x, 8*n), 0xff)
end

local function be_bytes(x)
  return nbyt(x, 3), nbyt(x, 2), nbyt(x, 1), nbyt(x, 0)
end

for _, strategy in helpers.each_strategy() do

  describe("gRPC-Web Proxying [#" .. strategy .. "]", function()
    local proxy_client
    local proxy_client_ssl

    local HELLO_REQUEST_TEXT_BODY = "AAAAAAYKBGhleWE="
    local HELLO_REQUEST_BODY = ngx.decode_base64(HELLO_REQUEST_TEXT_BODY)
    local HELLO_RESPONSE_TEXT_BODY = "AAAAAAwKCmhlbGxvIGhleWE=" ..
        "gAAAAB5ncnBjLXN0YXR1czowDQpncnBjLW1lc3NhZ2U6DQo="
    local HELLO_RESPONSE_BODY = ngx.decode_base64("AAAAAAwKCmhlbGxvIGhleWE=") ..
        ngx.decode_base64("gAAAAB5ncnBjLXN0YXR1czowDQpncnBjLW1lc3NhZ2U6DQo=")

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      }, {
        "grpc-web",
      })

      local service1 = assert(bp.services:insert {
        name = "grpc",
        url = helpers.grpcbin_url,
      })

      local route1 = assert(bp.routes:insert {
        protocols = { "http", "https" },
        paths = { "/" },
        service = service1,
      })

      local route2 = assert(bp.routes:insert {
        protocols = { "http", "https" },
        paths = { "/prefix" },
        service = service1,
      })

      local mock_grpc_service = assert(bp.services:insert {
        name = "mock_grpc_service",
        url = "http://localhost:8765",
      })

      local mock_grpc_route = assert(bp.routes:insert {
        protocols = { "http" },
        hosts = { "grpc_mock.example" },
        service = mock_grpc_service,
        preserve_host = true,
      })

      assert(bp.plugins:insert {
        route = mock_grpc_route,
        name = "grpc-web",
        config = {
        },
      })

      assert(bp.plugins:insert {
        route = route1,
        name = "grpc-web",
        config = {
          proto = "spec/fixtures/grpc/hello.proto",
        },
      })

      assert(bp.plugins:insert {
        route = route2,
        name = "grpc-web",
        config = {
          proto = "spec/fixtures/grpc/hello.proto",
          pass_stripped_path = true,
        },
      })

      local fixtures = {
        http_mock = {}
      }
      fixtures.http_mock.my_server_block = [[
        server {
          server_name myserver;
          listen 8765;

          location ~ / {
            content_by_lua_block {
              local headers = ngx.req.get_headers()
              ngx.header.content_type = "application/grpc"
              ngx.header.received_host = headers["Host"]
              ngx.header.received_te = headers["te"]
            }
          }
        }
      ]]

      assert(helpers.start_kong({
        database = strategy,
        plugins = "bundled,grpc-web",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }, nil, nil, fixtures))
    end)

    before_each(function()
      proxy_client = helpers.proxy_client(1000)
      proxy_client_ssl = helpers.proxy_ssl_client(1000)
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    test("Sets 'TE: trailers'", function()
      local res, err = proxy_client:post("/", {
        headers = {
          ["Host"] = "grpc_mock.example",
          ["Content-Type"] = "application/grpc-web-text",
        },
      })

      assert.equal("trailers", res.headers["received-te"])
      assert.is_nil(err)
    end)

    test("Ignores user-agent TE", function()
      -- in grpc-web, kong acts as a grpc client on behalf of the client
      -- (which generally is a web-browser); as such, the Te header must be
      -- set by kong, which will append trailers to the response body
      local res, err = proxy_client:post("/", {
        headers = {
          ["Host"] = "grpc_mock.example",
          ["Content-Type"] = "application/grpc-web-text",
          ["TE"] = "chunked",
        },
      })

      assert.equal("trailers", res.headers["received-te"])
      assert.is_nil(err)
    end)

    test("Call gRCP-base64 via HTTP", function()
      local res, err = proxy_client:post("/hello.HelloService/SayHello", {
        headers = {
          ["Content-Type"] = "application/grpc-web-text",
          ["Content-Length"] = tostring(#HELLO_REQUEST_TEXT_BODY),
        },
        body = HELLO_REQUEST_TEXT_BODY,
      })

      assert.equal(HELLO_RESPONSE_TEXT_BODY, res:read_body())
      assert.is_nil(err)
    end)

    test("Call gRCP-base64 via HTTPS", function()
      local res, err = proxy_client_ssl:post("/hello.HelloService/SayHello", {
        headers = {
          ["Content-Type"] = "application/grpc-web-text",
          ["Content-Length"] = tostring(#HELLO_REQUEST_TEXT_BODY),
        },
        body = HELLO_REQUEST_TEXT_BODY,
      })

      assert.equal(HELLO_RESPONSE_TEXT_BODY, res:read_body())
      assert.is_nil(err)
    end)

    test("Call binary gRCP via HTTP", function()
      local res, err = proxy_client:post("/hello.HelloService/SayHello", {
        headers = {
          ["Content-Type"] = "application/grpc-web+proto",
          ["Content-Length"] = tostring(#HELLO_REQUEST_BODY),
        },
        body = HELLO_REQUEST_BODY,
      })

      assert.equal(HELLO_RESPONSE_BODY, res:read_body())
      assert.is_nil(err)
    end)

    test("Call binary gRCP via HTTPS", function()
      local res, err = proxy_client_ssl:post("/hello.HelloService/SayHello", {
        headers = {
          ["Content-Type"] = "application/grpc-web+proto",
          ["Content-Length"] = tostring(#HELLO_REQUEST_BODY),
        },
        body = HELLO_REQUEST_BODY,
      })

      assert.equal(HELLO_RESPONSE_BODY, res:read_body())
      assert.is_nil(err)
    end)

    test("Call gRPC-Web JSON via HTTP", function()
      local req = cjson.encode{ greeting = "heya" }
      req = string.char(0, be_bytes(#req)) .. req
      local res, err = proxy_client:post("/hello.HelloService/SayHello", {
        headers = {
          ["Content-Type"] = "application/grpc-web+json",
          ["Content-Length"] = tostring(#req)
        },
        body = req,
      })

      local resp = cjson.encode{ reply = "hello heya" }
      resp = string.char(0, be_bytes(#resp)) .. resp

      local trailer = "grpc-status:0\r\ngrpc-message:\r\n"
      trailer = string.char(0x80, be_bytes(#trailer)) .. trailer

      assert.equal(resp .. trailer, res:read_body())
      assert.is_nil(err)
    end)

     test("Call plain JSON via HTTP", function()
      local res, err = proxy_client:post("/hello.HelloService/SayHello", {
        headers = {
          ["Content-Type"] = "application/json",
        },
        body = cjson.encode{ greeting = "heya" },
      })

      assert.same({ reply = "hello heya" }, cjson.decode((res:read_body())))
      assert.is_nil(err)
    end)

     test("Pass stripped URI", function()
       local res, err = proxy_client:post("/prefix/hello.HelloService/SayHello", {
         headers = {
           ["Content-Type"] = "application/json",
         },
         body = cjson.encode{ greeting = "heya" },
       })

       assert.same({ reply = "hello heya" }, cjson.decode((res:read_body())))
       assert.is_nil(err)
     end)
 end)
end
