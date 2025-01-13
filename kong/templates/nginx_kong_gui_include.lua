return [[
> local admin_gui_rewrite = admin_gui_path ~= "/"
> local admin_gui_path_prefix = admin_gui_path
> if admin_gui_path == "/" then
>   admin_gui_path_prefix = ""
> end
location = $(admin_gui_path_prefix)/robots.txt {
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    return 200 'User-agent: *\nDisallow: /';
}

location = $(admin_gui_path_prefix)/kconfig.js {
    default_type application/javascript;

    gzip on;
    gzip_types application/javascript;
    expires -1;

    content_by_lua_block {
        Kong.admin_gui_kconfig_content()
    }
}

> if (role == "control_plane" or role == "traditional") and #admin_listeners > 0 then
location ~* $(admin_gui_path_prefix)/gateway/api {
    set_by_lua_block $backend {
        local utils = require "kong.admin_gui.utils"
        local listener = utils.select_listener(kong.configuration.admin_listeners, { ssl = true })
        if listener then
            return "https://kong_admin_gui_api"
        else
            return "http://kong_admin_gui_api"
        end
    }
    rewrite ^$(admin_gui_path_prefix)/gateway/api(/.*)$ $1 break;
    proxy_pass $backend;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
> end

location = $(admin_gui_path_prefix)/favicon.ico {
    root gui;

    try_files /favicon.ico =404;

    log_not_found off;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    expires 90d;
    add_header Cache-Control 'public';
    add_header X-Frame-Options 'sameorigin';
    add_header X-XSS-Protection '1; mode=block';
    add_header X-Content-Type-Options 'nosniff';
    add_header X-Permitted-Cross-Domain-Policies 'master-only';
    etag off;
}

location ~* ^$(admin_gui_path_prefix)(?<path>/.*\.(jpg|jpeg|png|gif|svg|ico|css|ttf|js)(\?.*)?)$ {
    root gui;

    try_files $path =404;

    log_not_found off;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    expires 90d;
    add_header Cache-Control 'public';
    add_header X-Frame-Options 'sameorigin';
    add_header X-XSS-Protection '1; mode=block';
    add_header X-Content-Type-Options 'nosniff';
    add_header X-Permitted-Cross-Domain-Policies 'master-only';
    etag off;

> if admin_gui_rewrite then
    sub_filter '/__km_base__/' '$(admin_gui_path)/';
> else
    sub_filter '/__km_base__/' '/';
> end
    sub_filter_once off;
    sub_filter_types *;
}

location ~* ^$(admin_gui_path_prefix)(?<path>/.*)?$ {
    root gui;

    try_files $path /index.html =404;

    log_not_found off;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    add_header Cache-Control 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0';
    add_header X-Frame-Options 'sameorigin';
    add_header X-XSS-Protection '1; mode=block';
    add_header X-Content-Type-Options 'nosniff';
    add_header X-Permitted-Cross-Domain-Policies 'master-only';
    etag off;

> if admin_gui_rewrite then
    sub_filter '/__km_base__/' '$(admin_gui_path)/';
> else
    sub_filter '/__km_base__/' '/';
> end
    sub_filter_once off;
    sub_filter_types *;

    log_by_lua_block {
        Kong.admin_gui_log()
    }
}
]]
