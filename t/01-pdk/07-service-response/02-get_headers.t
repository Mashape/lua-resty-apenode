use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

$ENV{TEST_NGINX_NXSOCK} ||= html_dir();

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: service.response.get_headers() returns an iterable table (non-buffered)
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header.Foo = "Hello"
            }
        }
    }
}
--- config
    location /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()
            ngx.arg[1] = "type: " .. type(headers) .. "\nfirst: " .. (next(headers) and "exists" or "nil")
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
type: table
first: exists
--- no_error_log
[error]



=== TEST 2: service.response.get_headers() returns an iterable table (buffered)
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header.Foo = "Hello"
            }
        }
    }
}
--- config
    location /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        access_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()
            pdk.service.request.enable_buffering()
            ngx.ctx.buffered_headers = {
                ["Foo"] = "Hello",
                ["Bar"] = "World",
                ["Accept"] = {
                    "application/json",
                    "text/html",
                }
            }

            ngx.header.h = "oops, i am here"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()
            ngx.arg[1] = "type: " .. type(headers) .. "\nfirst: " .. (next(headers) and "exists" or "nil")
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
type: table
first: exists
--- no_error_log
[error]



=== TEST 3: service.response.get_headers() returns service response headers only (unbuffered mode) BROKEN
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header.Foo = "Hello"
                ngx.header.Bar = "World"
                ngx.header.Accept = {
                    "application/json",
                    "text/html",
                }
            }
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        access_by_lua_block {
            ngx.header.h = "oops, i am here"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()

            ngx.arg[1] = "Foo: " .. headers.Foo .. "\n" ..
                         "Bar: " .. headers.Bar .. "\n" ..
                         "Accept: " .. table.concat(headers.Accept, ", ") .. "\n" ..
                         "NonUpstreamHeader: " .. (headers.h or "i must not be here") .. "\n" ..
                         "Buffered: " .. (ngx.ctx.buffered_proxying and "true" or "false")

            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
Foo: Hello
Bar: World
Accept: application/json, text/html
NonUpstreamHeader: i must not be here
Buffered: false
--- no_error_log
[error]



=== TEST 4: service.response.get_headers() returns service response headers only (unbuffered mode, max_headers) BROKEN
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header.Foo = "Hello"
                ngx.header.Bar = "World"
                ngx.header.Accept = {
                    "application/json",
                    "text/html",
                }
            }
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        access_by_lua_block {
            ngx.header.h = "oops, i am here"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers(10)

            ngx.arg[1] = "Foo: " .. headers.Foo .. "\n" ..
                         "Bar: " .. headers.Bar .. "\n" ..
                         "Accept: " .. table.concat(headers.Accept, ", ") .. "\n" ..
                         "NonUpstreamHeader: " .. (headers.h or "i must not be here") .. "\n" ..
                         "Buffered: " .. (ngx.ctx.buffered_proxying and "true" or "false")

            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
Foo: Hello
Bar: World
Accept: application/json, text/html
NonUpstreamHeader: i must not be here
Buffered: false
--- no_error_log
[error]



=== TEST 5: service.response.get_headers() returns service response headers (buffered mode) CORRECT
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
            }
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        access_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()
            pdk.service.request.enable_buffering()
            ngx.ctx.buffered_headers = {
                ["Foo"] = "Hello",
                ["Bar"] = "World",
                ["Accept"] = {
                    "application/json",
                    "text/html",
                }
            }

            ngx.header.h = "oops, i am here"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()

            ngx.arg[1] = "Foo: " .. headers.Foo .. "\n" ..
                         "Bar: " .. headers.Bar .. "\n" ..
                         "Accept: " .. table.concat(headers.Accept, ", ") .. "\n" ..
                         "NonUpstreamHeader: " .. (headers.h or "i must not be here") .. "\n" ..
                         "Buffered: " .. (ngx.ctx.buffered_proxying and "true" or "false")

            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
Foo: Hello
Bar: World
Accept: application/json, text/html
NonUpstreamHeader: i must not be here
Buffered: true
--- no_error_log
[error]



=== TEST 6: service.response.get_headers() returns service response headers (buffered mode, max_headers) CORRECT
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
            }
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        access_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()
            pdk.service.request.enable_buffering()
            ngx.ctx.buffered_headers = {
                ["Foo"] = "Hello",
                ["Bar"] = "World",
                ["Accept"] = {
                    "application/json",
                    "text/html",
                }
            }

            ngx.header.h = "oops, i am here"
        }

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers(10)

            ngx.arg[1] = "Foo: " .. headers.Foo .. "\n" ..
                         "Bar: " .. headers.Bar .. "\n" ..
                         "Accept: " .. table.concat(headers.Accept, ", ") .. "\n" ..
                         "NonUpstreamHeader: " .. (headers.h or "i must not be here") .. "\n" ..
                         "Buffered: " .. (ngx.ctx.buffered_proxying and "true" or "false")

            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
Foo: Hello
Bar: World
Accept: application/json, text/html
NonUpstreamHeader: i must not be here
Buffered: true
--- no_error_log
[error]



=== TEST 7: service.response.get_headers() returns a table
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            return 200;
        }
    }
}
--- config
    location /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.arg[1] = "type: " .. type(pdk.service.response.get_headers())
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
type: table
--- no_error_log
[error]



=== TEST 8: service.response.get_headers() returns service response headers
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header.Foo = "Hello"
                ngx.header.Bar = "World"
                ngx.header.Accept = {
                    "application/json",
                    "text/html",
                }
            }
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()

            ngx.arg[1] = "Foo: " .. headers.Foo .. "\n" ..
                         "Bar: " .. headers.Bar .. "\n" ..
                         "Accept: " .. table.concat(headers.Accept, ", ")


            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
Foo: Hello
Bar: World
Accept: application/json, text/html
--- no_error_log
[error]



=== TEST 9: service.response.get_headers() returns service response headers with case-insensitive metatable
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            content_by_lua_block {
                ngx.header["X-Foo-Header"] = "Hello"
            }
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()

            ngx.arg[1] = "X-Foo-Header: " .. headers["X-Foo-Header"] .. "\n" ..
                         "x-Foo-header: " .. headers["x-Foo-header"] .. "\n" ..
                         "x_foo_header: " .. headers["x_foo_header"] .. "\n" ..
                         "x_Foo_header: " .. headers["x_Foo_header"]

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



=== TEST 10: service.response.get_headers() fetches 100 headers max by default
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            default_type '';
            content_by_lua_block {
                for i = 1, 200 do
                    ngx.header["X-Header-" .. i] = "test"
                end
            }
        }
    }
}
--- config
    location = /t {
        default_type '';
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers = pdk.service.response.get_headers()

            local n = 0

            for k in pairs(headers) do
                n = n + 1
            end

            ngx.arg[1] = ngx.arg[1] .. "number of headers fetched <= 100? " .. (n <= 100 and "true" or "false")
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
number of headers fetched <= 100? true
--- no_error_log
[error]



=== TEST 11: service.response.get_headers() returns error when truncating
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            default_type '';
            content_by_lua_block {
                for i = 1, 200 do
                    ngx.header["X-Header-" .. i] = "test"
                end
            }
        }
    }
}
--- config
    location = /t {
        default_type '';
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local headers, err = pdk.service.response.get_headers()
            if err then
                ngx.arg[1] = err
                ngx.arg[2] = true
            end
        }
    }
--- request
GET /t
--- response_body chop
truncated
--- no_error_log
[error]



=== TEST 12: service.response.get_headers() fetches max_headers argument
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            default_type '';
            content_by_lua_block {
                for i = 1, 100 do
                    ngx.header["X-Header-" .. i] = "test"
                end
            }
        }
    }
}
--- config
    location = /t {
        default_type  '';
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local max_headers = 60
            local headers = pdk.service.response.get_headers(max_headers)

            local n = 0

            for k in pairs(headers) do
                n = n + 1
            end

            ngx.arg[1] = ngx.arg[1] .. "number of headers fetched <= max_headers? " .. (n <= max_headers and "true" or "false")
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
number of headers fetched <= max_headers? true
--- no_error_log
[error]



=== TEST 13: service.response.get_headers() raises error when trying to fetch with max_headers invalid value
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            return 200;
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local _, err = pcall(pdk.service.response.get_headers, "invalid")

            ngx.arg[1] = "error: " .. err
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
error: max_headers must be a number or nil
--- no_error_log
[error]



=== TEST 14: service.response.get_headers() raises error when trying to fetch with max_headers < 1
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            return 200;
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local _, err = pcall(pdk.service.response.get_headers, 0)

            ngx.arg[1] = "error: " .. err
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
error: max_headers must be >= 1
--- no_error_log
[error]



=== TEST 15: service.response.get_headers() raises error when trying to fetch with max_headers > 1000
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            return 200;
        }
    }
}
--- config
    location = /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;

        header_filter_by_lua_block {
            ngx.header.content_length = nil
        }

        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local _, err = pcall(pdk.service.response.get_headers, 1001)

            ngx.arg[1] = "error: " .. err
            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
error: max_headers must be <= 1000
--- no_error_log
[error]



=== TEST 16: service.response.get_headers() returns only service headers
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

            local headers = pdk.service.response.get_headers()

            ngx.arg[1] = "X-Service-Header: " .. headers["X-Service-Header"] .. "\n" ..
                         "X-Non-Service-Header: " .. type(headers["X-Non-Service-Header"]) .. "\n" ..
                         "X-Non-Service-Header: " .. ngx.header["X-Non-Service-Header"]

            ngx.arg[2] = true
        }
    }
--- request
GET /t
--- response_body chop
X-Service-Header: test
X-Non-Service-Header: nil
X-Non-Service-Header: test
--- no_error_log
[error]
