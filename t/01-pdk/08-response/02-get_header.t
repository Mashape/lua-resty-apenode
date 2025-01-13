use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

$ENV{TEST_NGINX_NXSOCK} ||= html_dir();

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: response.get_header() returns first header when multiple is given with same name
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.header.Accept = {
                "application/json",
                "text/html",
            }
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil

            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.data = "content type header value: " .. pdk.response.get_header("Accept")
        }

        body_filter_by_lua_block {
            ngx.arg[1] = ngx.ctx.data
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
content type header value: application/json
--- no_error_log
[error]



=== TEST 2: response.get_header() returns values from case-insensitive metatable
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.header["X-Foo-Header"] = "Hello"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil

            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local data = {}

            data[1] = "X-Foo-Header: " .. pdk.response.get_header("X-Foo-Header")
            data[2] = "x-Foo-header: " .. pdk.response.get_header("x-Foo-header")
            data[3] = "x_foo_header: " .. pdk.response.get_header("x_foo_header")
            data[4] = "x_Foo_header: " .. pdk.response.get_header("x_Foo_header")

            ngx.ctx.data = table.concat(data, "\n")
        }

        body_filter_by_lua_block {
            ngx.arg[1] = ngx.ctx.data
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
X-Foo-Header: Hello
x-Foo-header: Hello
x_foo_header: Hello
x_Foo_header: Hello
--- no_error_log
[error]



=== TEST 3: response.get_header() returns nil when header is missing
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil

            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.data = "X-Missing: " .. type(pdk.response.get_header("X-Missing"))
        }

        body_filter_by_lua_block {
            ngx.arg[1] = ngx.ctx.data
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
X-Missing: nil
--- no_error_log
[error]



=== TEST 4: response.get_header() returns existing header will not limited by get_headers() default max_headers configuration
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            for i = 1, 100 do
                ngx.header["X-Header-" .. i] = "test"
            end

            ngx.header["Accept"] = "text/html"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil

            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.data = "accept header value: " .. type(pdk.response.get_header("Accept"))
        }

        body_filter_by_lua_block {
            ngx.arg[1] = ngx.ctx.data
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
accept header value: string
--- no_error_log
[error]



=== TEST 5: response.get_header() raises error when trying to fetch with invalid argument
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil

            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local ok, err = pcall(pdk.response.get_header)
            if not ok then
                ngx.ctx.err = err
            end
        }

        body_filter_by_lua_block {
            ngx.arg[1] = "error: " .. ngx.ctx.err
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
error: header name must be a string
--- no_error_log
[error]



=== TEST 6: response.get_header() returns not-only service header
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header["X-Service-Header"] = "test"
            }
        }
    }
}
--- config
    location = /t {
        access_by_lua_block {
            ngx.header["X-Non-Service-Header"] = "test"
        }

        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local get_header = pdk.response.get_header

            ngx.arg[1] = "X-Service-Header: "     .. get_header("X-Service-Header") .. "\n" ..
                         "X-Non-Service-Header: " .. get_header("X-Non-Service-Header")

            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
X-Service-Header: test
X-Non-Service-Header: test
--- no_error_log
[error]
