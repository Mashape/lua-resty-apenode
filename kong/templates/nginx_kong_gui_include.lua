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

> if csp_connect_src then
>   -- [CSP] 'wasm-unsafe-eval' in script-src is required for atc-router-wasm
>   -- [CSP] TODO: 'unsafe-inline' is still required for style-src because of monaco-editor. See: https://github.com/microsoft/monaco-editor/issues/271
    add_header Content-Security-Policy "default-src 'self'; connect-src $(csp_connect_src); img-src 'self' data:; script-src 'self' 'wasm-unsafe-eval'; script-src-elem 'self' https://buttons.github.io/buttons.js; style-src 'self' 'unsafe-inline';";
> end

    add_header Referrer-Policy 'strict-origin-when-cross-origin';
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
