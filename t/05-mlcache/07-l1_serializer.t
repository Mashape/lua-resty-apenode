# vim:set ts=4 sts=4 sw=4 et ft=:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3) + 1;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm 1m;
    lua_shared_dict  ipc_shm 1m;

    init_by_lua_block {
        -- local verbose = true
        local verbose = false
        local outfile = "$Test::Nginx::Util::ErrLogFile"
        -- local outfile = "/tmp/v.log"
        if verbose then
            local dump = require "jit.dump"
            dump.on(nil, outfile)
        else
            local v = require "jit.v"
            v.on(outfile)
        end

        require "resty.core"
        -- jit.opt.start("hotloop=1")
        -- jit.opt.start("loopunroll=1000000")
        -- jit.off()
    }
};

run_tests();

__DATA__

=== TEST 1: l1_serializer is validated by the constructor
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local ok, err = pcall(mlcache.new, "my_mlcache", "cache_shm", {
                l1_serializer = false,
            })
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.l1_serializer must be a function
--- no_error_log
[error]



=== TEST 2: l1_serializer is called on L1+L2 cache misses
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
--- no_error_log
[error]



=== TEST 3: get() JITs when hit of scalar value coming from shm with l1_serializer
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(i)
                    return i + 2
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb_number()
                return 123456
            end

            for i = 1, 10e2 do
                local data = assert(cache:get("number", nil, cb_number))
                assert(data == 123458)

                cache.lru:delete("number")
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):18 loop\]/
--- no_error_log
[error]



=== TEST 4: l1_serializer is not called on L1 hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local calls = 0
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    calls = calls + 1
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            for i = 1, 3 do
                local data, err = cache:get("key", nil, function() return "foo" end)
                if not data then
                    ngx.log(ngx.ERR, err)
                    return
                end

                ngx.say(data)
            end

            ngx.say("calls: ", calls)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
transform("foo")
transform("foo")
calls: 1
--- no_error_log
[error]



=== TEST 5: l1_serializer is called on each L2 hit
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local calls = 0
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    calls = calls + 1
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            for i = 1, 3 do
                local data, err = cache:get("key", nil, function() return "foo" end)
                if not data then
                    ngx.log(ngx.ERR, err)
                    return
                end

                ngx.say(data)
                cache.lru:delete("key")
            end

            ngx.say("calls: ", calls)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
transform("foo")
transform("foo")
calls: 3
--- no_error_log
[error]



=== TEST 6: l1_serializer is called on boolean false hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return string.format("transform_boolean(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return false
            end

            local data, err = cache:get("key", nil, cb)
            if not data then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
transform_boolean("false")
--- no_error_log
[error]



=== TEST 7: l1_serializer is called in protected mode (L2 miss)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    error("cannot transform")
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer threw an error: .*?: cannot transform
--- no_error_log
[error]



=== TEST 8: l1_serializer is called in protected mode (L2 hit)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local called = false
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    if called then error("cannot transform") end
                    called = true
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(cache:get("key", nil, function() return "foo" end))
            cache.lru:delete("key")

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer threw an error: .*?: cannot transform
--- no_error_log
[error]



=== TEST 9: l1_serializer is not called for L2+L3 misses (no record)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local called = false
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    called = true
                    return string.format("transform(%s)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return nil end)
            if data ~= nil then
                ngx.log(ngx.ERR, "got a value for a L3 miss: ", tostring(data))
                return
            elseif err ~= nil then
                ngx.log(ngx.ERR, "got an error for a L3 miss: ", tostring(err))
                return
            end

            -- our L3 returned nil, we do not call the l1_serializer and
            -- we store the LRU nil sentinel value

            ngx.say("l1_serializer called for L3 miss: ", called)

            -- delete from LRU, and try from L2 again

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, function() error("not supposed to call") end)
            if data ~= nil then
                ngx.log(ngx.ERR, "got a value for a L3 miss: ", tostring(data))
                return
            elseif err ~= nil then
                ngx.log(ngx.ERR, "got an error for a L3 miss: ", tostring(err))
                return
            end

            ngx.say("l1_serializer called for L2 negative hit: ", called)
        }
    }
--- request
GET /t
--- response_body
l1_serializer called for L3 miss: false
l1_serializer called for L2 negative hit: false
--- no_error_log
[error]



=== TEST 10: l1_serializer is not supposed to return a nil value
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return nil
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = cache:get("key", nil, function() return "foo" end)
            assert(not ok, "get() should not return successfully")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer returned a nil value
--- no_error_log
[error]



=== TEST 11: l1_serializer can return nil + error
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return nil, "l1_serializer: cannot transform"
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end

            ngx.say("data: ", data)
        }
    }
--- request
GET /t
--- response_body
l1_serializer: cannot transform
data: nil
--- no_error_log
[error]



=== TEST 12: l1_serializer can be given as a get() argument
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", {
                l1_serializer = function(s)
                    return string.format("transform(%q)", s)
                end
            }, function() return "foo" end)
            if not data then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
--- no_error_log
[error]



=== TEST 13: l1_serializer as get() argument has precedence over the constructor one
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return string.format("constructor(%q)", s)
                end
            })

            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key1", {
                l1_serializer = function(s)
                    return string.format("get_argument(%q)", s)
                end
            }, function() return "foo" end)
            if not data then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)

            local data, err = cache:get("key2", nil, function() return "bar" end)
            if not data then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
get_argument("foo")
constructor("bar")
--- no_error_log
[error]



=== TEST 14: get() validates l1_serializer is a function
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.get, cache, "key", {
                l1_serializer = false,
            }, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.l1_serializer must be a function
--- no_error_log
[error]



=== TEST 15: set() calls l1_serializer
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                l1_serializer = function(s)
                    return string.format("transform(%q)", s)
                end
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = cache:set("key", nil, "value")
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local value, err = cache:get("key", nil, error)
            if not value then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(value)
        }
    }
--- request
GET /t
--- response_body
transform("value")
--- no_error_log
[error]



=== TEST 16: set() calls l1_serializer for boolean false values
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                l1_serializer = function(s)
                    return string.format("transform_boolean(%q)", s)
                end
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = cache:set("key", nil, false)
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local value, err = cache:get("key", nil, error)
            if not value then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(value)
        }
    }
--- request
GET /t
--- response_body
transform_boolean("false")
--- no_error_log
[error]



=== TEST 17: l1_serializer as set() argument has precedence over the constructor one
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                l1_serializer = function(s)
                    return string.format("constructor(%q)", s)
                end
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = cache:set("key", {
                l1_serializer = function(s)
                    return string.format("set_argument(%q)", s)
                end
            }, "value")
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local value, err = cache:get("key", nil, error)
            if not value then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(value)
        }
    }
--- request
GET /t
--- response_body
set_argument("value")
--- no_error_log
[error]



=== TEST 18: set() validates l1_serializer is a function
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.set, cache, "key", {
                l1_serializer = true
            }, "value")
            if not data then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.l1_serializer must be a function
--- no_error_log
[error]



=== TEST 19: l1_serializer fails will not store the cached vaule in L2
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local dict = ngx.shared.cache_shm
            local mlcache = require "kong.resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    error("cannot transform")
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)

            local v, err = dict:get("my_mlcachekey")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("no value in shm: ", v == nil )
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer threw an error: .*?: cannot transform
nil
no value in shm: true
--- no_error_log
[error]



=== TEST 20: l1_serializer fails will not store the cached vaule in L2 (L2 miss)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "kong.resty.mlcache"

            local called = false
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    if not called then
                        called = true
                        error("cannot transform")
                    end

                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)

            local data, err = cache:get("key", nil, function() return "bar" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer threw an error: .*?: cannot transform
nil
transform\("bar"\)
--- no_error_log
[error]
