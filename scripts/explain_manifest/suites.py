import re
import os

wasm_filters = []
wasm_filter_variable_file = "../../build/openresty/wasmx/filters/variables.bzl"
if os.path.exists(wasm_filter_variable_file):
    from importlib.util import spec_from_loader, module_from_spec
    from importlib.machinery import SourceFileLoader

    wasm_filter_spec = spec_from_loader("wasm_filters", SourceFileLoader("wasm_filters", wasm_filter_variable_file))
    wasm_filter_module = module_from_spec(wasm_filter_spec)
    wasm_filter_spec.loader.exec_module(wasm_filter_module)
    wasm_filters = [f for filter in wasm_filter_module.WASM_FILTERS for f in filter["files"]]


def read_requirements(path=None):
    if not path:
        path = os.path.join(os.path.dirname(__file__), "..", "..", ".requirements")

    with open(path, "r") as f:
        lines = [re.findall("(.+)=([^# ]+)", d) for d in f.readlines()]
        return {l[0][0]: l[0][1].strip() for l in lines if l}

def common_suites(expect, libxcrypt_no_obsolete_api: bool = False, skip_libsimdjson_ffi: bool = False):
    # file existence
    expect("/usr/local/kong/include/google/protobuf/**.proto",
           "includes Google protobuf headers").exists()

    expect("/usr/local/kong/include/kong/**/*.proto",
           "includes Kong protobuf headers").exists()

    expect("/etc/kong/kong.conf.default", "includes default kong config").exists()

    expect("/etc/kong/kong.logrotate", "includes logrotate config").exists()

    expect("/etc/kong/kong.logrotate", "logrotate config should have 0644 permissions").file_mode.equals("0644")

    expect("/usr/local/kong/include/openssl/**.h", "includes OpenSSL headers").exists()

    # binary correctness
    expect("/usr/local/openresty/nginx/sbin/nginx", "nginx rpath should contain kong lib") \
        .rpath.equals("/usr/local/openresty/luajit/lib:/usr/local/kong/lib:/usr/local/openresty/lualib")

    expect("/usr/local/openresty/nginx/sbin/nginx", "nginx binary should contain dwarf info for dynatrace") \
        .has_dwarf_info.equals(True) \
        .has_ngx_http_request_t_DW.equals(True)

    expect("/usr/local/openresty/nginx/sbin/nginx", "nginx binary should link pcre statically") \
        .exported_symbols.contain("pcre2_general_context_free_8") \
        .exported_symbols.do_not().contain("pcre_free") \
        .needed_libraries.do_not().contain_match("libpcre.so.+") \
        .needed_libraries.do_not().contain_match(r"libpcre.+.so.+") \
        .needed_libraries.do_not().contain_match(r"libpcre2\-(8|16|32).so.+") \

    expect("/usr/local/openresty/nginx/sbin/nginx", "nginx should not be compiled with debug flag") \
        .nginx_compile_flags.do_not().match(r"with\-debug")

    expect("/usr/local/openresty/nginx/sbin/nginx", "nginx should include Kong's patches") \
        .functions \
        .contain("ngx_http_lua_kong_ffi_set_grpc_authority") \
        .contain("ngx_http_lua_ffi_balancer_enable_keepalive") \
        .contain("ngx_http_lua_kong_ffi_set_dynamic_log_level") \
        .contain("ngx_http_lua_kong_ffi_get_dynamic_log_level") \
        .contain("ngx_http_lua_kong_ffi_get_static_tag") \
        .contain("ngx_stream_lua_kong_ffi_get_static_tag") \
        .contain("ngx_http_lua_kong_ffi_get_full_client_certificate_chain") \
        .contain("ngx_http_lua_kong_ffi_disable_session_reuse") \
        .contain("ngx_http_lua_kong_ffi_set_upstream_client_cert_and_key") \
        .contain("ngx_http_lua_kong_ffi_set_upstream_ssl_trusted_store") \
        .contain("ngx_http_lua_kong_ffi_set_upstream_ssl_verify") \
        .contain("ngx_http_lua_kong_ffi_set_upstream_ssl_verify_depth") \
        .contain("ngx_stream_lua_kong_ffi_get_full_client_certificate_chain") \
        .contain("ngx_stream_lua_kong_ffi_disable_session_reuse") \
        .contain("ngx_stream_lua_kong_ffi_set_upstream_client_cert_and_key") \
        .contain("ngx_stream_lua_kong_ffi_set_upstream_ssl_trusted_store") \
        .contain("ngx_stream_lua_kong_ffi_set_upstream_ssl_verify") \
        .contain("ngx_stream_lua_kong_ffi_set_upstream_ssl_verify_depth") \
        .contain("ngx_http_lua_kong_ffi_var_get_by_index") \
        .contain("ngx_http_lua_kong_ffi_var_set_by_index") \
        .contain("ngx_http_lua_kong_ffi_var_load_indexes")

    expect("/usr/local/openresty/site/lualib/libatc_router.so", "ATC router so should have ffi module compiled") \
        .functions \
        .contain("router_execute")

    if not skip_libsimdjson_ffi:
        expect("/usr/local/openresty/site/lualib/libsimdjson_ffi.so", "simdjson should have ffi module compiled") \
            .functions \
            .contain("simdjson_ffi_state_new")

    if libxcrypt_no_obsolete_api:
        expect("/usr/local/openresty/nginx/sbin/nginx", "nginx linked with libxcrypt.so.2") \
            .needed_libraries.contain("libcrypt.so.2")
    else:
        expect("/usr/local/openresty/nginx/sbin/nginx", "nginx should link libxcrypt.so.1") \
            .needed_libraries.contain("libcrypt.so.1")

    expect("/usr/local/openresty/nginx/sbin/nginx", "nginx compiled with OpenSSL 3.4.x") \
        .nginx_compiled_openssl.matches(r"OpenSSL 3.4.\d") \
        .version_requirement.key("libssl.so.3").less_than("OPENSSL_3.5.0") \
        .version_requirement.key("libcrypto.so.3").less_than("OPENSSL_3.5.0") \

    expect("**/*.so", "dynamic libraries are compiled with OpenSSL 3.4.x") \
        .version_requirement.key("libssl.so.3").less_than("OPENSSL_3.5.0") \
        .version_requirement.key("libcrypto.so.3").less_than("OPENSSL_3.5.0") \

    ADA_VERSION = read_requirements()["ADA"]
    expect("**/*.so", "ada version is less than %s" % ADA_VERSION) \
        .version_requirement.key("libada.so").is_not().greater_than("ADA_%s" % ADA_VERSION) \

    # wasm filters
    for f in wasm_filters:
        expect("/usr/local/kong/wasm/%s" % f, "wasm filter %s is installed under kong/wasm" % f).exists()


def libc_libcpp_suites(expect, libc_max_version: str = None, libcxx_max_version: str = None, cxxabi_max_version: str = None):
    if libc_max_version:
        expect("**/*.so", "libc version is less than %s" % libc_max_version) \
            .version_requirement.key("libc.so.6").is_not().greater_than("GLIBC_%s" % libc_max_version) \
            .version_requirement.key("libdl.so.2").is_not().greater_than("GLIBC_%s" % libc_max_version) \
            .version_requirement.key("libpthread.so.0").is_not().greater_than("GLIBC_%s" % libc_max_version) \
            .version_requirement.key("librt.so.1").is_not().greater_than("GLIBC_%s" % libc_max_version) \

    if libcxx_max_version:
        expect("**/*.so", "glibcxx version is less than %s" % libcxx_max_version) \
            .version_requirement.key("libstdc++.so.6").is_not().greater_than("GLIBCXX_%s" % libcxx_max_version)

    if cxxabi_max_version:
        expect("**/*.so", "cxxabi version is less than %s" % cxxabi_max_version) \
            .version_requirement.key("libstdc++.so.6").is_not().greater_than("CXXABI_%s" % cxxabi_max_version)


def arm64_suites(expect):
    expect("**/*/**.so*", "Dynamic libraries are arm64 arch") \
        .arch.equals("AARCH64")

    expect("/usr/local/openresty/nginx/sbin/nginx", "Nginx is arm64 arch") \
        .arch.equals("AARCH64")

def docker_suites(expect):

    m = expect("/etc/passwd", "kong user exists") \
        .text_content.matches(r"kong:x:(\d+)").get_last_macthes()

    if m:
        kong_uid = int(m[0].groups()[0])


    m = expect("/etc/group", "kong group exists") \
        .text_content.matches(r"kong:x:(\d+)").get_last_macthes()

    if m:
        kong_gid = int(m[0].groups()[0])

    for path in ("/usr/local/kong/**", "/usr/local/bin/kong"):
        expect(path, "%s owned by kong:root" % path) \
            .uid.equals(kong_uid) \
            .gid.equals(0)

    for path in ("/usr/local/bin/luarocks",
                 "/usr/local/bin/luarocks-admin",
                 "/usr/local/etc/luarocks/**",
                 "/usr/local/lib/lua/**",
                 "/usr/local/lib/luarocks/**",
                 "/usr/local/openresty/**",
                 "/usr/local/share/lua/**"):
        expect(path, "%s owned by kong:kong" % path) \
            .uid.equals(kong_uid) \
            .gid.equals(kong_gid)

    expect((
        "/etc/ssl/certs/ca-certificates.crt", #Debian/Ubuntu/Gentoo
        "/etc/pki/tls/certs/ca-bundle.crt", #Fedora/RHEL 6
        "/etc/ssl/ca-bundle.pem", #OpenSUSE
        "/etc/pki/tls/cacert.pem", #OpenELEC
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", #CentOS/RHEL 7
        "/etc/ssl/cert.pem", #OpenBSD, Alpine
    ), "ca-certiticates exists") \
        .exists()
