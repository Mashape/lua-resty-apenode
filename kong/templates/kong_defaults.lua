return [[
prefix = /usr/local/kong/
log_level = notice
proxy_access_log = logs/access.log
proxy_error_log = logs/error.log
proxy_stream_access_log = logs/access.log basic
proxy_stream_error_log = logs/error.log
admin_access_log = logs/admin_access.log
admin_error_log = logs/error.log
admin_gui_access_log = logs/admin_gui_access.log
admin_gui_error_log = logs/admin_gui_error.log
status_access_log = off
status_error_log = logs/status_error.log
vaults = bundled
plugins = bundled
port_maps = NONE
host_ports = NONE
anonymous_reports = on
proxy_server = NONE
proxy_server_ssl_verify = on
error_template_html = NONE
error_template_json = NONE
error_template_xml = NONE
error_template_plain = NONE
node_id = NONE

proxy_listen = 0.0.0.0:8000 reuseport backlog=16384, 0.0.0.0:8443 http2 ssl reuseport backlog=16384
stream_listen = off
admin_listen = 127.0.0.1:8001 reuseport backlog=16384, 127.0.0.1:8444 http2 ssl reuseport backlog=16384
admin_gui_listen = 0.0.0.0:8002, 0.0.0.0:8445 ssl
status_listen = 127.0.0.1:8007 reuseport backlog=16384
cluster_listen = 0.0.0.0:8005
cluster_control_plane = 127.0.0.1:8005
cluster_cert = NONE
cluster_cert_key = NONE
cluster_mtls = shared
cluster_ca_cert = NONE
cluster_server_name = NONE
cluster_data_plane_purge_delay = 1209600
cluster_ocsp = off
cluster_max_payload = 16777216
cluster_use_proxy = off
cluster_dp_labels = NONE
cluster_rpc = off
cluster_rpc_sync = off
cluster_cjson = off

lmdb_environment_path = dbless.lmdb
lmdb_map_size = 2048m
mem_cache_size = 128m
worker_events_max_payload = 65535
ssl_cert = NONE
ssl_cert_key = NONE
client_ssl = off
client_ssl_cert = NONE
client_ssl_cert_key = NONE
ssl_cipher_suite = intermediate
ssl_ciphers = NONE
ssl_protocols = TLSv1.2 TLSv1.3
ssl_prefer_server_ciphers = on
ssl_dhparam = NONE
ssl_session_tickets = on
ssl_session_timeout = 1d
ssl_session_cache_size = 10m
admin_ssl_cert = NONE
admin_ssl_cert_key = NONE
admin_gui_ssl_cert = NONE
admin_gui_ssl_cert_key = NONE
status_ssl_cert = NONE
status_ssl_cert_key = NONE
headers = server_tokens, latency_tokens, x-kong-request-id
headers_upstream = x-kong-request-id
trusted_ips = NONE
error_default_type = text/plain
upstream_keepalive_pool_size = 512
upstream_keepalive_max_requests = 10000
upstream_keepalive_idle_timeout = 60
allow_debug_header = off

nginx_user = kong kong
nginx_worker_processes = auto
nginx_daemon = on
nginx_main_daemon = on
nginx_main_user = kong kong
nginx_main_worker_processes = auto
nginx_main_worker_rlimit_nofile = auto
nginx_events_worker_connections = auto
nginx_events_multi_accept = on
nginx_http_charset = UTF-8
nginx_http_client_max_body_size = 10m
nginx_http_client_body_buffer_size = 8k
nginx_http_ssl_protocols = NONE
nginx_http_ssl_prefer_server_ciphers = NONE
nginx_http_ssl_dhparam = NONE
nginx_http_ssl_session_tickets = NONE
nginx_http_ssl_session_timeout = NONE
nginx_http_ssl_conf_command = NONE
nginx_http_proxy_ssl_conf_command = NONE
nginx_http_lua_ssl_conf_command = NONE
nginx_http_grpc_ssl_conf_command = NONE
nginx_http_lua_regex_match_limit = 100000
nginx_http_lua_regex_cache_max_entries = 8192
nginx_http_keepalive_requests = 10000
nginx_stream_ssl_conf_command = NONE
nginx_stream_proxy_ssl_conf_command = NONE
nginx_stream_lua_ssl_conf_command = NONE
nginx_stream_ssl_protocols = NONE
nginx_stream_ssl_prefer_server_ciphers = NONE
nginx_stream_ssl_dhparam = NONE
nginx_stream_ssl_session_tickets = NONE
nginx_stream_ssl_session_timeout = NONE
nginx_proxy_real_ip_header = X-Real-IP
nginx_proxy_real_ip_recursive = off
nginx_admin_client_max_body_size = 10m
nginx_admin_client_body_buffer_size = 10m

client_body_buffer_size = 8k
real_ip_header = X-Real-IP
real_ip_recursive = off

database = postgres

pg_host = 127.0.0.1
pg_port = 5432
pg_database = kong
pg_schema = NONE
pg_timeout = 5000
pg_user = kong
pg_password = NONE
pg_ssl = off
pg_ssl_verify = off
pg_max_concurrent_queries = 0
pg_semaphore_timeout = 60000
pg_keepalive_timeout = NONE
pg_pool_size = NONE
pg_backlog = NONE
_debug_pg_ttl_cleanup_interval = 300

pg_ro_host = NONE
pg_ro_port = NONE
pg_ro_database = NONE
pg_ro_schema = NONE
pg_ro_timeout = NONE
pg_ro_user = NONE
pg_ro_password = NONE
pg_ro_ssl = NONE
pg_ro_ssl_verify = NONE
pg_ro_max_concurrent_queries = NONE
pg_ro_semaphore_timeout = NONE
pg_ro_keepalive_timeout = NONE
pg_ro_pool_size = NONE
pg_ro_backlog = NONE

declarative_config = NONE
declarative_config_string = NONE

db_update_frequency = 5
db_update_propagation = 0
db_cache_ttl = 0
db_cache_neg_ttl = NONE
db_resurrect_ttl = 30
db_cache_warmup_entities = services

dns_resolver = NONE
dns_hostsfile = /etc/hosts
dns_order = LAST,SRV,A,CNAME
dns_valid_ttl = NONE
dns_stale_ttl = 3600
dns_cache_size = 10000
dns_not_found_ttl = 30
dns_error_ttl = 1
dns_no_sync = off

new_dns_client = off

resolver_address = NONE
resolver_hosts_file = /etc/hosts
resolver_family = A,SRV
resolver_valid_ttl = NONE
resolver_stale_ttl = 3600
resolver_lru_cache_size = 10000
resolver_mem_cache_size = 5m
resolver_error_ttl = 1

dedicated_config_processing = on
worker_consistency = eventual
worker_state_update_frequency = 5

router_flavor = traditional_compatible

lua_socket_pool_size = 256
lua_ssl_trusted_certificate = system
lua_ssl_verify_depth = 1
lua_ssl_protocols = TLSv1.2 TLSv1.3
lua_package_path = ./?.lua;./?/init.lua;
lua_package_cpath = NONE

lua_max_req_headers = 100
lua_max_resp_headers = 100
lua_max_uri_args = 100
lua_max_post_args = 100

role = traditional
kic = off
pluginserver_names = NONE

untrusted_lua = sandbox
untrusted_lua_sandbox_requires =
untrusted_lua_sandbox_environment =

admin_gui_url =
admin_gui_path = /
admin_gui_api_url = NONE

openresty_path =

opentelemetry_tracing = off
opentelemetry_tracing_sampling_rate = 0.01
tracing_instrumentations = off
tracing_sampling_rate = 0.01

wasm = off
wasm_filters_path = NONE
wasm_dynamic_module = NONE
wasm_filters = bundled,user

request_debug = on
request_debug_token =
]]
