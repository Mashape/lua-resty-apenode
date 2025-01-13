use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: service.set_proxy_address() errors if ip is not a string
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_proxy_address, 127001, 123)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
ip must be an IPv4 or IPv6 address
--- no_error_log
[error]



=== TEST 2: service.set_proxy_address() sets ngx.ctx.balancer_data.ip and port
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

            local ok = pdk.service.set_proxy_address("10.0.0.11", 123)

            ngx.say(tostring(ok))
            ngx.say("host: ", ngx.ctx.balancer_data.host)
            ngx.say("ip: ", ngx.ctx.balancer_data.ip)
            ngx.say("port: ", ngx.ctx.balancer_data.port)
        }
    }
--- request
GET /t
--- response_body
nil
host: foo.xyz
ip: 10.0.0.11
port: 123
--- no_error_log
[error]



=== TEST 3: service.set_proxy_address() errors if port is not a number
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_proxy_address, "1.2.3.4", "foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
port must be an integer
--- no_error_log
[error]



=== TEST 4: service.set_proxy_address() errors if port is not an integer
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_proxy_address, "5.6.7.8", 123.4)

            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
port must be an integer
--- no_error_log
[error]



=== TEST 5: service.set_proxy_address() errors if port is out of range
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_proxy_address, "9.10.11.12", -1)
            ngx.say(err)
            local pok, err = pcall(pdk.service.set_proxy_address, "13.14.15.16", 70000)
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



=== TEST 6: service.set_proxy_address() sets the balancer port
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

            local ok = pdk.service.set_proxy_address("17.18.19.20", 1234)

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


=== TEST 7: service.set_proxy_address() errors if IP is not an IPv4 or IPv6 address
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local pok, err = pcall(pdk.service.set_proxy_address, "konghq.test", 443)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
ip must be an IPv4 or IPv6 address
--- no_error_log
[error]
