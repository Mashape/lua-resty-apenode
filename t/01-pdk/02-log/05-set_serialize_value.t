use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

plan tests => 51;

run_tests();

__DATA__

=== TEST 1: kong.log.set_serialize_value() rejects parameters with the wrong format
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local ok, err = pcall(pdk.log.set_serialize_value, 1)
            pdk.log.info("key ", ok, " ", err)

            ok, err = pcall(pdk.log.set_serialize_value, "valid key", 1, { mode = "invalid" })
            pdk.log.info("mode ", ok, " ", err)
        }
    }

--- request
GET /t
--- no_response_body
--- error_log
key false key must be a string
mode false mode must be 'set', 'add' or 'replace'
--- no_error_log
[error]



=== TEST 2: kong.log.serialize() rejects invalid values, including self-referencial tables
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.log.set_serialize_value("with_function", { f = function() end })
            local ok, err = pcall(pdk.log.serialize, { kong = pdk })
            pdk.log.info("with_function ", ok, " ", err)

            local self_ref = {}
            self_ref.self_ref = self_ref
            pdk.log.set_serialize_value("self_ref", self_ref)
            local ok, err = pcall(pdk.log.serialize, { kong = pdk })
            pdk.log.info("self_ref ", ok, " ", err)
        }
    }
--- request
GET /t
--- no_response_body
--- error_log
with_function false value must be nil, a number, string, boolean or a non-self-referencial table containing numbers, string and booleans
self_ref false value must be nil, a number, string, boolean or a non-self-referencial table containing numbers, string and booleans
--- no_error_log
[error]



=== TEST 3: kong.log.set_serialize_value stores changes on ngx.ctx.serialize_values
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.log.set_serialize_value("val1", 1)
            assert(#ngx.ctx.serialize_values == 1, "== 1 ")

            -- Supports several operations over the same variable
            pdk.log.set_serialize_value("val1", 2)
            assert(#ngx.ctx.serialize_values == 2, "== 2")

            -- Other variables also supported
            pdk.log.set_serialize_value("val2", 1)
            assert(#ngx.ctx.serialize_values == 3, "== 3")
        }
    }
--- request
GET /t
--- no_response_body
--- no_error_log
[error]



=== TEST 4: kong.log.set_serialize_value() sets, adds and replaces values with simple keys
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.log.set_serialize_value("val1", 1)
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("set new field works ", s.val1 == 1)

            pdk.log.set_serialize_value("val1", 2)
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("set existing value overrides it ", s.val1 == 2)

            pdk.log.set_serialize_value("val2", 1, { mode = "replace" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("replace new value changes nothing ", s.val2 == nil)

            pdk.log.set_serialize_value("val1", 3, { mode = "replace" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("replace existing value changes it ", s.val1 == 3)

            pdk.log.set_serialize_value("val3", 1, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add new value sets it ", s.val3 == 1)

            pdk.log.set_serialize_value("val1", 4, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add existing value does not set it ", s.val1 == 3)
        }
    }

--- request
GET /t
--- no_response_body
--- error_log
set new field works true
set existing value overrides it true
replace new value changes nothing true
replace existing value changes it true
add new value sets it true
add existing value does not set it true
--- no_error_log
[error]



=== TEST 5: kong.log.set_serialize_value sets, adds and replaces values with keys with dots
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.log.set_serialize_value("foo.bar.baz", 1)
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("set new deep leaf adds it ", s.foo.bar.baz == 1)

            pdk.log.set_serialize_value("foo.bar.baz", 2)
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("set existing deep leaf changes it ", s.foo.bar.baz == 2)

            pdk.log.set_serialize_value("foo.bar2", 2)
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("set new branch adds it ", s.foo.bar2 == 2)

            pdk.log.set_serialize_value("foo2.bar.baz", 1, { mode = "replace" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("replace new deep leaf does not create anything ", s.foo2 == nil)

            pdk.log.set_serialize_value("foo.bar.baz2", 1, { mode = "replace" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("replace new deep leaf on existing branch does not add it ", s.foo.bar.baz2 == nil)

            pdk.log.set_serialize_value("foo.bar.baz", 3, { mode = "replace" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("replace existing deep leaf changes it ", s.foo.bar.baz == 3)

            pdk.log.set_serialize_value("foo3.bar.baz", 1, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add new deep leaf to root adds it ", s.foo3.bar.baz == 1)

            pdk.log.set_serialize_value("foo3.bar2", 1, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add new branch creates it ", s.foo3.bar2 == 1)

            pdk.log.set_serialize_value("foo.bar.baz", 3, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add existing deep leaf does not change it", s.foo.bar.baz == 2)

            pdk.log.set_serialize_value("foo4\\.bar\\.baz", 4, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add new branch with dots escaped creates it ", s["foo4.bar.baz"] == 4)

            pdk.log.set_serialize_value("foo4.bar\\.baz", 4, { mode = "add" })
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("add new branch with nested and dots escaped creates it ", s.foo4["bar.baz"] == 4)
        }
    }

--- request
GET /t
--- no_response_body
--- error_log
set new deep leaf adds it true
set existing deep leaf changes it true
set new branch adds it true
replace new deep leaf does not create anything true
replace new deep leaf on existing branch does not add it true
replace existing deep leaf changes it true
add new deep leaf to root adds it true
add new branch creates it true
add existing deep leaf does not change it
add new branch with dots escaped creates it true
add new branch with nested and dots escaped creates it true
--- no_error_log
[error]



=== TEST 6: kong.log.set_serialize_value() setting values to numbers, booleans, tables
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.log.set_serialize_value("string", "hello")
            pdk.log.set_serialize_value("number", 1)
            pdk.log.set_serialize_value("btrue", true)
            pdk.log.set_serialize_value("bfalse", false)
            pdk.log.set_serialize_value("complex", {
              str = "bye",
              n = 2,
              b1 = true,
              b2 = false,
              t = { k = "k" }
            })

            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("string ", s.string == "hello")
            pdk.log.info("number ", s.number == 1)
            pdk.log.info("btrue ", s.btrue == true)
            pdk.log.info("bfalse ", s.bfalse == false)
            pdk.log.info("complex ", s.complex.str == "bye" and
                                     s.complex.n == 2 and
                                     s.complex.b1 == true and
                                     s.complex.b2 == false and
                                     s.complex.t.k == "k")
        }
    }

--- request
GET /t
--- no_response_body
--- error_log
string true
number true
btrue true
bfalse true
complex true
--- no_error_log
[error]



=== TEST 7: kong.log.set_serialize_value() setting values to nil
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local old_get_headers = ngx.req.get_headers
            ngx.req.get_headers = function()
              local headers = old_get_headers()
              headers.foo = "bar"
              headers.authorization = "secret1"
              headers["proxy-authorization"] = "secret2"
              return headers
            end
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.log.set_serialize_value("str", "hello")
            pdk.log.set_serialize_value("str", nil)
            pdk.log.set_serialize_value("request.headers.foo", nil)
            pdk.log.set_serialize_value("request.headers.authorization", nil, { mode = "replace" })

            local s = pdk.log.serialize({ kong = pdk })

            pdk.log.info("str ", s.str == nil)
            pdk.log.info("request.headers.foo ", s.request.headers.foo == nil)
            pdk.log.info("request.headers.authorization ", s.request.headers.authorization == nil)
        }
    }

--- request
GET /t
--- no_response_body
--- error_log
str true
request.headers.foo true
request.headers.authorization true
--- no_error_log
[error]



=== TEST 8: kong.log.serialize() redactes authorization headers by default
--- http_config eval: $t::Util::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local old_get_headers = ngx.req.get_headers
            ngx.req.get_headers = function()
              local headers = old_get_headers()
              headers.foo = "bar"
              headers.authorization = "secret1"
              headers["proxy-authorization"] = "secret2"
              return headers
            end

            local PDK = require "kong.pdk"
            local pdk = PDK.new()
            local s = pdk.log.serialize({ kong = pdk })
            pdk.log.info("foo " .. s.request.headers.foo)
            pdk.log.info("authorization " .. s.request.headers.authorization)
            pdk.log.info("proxy-authorization " .. s.request.headers["proxy-authorization"])
            pdk.log.info("Authorization " .. s.request.headers.Authorization)
            pdk.log.info("Proxy-Authorization " .. s.request.headers["Proxy-Authorization"])
            pdk.log.info("PROXY_AUTHORIZATION " .. s.request.headers["PROXY_AUTHORIZATION"])
        }
    }

--- request
GET /t
--- no_response_body
--- error_log
foo bar
authorization REDACTED
proxy-authorization REDACTED
Authorization REDACTED
Proxy-Authorization REDACTED
PROXY_AUTHORIZATION REDACTED
--- no_error_log
[error]
