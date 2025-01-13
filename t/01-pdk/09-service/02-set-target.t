use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: service.set_target() errors if host is not a string
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_target, 127001, 123)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
host must be a string
--- no_error_log
[error]



=== TEST 2: service.set_target() sets ngx.ctx.balancer_data.host
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {

        set $upstream_host '';

        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.balancer_data = {
                host = "foo.xyz"
            }

            local ok = pdk.service.set_target("example.test", 123)

            ngx.say(tostring(ok))
            ngx.say("host: ", ngx.ctx.balancer_data.host)
        }
    }
--- request
GET /t
--- response_body
nil
host: example.test
--- no_error_log
[error]



=== TEST 3: service.set_target() errors if port is not a number
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_target, "example.test", "foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
port must be an integer
--- no_error_log
[error]



=== TEST 4: service.set_target() errors if port is not an integer
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_target, "example.test", 123.4)

            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
port must be an integer
--- no_error_log
[error]



=== TEST 5: service.set_target() errors if port is out of range
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_target, "example.test", -1)
            ngx.say(err)
            local pok, err = pcall(pdk.service.set_target, "example.test", 70000)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
port must be an integer between 0 and 65535: given -1
port must be an integer between 0 and 65535: given 70000
--- no_error_log
[error]



=== TEST 6: service.set_target() sets the balancer port
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {

        set $upstream_host '';

        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.balancer_data = {
                port = 8000
            }

            local ok = pdk.service.set_target("example.test", 1234)

            ngx.say(tostring(ok))
            ngx.say("port: ", ngx.ctx.balancer_data.port)
        }
    }
--- request
GET /t
--- response_body
nil
port: 1234
--- no_error_log
[error]



=== TEST 7: service.set_target() sets the balancer IP if host is an IPv4 address
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {

        set $upstream_host '';

        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.balancer_data = {
                port = 8000
            }

            local ok = pdk.service.set_target("192.168.2.4", 1234)

            ngx.say(tostring(ok))
            ngx.say("ip: ", ngx.ctx.balancer_data.ip)
            ngx.say("host: ", ngx.ctx.balancer_data.host)
            ngx.say("port: ", ngx.ctx.balancer_data.port)
        }
    }
--- request
GET /t
--- response_body
nil
ip: 192.168.2.4
host: 192.168.2.4
port: 1234
--- no_error_log
[error]



=== TEST 8: service.set_target() sets the balancer IP if host is an IPv6 address
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {

        set $upstream_host '';

        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            ngx.ctx.balancer_data = {
                port = 8000
            }

            local ok = pdk.service.set_target("0:0:0:0:0:ffff:192.168.2.4", 1234)

            ngx.say(tostring(ok))
            ngx.say("ip: ", ngx.ctx.balancer_data.ip)
            ngx.say("host: ", ngx.ctx.balancer_data.host)
            ngx.say("port: ", ngx.ctx.balancer_data.port)
        }
    }
--- request
GET /t
--- response_body
nil
ip: 0:0:0:0:0:ffff:192.168.2.4
host: 0:0:0:0:0:ffff:192.168.2.4
port: 1234
--- no_error_log
[error]
