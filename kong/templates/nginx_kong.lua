return [[
server_tokens off;

error_log ${{PROXY_ERROR_LOG}} ${{LOG_LEVEL}};

lua_package_path       '${{LUA_PACKAGE_PATH}};;';
lua_package_cpath      '${{LUA_PACKAGE_CPATH}};;';
lua_socket_pool_size   ${{LUA_SOCKET_POOL_SIZE}};
lua_socket_log_errors  off;
lua_max_running_timers 4096;
lua_max_pending_timers 16384;

include 'nginx-kong-inject.conf';

lua_shared_dict kong                        5m;
lua_shared_dict kong_locks                  8m;
lua_shared_dict kong_healthchecks           5m;
lua_shared_dict kong_cluster_events         5m;
lua_shared_dict kong_rate_limiting_counters 12m;
lua_shared_dict kong_core_db_cache          ${{MEM_CACHE_SIZE}};
lua_shared_dict kong_core_db_cache_miss     12m;
lua_shared_dict kong_db_cache               ${{MEM_CACHE_SIZE}};
lua_shared_dict kong_db_cache_miss          12m;
lua_shared_dict kong_secrets                5m;

> if new_dns_client then
lua_shared_dict kong_dns_cache              ${{RESOLVER_MEM_CACHE_SIZE}};
> end

underscores_in_headers on;
> if ssl_cipher_suite == 'old' then
lua_ssl_conf_command CipherString DEFAULT:@SECLEVEL=0;
proxy_ssl_conf_command CipherString DEFAULT:@SECLEVEL=0;
ssl_conf_command CipherString DEFAULT:@SECLEVEL=0;
grpc_ssl_conf_command CipherString DEFAULT:@SECLEVEL=0;
> end
> if ssl_ciphers then
ssl_ciphers ${{SSL_CIPHERS}};
> end

# injected nginx_http_* directives
> for _, el in ipairs(nginx_http_directives) do
$(el.name) $(el.value);
> end

uninitialized_variable_warn  off;

init_by_lua_block {
> if test and coverage then
    require 'luacov'
    jit.off()
> end -- test and coverage
    Kong = require 'kong'
    Kong.init()
}

init_worker_by_lua_block {
    Kong.init_worker()
}

exit_worker_by_lua_block {
    Kong.exit_worker()
}

> if (role == "traditional" or role == "data_plane") and #proxy_listeners > 0 then
log_format kong_log_format '$remote_addr - $remote_user [$time_local] '
                           '"$request" $status $body_bytes_sent '
                           '"$http_referer" "$http_user_agent" '
                           'kong_request_id: "$kong_request_id"';

# Load variable indexes
lua_kong_load_var_index default;

upstream kong_upstream {
    server 0.0.0.1;

    # injected nginx_upstream_* directives
> for _, el in ipairs(nginx_upstream_directives) do
    $(el.name) $(el.value);
> end

    balancer_by_lua_block {
        Kong.balancer()
    }
}

> if (role == "control_plane" or role == "traditional") and #admin_listeners > 0 then
upstream kong_admin_gui_api {
  server 0.0.0.1;

  balancer_by_lua_block {
    Kong.admin_gui_api_balancer()
  }
}
> end

server {
    server_name kong;
> for _, entry in ipairs(proxy_listeners) do
    listen $(entry.listener);
> end

> for _, entry in ipairs(proxy_listeners) do
> if entry.http2 then
    http2 on;
> break
> end
> end

    error_page 400 404 405 408 411 412 413 414 417 /kong_error_handler;
    error_page 494 =494                            /kong_error_handler;
    error_page 500 502 503 504                     /kong_error_handler;

    # Append the kong request id to the error log
    # https://github.com/Kong/lua-kong-nginx-module#lua_kong_error_log_request_id
    lua_kong_error_log_request_id $kong_request_id;

> if proxy_access_log_enabled then
>   if custom_proxy_access_log then
    access_log ${{PROXY_ACCESS_LOG}};
>   else
    access_log ${{PROXY_ACCESS_LOG}} kong_log_format;
>   end
> else
    access_log off;
> end

    error_log  ${{PROXY_ERROR_LOG}} ${{LOG_LEVEL}};

> if proxy_ssl_enabled then
> for i = 1, #ssl_cert do
    ssl_certificate     $(ssl_cert[i]);
    ssl_certificate_key $(ssl_cert_key[i]);
> end
    ssl_session_cache   shared:SSL:${{SSL_SESSION_CACHE_SIZE}};
    ssl_certificate_by_lua_block {
        Kong.ssl_certificate()
    }
    ssl_client_hello_by_lua_block {
        Kong.ssl_client_hello()
    }
> end

    # injected nginx_proxy_* directives
> for _, el in ipairs(nginx_proxy_directives) do
    $(el.name) $(el.value);
> end
> for _, ip in ipairs(trusted_ips) do
    set_real_ip_from $(ip);
> end

    rewrite_by_lua_block {
        Kong.rewrite()
    }

    access_by_lua_block {
        Kong.access()
    }

    header_filter_by_lua_block {
        Kong.header_filter()
    }

    body_filter_by_lua_block {
        Kong.body_filter()
    }

    log_by_lua_block {
        Kong.log()
    }

    location / {
        default_type                     '';

        set $ctx_ref                     '';
        set $upstream_te                 '';
        set $upstream_via                '';
        set $upstream_host               '';
        set $upstream_upgrade            '';
        set $upstream_connection         '';
        set $upstream_scheme             '';
        set $upstream_uri                '';
        set $upstream_x_forwarded_for    '';
        set $upstream_x_forwarded_proto  '';
        set $upstream_x_forwarded_host   '';
        set $upstream_x_forwarded_port   '';
        set $upstream_x_forwarded_path   '';
        set $upstream_x_forwarded_prefix '';
        set $kong_proxy_mode             'http';

        proxy_http_version      1.1;
        proxy_buffering          on;
        proxy_request_buffering  on;

        # injected nginx_location_* directives
> for _, el in ipairs(nginx_location_directives) do
        $(el.name) $(el.value);
> end

        proxy_set_header      TE                 $upstream_te;
        proxy_set_header      Via                $upstream_via;
        proxy_set_header      Host               $upstream_host;
        proxy_set_header      Upgrade            $upstream_upgrade;
        proxy_set_header      Connection         $upstream_connection;
        proxy_set_header      X-Forwarded-For    $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto  $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host   $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port   $upstream_x_forwarded_port;
        proxy_set_header      X-Forwarded-Path   $upstream_x_forwarded_path;
        proxy_set_header      X-Forwarded-Prefix $upstream_x_forwarded_prefix;
        proxy_set_header      X-Real-IP          $remote_addr;
> if enabled_headers_upstream["X-Kong-Request-Id"] then
        proxy_set_header      X-Kong-Request-Id  $kong_request_id;
> end
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
> if client_ssl then
        proxy_ssl_certificate ${{CLIENT_SSL_CERT}};
        proxy_ssl_certificate_key ${{CLIENT_SSL_CERT_KEY}};
> end
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location @unbuffered {
        internal;
        default_type         '';
        set $kong_proxy_mode 'unbuffered';

        proxy_http_version      1.1;
        proxy_buffering         off;
        proxy_request_buffering off;

        proxy_set_header      TE                 $upstream_te;
        proxy_set_header      Via                $upstream_via;
        proxy_set_header      Host               $upstream_host;
        proxy_set_header      Upgrade            $upstream_upgrade;
        proxy_set_header      Connection         $upstream_connection;
        proxy_set_header      X-Forwarded-For    $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto  $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host   $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port   $upstream_x_forwarded_port;
        proxy_set_header      X-Forwarded-Path   $upstream_x_forwarded_path;
        proxy_set_header      X-Forwarded-Prefix $upstream_x_forwarded_prefix;
        proxy_set_header      X-Real-IP          $remote_addr;
> if enabled_headers_upstream["X-Kong-Request-Id"] then
        proxy_set_header      X-Kong-Request-Id  $kong_request_id;
> end
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
> if client_ssl then
        proxy_ssl_certificate ${{CLIENT_SSL_CERT}};
        proxy_ssl_certificate_key ${{CLIENT_SSL_CERT_KEY}};
> end
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location @unbuffered_request {
        internal;
        default_type         '';
        set $kong_proxy_mode 'unbuffered';

        proxy_http_version      1.1;
        proxy_buffering          on;
        proxy_request_buffering off;

        proxy_set_header      TE                 $upstream_te;
        proxy_set_header      Via                $upstream_via;
        proxy_set_header      Host               $upstream_host;
        proxy_set_header      Upgrade            $upstream_upgrade;
        proxy_set_header      Connection         $upstream_connection;
        proxy_set_header      X-Forwarded-For    $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto  $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host   $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port   $upstream_x_forwarded_port;
        proxy_set_header      X-Forwarded-Path   $upstream_x_forwarded_path;
        proxy_set_header      X-Forwarded-Prefix $upstream_x_forwarded_prefix;
        proxy_set_header      X-Real-IP          $remote_addr;
> if enabled_headers_upstream["X-Kong-Request-Id"] then
        proxy_set_header      X-Kong-Request-Id  $kong_request_id;
> end
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
> if client_ssl then
        proxy_ssl_certificate ${{CLIENT_SSL_CERT}};
        proxy_ssl_certificate_key ${{CLIENT_SSL_CERT_KEY}};
> end
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location @unbuffered_response {
        internal;
        default_type         '';
        set $kong_proxy_mode 'unbuffered';

        proxy_http_version      1.1;
        proxy_buffering         off;
        proxy_request_buffering  on;

        proxy_set_header      TE                 $upstream_te;
        proxy_set_header      Via                $upstream_via;
        proxy_set_header      Host               $upstream_host;
        proxy_set_header      Upgrade            $upstream_upgrade;
        proxy_set_header      Connection         $upstream_connection;
        proxy_set_header      X-Forwarded-For    $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto  $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host   $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port   $upstream_x_forwarded_port;
        proxy_set_header      X-Forwarded-Path   $upstream_x_forwarded_path;
        proxy_set_header      X-Forwarded-Prefix $upstream_x_forwarded_prefix;
        proxy_set_header      X-Real-IP          $remote_addr;
> if enabled_headers_upstream["X-Kong-Request-Id"] then
        proxy_set_header      X-Kong-Request-Id  $kong_request_id;
> end
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
> if client_ssl then
        proxy_ssl_certificate ${{CLIENT_SSL_CERT}};
        proxy_ssl_certificate_key ${{CLIENT_SSL_CERT_KEY}};
> end
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location @grpc {
        internal;
        default_type         '';
        set $kong_proxy_mode 'grpc';

        grpc_set_header      TE                 $upstream_te;
        grpc_set_header      Via                $upstream_via;
        grpc_set_header      X-Forwarded-For    $upstream_x_forwarded_for;
        grpc_set_header      X-Forwarded-Proto  $upstream_x_forwarded_proto;
        grpc_set_header      X-Forwarded-Host   $upstream_x_forwarded_host;
        grpc_set_header      X-Forwarded-Port   $upstream_x_forwarded_port;
        grpc_set_header      X-Forwarded-Path   $upstream_x_forwarded_path;
        grpc_set_header      X-Forwarded-Prefix $upstream_x_forwarded_prefix;
        grpc_set_header      X-Real-IP          $remote_addr;
> if enabled_headers_upstream["X-Kong-Request-Id"] then
        grpc_set_header      X-Kong-Request-Id  $kong_request_id;
> end
        grpc_pass_header     Server;
        grpc_pass_header     Date;
        grpc_ssl_name        $upstream_host;
        grpc_ssl_server_name on;
> if client_ssl then
        grpc_ssl_certificate ${{CLIENT_SSL_CERT}};
        grpc_ssl_certificate_key ${{CLIENT_SSL_CERT_KEY}};
> end
        grpc_pass            $upstream_scheme://kong_upstream;
    }

    location = /kong_buffered_http {
        internal;
        default_type         '';
        set $kong_proxy_mode 'http';

        rewrite_by_lua_block       {
          -- ngx.location.capture will create a new nginx request,
          -- so the upstream ssl-related info attached to the `r` gets lost.
          -- we need to re-set them here to the new nginx request.
          local ctx = ngx.ctx
          local upstream_ssl = require("kong.runloop.upstream_ssl")

          upstream_ssl.set_service_ssl(ctx)
          upstream_ssl.fallback_upstream_client_cert(ctx)
        }
        access_by_lua_block        {;}
        header_filter_by_lua_block {;}
        body_filter_by_lua_block   {;}
        log_by_lua_block           {;}

        proxy_http_version 1.1;
        proxy_set_header      TE                 $upstream_te;
        proxy_set_header      Via                $upstream_via;
        proxy_set_header      Host               $upstream_host;
        proxy_set_header      Upgrade            $upstream_upgrade;
        proxy_set_header      Connection         $upstream_connection;
        proxy_set_header      X-Forwarded-For    $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto  $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host   $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port   $upstream_x_forwarded_port;
        proxy_set_header      X-Forwarded-Path   $upstream_x_forwarded_path;
        proxy_set_header      X-Forwarded-Prefix $upstream_x_forwarded_prefix;
        proxy_set_header      X-Real-IP          $remote_addr;
> if enabled_headers_upstream["X-Kong-Request-Id"] then
        proxy_set_header      X-Kong-Request-Id  $kong_request_id;
> end
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
> if client_ssl then
        proxy_ssl_certificate ${{CLIENT_SSL_CERT}};
        proxy_ssl_certificate_key ${{CLIENT_SSL_CERT_KEY}};
> end
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location = /kong_error_handler {
        internal;

        default_type                 '';

        rewrite_by_lua_block {;}
        access_by_lua_block  {;}

        content_by_lua_block {
            Kong.handle_error()
        }
    }
}
> end -- (role == "traditional" or role == "data_plane") and #proxy_listeners > 0

> if (role == "control_plane" or role == "traditional") and #admin_listeners > 0 then
server {
    charset UTF-8;
    server_name kong_admin;
> for _, entry in ipairs(admin_listeners) do
    listen $(entry.listener);
> end

> for _, entry in ipairs(admin_listeners) do
> if entry.http2 then
    http2 on;
> break
> end
> end

    access_log ${{ADMIN_ACCESS_LOG}};
    error_log  ${{ADMIN_ERROR_LOG}} ${{LOG_LEVEL}};

> if admin_ssl_enabled then
> for i = 1, #admin_ssl_cert do
    ssl_certificate     $(admin_ssl_cert[i]);
    ssl_certificate_key $(admin_ssl_cert_key[i]);
> end
    ssl_session_cache   shared:AdminSSL:10m;
> end

    # injected nginx_admin_* directives
> for _, el in ipairs(nginx_admin_directives) do
    $(el.name) $(el.value);
> end

    location / {
        default_type application/json;
        content_by_lua_block {
            Kong.admin_content()
        }
        header_filter_by_lua_block {
            Kong.admin_header_filter()
        }
    }

    location /robots.txt {
        return 200 'User-agent: *\nDisallow: /';
    }
}
> end -- (role == "control_plane" or role == "traditional") and #admin_listeners > 0

> if #status_listeners > 0 then
server {
    charset UTF-8;
    server_name kong_status;
> for _, entry in ipairs(status_listeners) do
    listen $(entry.listener);
> end

> for _, entry in ipairs(status_listeners) do
> if entry.http2 then
    http2 on;
> break
> end
> end

    access_log ${{STATUS_ACCESS_LOG}};
    error_log  ${{STATUS_ERROR_LOG}} ${{LOG_LEVEL}};

> if status_ssl_enabled then
> for i = 1, #status_ssl_cert do
    ssl_certificate     $(status_ssl_cert[i]);
    ssl_certificate_key $(status_ssl_cert_key[i]);
> end
    ssl_session_cache   shared:StatusSSL:1m;
> end

    # injected nginx_status_* directives
> for _, el in ipairs(nginx_status_directives) do
    $(el.name) $(el.value);
> end

    location / {
        default_type application/json;
        content_by_lua_block {
            Kong.status_content()
        }
        header_filter_by_lua_block {
            Kong.status_header_filter()
        }
    }

    location /robots.txt {
        return 200 'User-agent: *\nDisallow: /';
    }
}
> end

> if (role == "control_plane" or role == "traditional") and #admin_listeners > 0 and #admin_gui_listeners > 0 then
server {
    server_name kong_gui;
> for i = 1, #admin_gui_listeners do
    listen $(admin_gui_listeners[i].listener);
> end

> for _, entry in ipairs(admin_gui_listeners) do
> if entry.http2 then
    http2 on;
> break
> end
> end

> if admin_gui_ssl_enabled then
> for i = 1, #admin_gui_ssl_cert do
    ssl_certificate     $(admin_gui_ssl_cert[i]);
    ssl_certificate_key $(admin_gui_ssl_cert_key[i]);
> end
    ssl_protocols TLSv1.2 TLSv1.3;
> end

    client_max_body_size 10m;
    client_body_buffer_size 10m;

    types {
        text/html                             html htm shtml;
        text/css                              css;
        text/xml                              xml;
        image/gif                             gif;
        image/jpeg                            jpeg jpg;
        application/javascript                js;
        application/json                      json;
        image/png                             png;
        image/tiff                            tif tiff;
        image/x-icon                          ico;
        image/x-jng                           jng;
        image/x-ms-bmp                        bmp;
        image/svg+xml                         svg svgz;
        image/webp                            webp;
    }

    access_log ${{ADMIN_GUI_ACCESS_LOG}};
    error_log ${{ADMIN_GUI_ERROR_LOG}};

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    include nginx-kong-gui-include.conf;
}
> end -- of the (role == "control_plane" or role == "traditional") and #admin_listeners > 0 and #admin_gui_listeners > 0

> if role == "control_plane" then
server {
    charset UTF-8;
    server_name kong_cluster_listener;
> for _, entry in ipairs(cluster_listeners) do
    listen $(entry.listener) ssl;
> end

    access_log ${{ADMIN_ACCESS_LOG}};
    error_log  ${{ADMIN_ERROR_LOG}} ${{LOG_LEVEL}};

> if cluster_mtls == "shared" then
    ssl_verify_client   optional_no_ca;
> else
    ssl_verify_client   on;
    ssl_client_certificate ${{CLUSTER_CA_CERT}};
    ssl_verify_depth     4;
> end
    ssl_certificate     ${{CLUSTER_CERT}};
    ssl_certificate_key ${{CLUSTER_CERT_KEY}};
    ssl_session_cache   shared:ClusterSSL:10m;

    location = /v1/outlet {
        content_by_lua_block {
            Kong.serve_cluster_listener()
        }
    }

> if cluster_rpc then
    location = /v2/outlet {
        content_by_lua_block {
            Kong.serve_cluster_rpc_listener()
        }
    }
> end -- cluster_rpc is enabled
}
> end -- role == "control_plane"

server {
    charset UTF-8;
    server_name kong_worker_events;
    listen unix:${{SOCKET_PATH}}/${{WORKER_EVENTS_SOCK}};
    access_log off;
    location / {
        content_by_lua_block {
          require("resty.events.compat").run()
        }
    }
}
]]
