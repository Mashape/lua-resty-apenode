use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

$ENV{TEST_NGINX_NXSOCK} ||= html_dir();

plan tests => repeat_each() * (blocks() * 2);

run_tests();

__DATA__

=== TEST 1: verify phase checking in kong.service.request
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            return 200;
        }
    }

    init_worker_by_lua_block {

        phases = require("kong.pdk.private.phases").phases

        phase_check_module = "service.request"
        phase_check_data = {
            {
                method        = "enable_buffering",
                args          = { "http" },
                init_worker   = "forced false",
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_scheme",
                args          = { "http" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_method",
                args          = { "GET" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_path",
                args          = { "/" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_raw_query",
                args          = { "foo=bar&baz=bla" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_query",
                args          = { { foo = "bar", baz = "bla" } },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "clear_query_arg",
                args          = { "foo" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_header",
                args          = { "X-Foo", "bar" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "add_header",
                args          = { "X-Foo", "bar" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "clear_header",
                args          = { "X-Foo" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_headers",
                args          = { { ["X-Foo"] = "bar" } },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            }, {
                method        = "set_raw_body",
                args          = { "foo" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = false,
                body_filter   = false,
                log           = false,
                admin_api     = "forced false",
            }, {
                method        = "set_body",
                args          = { { foo = "bar" }, "application/json" },
                init_worker   = false,
                certificate   = "pending",
                rewrite       = true,
                access        = true,
                response      = "forced false",
                header_filter = false,
                body_filter   = false,
                log           = false,
                admin_api     = "forced false",
            },{
                method        = "disable_tls",
                args          = { },
                init_worker   = "forced false",
                certificate   = "pending",
                rewrite       = "forced false",
                access        = "forced false",
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            },{
                method        = "enable_tls",
                args          = { },
                init_worker   = "forced false",
                certificate   = "pending",
                rewrite       = "forced false",
                access        = "forced false",
                response      = "forced false",
                header_filter = "forced false",
                body_filter   = "forced false",
                log           = "forced false",
                admin_api     = "forced false",
            },
        }

        phase_check_functions(phases.init_worker)
    }

    #ssl_certificate_by_lua_block {
    #    phase_check_functions(phases.certificate)
    #}
}
--- config
    location /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;
        set $upstream_uri '/t';
        set $upstream_scheme 'http';

        rewrite_by_lua_block {
            phase_check_functions(phases.rewrite)
        }

        access_by_lua_block {
            phase_check_functions(phases.access)
            phase_check_functions(phases.response)
            phase_check_functions(phases.admin_api)
        }

        header_filter_by_lua_block {
            phase_check_functions(phases.header_filter)
        }

        body_filter_by_lua_block {
            phase_check_functions(phases.body_filter)
        }

        log_by_lua_block {
            phase_check_functions(phases.log)
        }
    }
--- request
GET /t
--- no_error_log
[error]
