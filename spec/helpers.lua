------------------------------------------------------------------
-- Collection of utilities to help testing Kong features and plugins.
--
-- @copyright Copyright 2016-2022 Kong Inc. All rights reserved.
-- @license [Apache 2.0](https://opensource.org/licenses/Apache-2.0)
-- @module spec.helpers


local log = require("kong.cmd.utils.log")
local reload_module = require("spec.internal.module").reload


log.set_lvl(log.levels.quiet) -- disable stdout logs in tests


-- reload some modules when env or _G changes
local CONSTANTS = reload_module("spec.internal.constants")
local conf = reload_module("spec.internal.conf")
local shell = reload_module("spec.internal.shell")
local misc = reload_module("spec.internal.misc")
local DB = reload_module("spec.internal.db")
local grpc = reload_module("spec.internal.grpc")
local dns_mock = reload_module("spec.internal.dns")
local asserts = reload_module("spec.internal.asserts") -- luacheck: ignore
local pid = reload_module("spec.internal.pid")
local cmd = reload_module("spec.internal.cmd")
local server = reload_module("spec.internal.server")
local client = reload_module("spec.internal.client")
local wait = reload_module("spec.internal.wait")


-- redo the patches to make kong PDK available to timerng timers
_G.timerng:destroy()

_G.timerng = require("resty.timerng").new({
  min_threads = 16,
  max_threads = 32,
})

_G.timerng:start()

_G.ngx.timer.at = function (delay, callback, ...)
  return _timerng:at(delay, callback, ...)
end

_G.ngx.timer.every = function (interval, callback, ...)
  return _timerng:every(interval, callback, ...)
end


----------------
-- Variables/constants
-- @section exported-fields


--- Below is a list of fields/constants exported on the `helpers` module table:
-- @table helpers
-- @field dir The [`pl.dir` module of Penlight](http://tieske.github.io/Penlight/libraries/pl.dir.html)
-- @field path The [`pl.path` module of Penlight](http://tieske.github.io/Penlight/libraries/pl.path.html)
-- @field file The [`pl.file` module of Penlight](http://tieske.github.io/Penlight/libraries/pl.file.html)
-- @field utils The [`pl.utils` module of Penlight](http://tieske.github.io/Penlight/libraries/pl.utils.html)
-- @field test_conf The Kong test configuration. See also `get_running_conf` which might be slightly different.
-- @field test_conf_path The configuration file in use.
-- @field mock_upstream_hostname
-- @field mock_upstream_protocol
-- @field mock_upstream_host
-- @field mock_upstream_port
-- @field mock_upstream_url Base url constructed from the components
-- @field mock_upstream_ssl_protocol
-- @field mock_upstream_ssl_host
-- @field mock_upstream_ssl_port
-- @field mock_upstream_ssl_url Base url constructed from the components
-- @field mock_upstream_stream_port
-- @field mock_upstream_stream_ssl_port
-- @field mock_grpc_upstream_proto_path
-- @field grpcbin_host The host for grpcbin service, it can be set by env KONG_SPEC_TEST_GRPCBIN_HOST.
-- @field grpcbin_port The port (SSL disabled) for grpcbin service, it can be set by env KONG_SPEC_TEST_GRPCBIN_PORT.
-- @field grpcbin_ssl_port The port (SSL enabled) for grpcbin service it can be set by env KONG_SPEC_TEST_GRPCBIN_SSL_PORT.
-- @field grpcbin_url The URL (SSL disabled) for grpcbin service
-- @field grpcbin_ssl_url The URL (SSL enabled) for grpcbin service
-- @field redis_host The host for Redis, it can be set by env KONG_SPEC_TEST_REDIS_HOST.
-- @field redis_port The port (SSL disabled) for Redis, it can be set by env KONG_SPEC_TEST_REDIS_PORT.
-- @field redis_ssl_port The port (SSL enabled) for Redis, it can be set by env KONG_SPEC_TEST_REDIS_SSL_PORT.
-- @field redis_ssl_sni The server name for Redis, it can be set by env KONG_SPEC_TEST_REDIS_SSL_SNI.
-- @field zipkin_host The host for Zipkin service, it can be set by env KONG_SPEC_TEST_ZIPKIN_HOST.
-- @field zipkin_port the port for Zipkin service, it can be set by env KONG_SPEC_TEST_ZIPKIN_PORT.
-- @field otelcol_host The host for OpenTelemetry Collector service, it can be set by env KONG_SPEC_TEST_OTELCOL_HOST.
-- @field otelcol_http_port the port for OpenTelemetry Collector service, it can be set by env KONG_SPEC_TEST_OTELCOL_HTTP_PORT.
-- @field old_version_kong_path the path for the old version kong source code, it can be set by env KONG_SPEC_TEST_OLD_VERSION_KONG_PATH.
-- @field otelcol_zpages_port the port for OpenTelemetry Collector Zpages service, it can be set by env KONG_SPEC_TEST_OTELCOL_ZPAGES_PORT.
-- @field otelcol_file_exporter_path the path of for OpenTelemetry Collector's file exporter, it can be set by env KONG_SPEC_TEST_OTELCOL_FILE_EXPORTER_PATH.

----------
-- Exposed
----------
-- @export
  return {
  -- Penlight
  dir = require("pl.dir"),
  path = require("pl.path"),
  file = require("pl.file"),
  utils = require("pl.utils"),

  -- Kong testing properties
  db = DB.db,
  blueprints = DB.blueprints,
  get_db_utils = DB.get_db_utils,
  get_cache = DB.get_cache,
  bootstrap_database = DB.bootstrap_database,
  bin_path = CONSTANTS.BIN_PATH,
  test_conf = conf,
  test_conf_path = CONSTANTS.TEST_CONF_PATH,
  external_plugins_path = CONSTANTS.EXTERNAL_PLUGINS_PATH,
  mock_upstream_hostname = CONSTANTS.MOCK_UPSTREAM_HOSTNAME,
  mock_upstream_protocol = CONSTANTS.MOCK_UPSTREAM_PROTOCOL,
  mock_upstream_host     = CONSTANTS.MOCK_UPSTREAM_HOST,
  mock_upstream_port     = CONSTANTS.MOCK_UPSTREAM_PORT,
  mock_upstream_url      = CONSTANTS.MOCK_UPSTREAM_PROTOCOL .. "://" ..
                           CONSTANTS.MOCK_UPSTREAM_HOST .. ':' ..
                           CONSTANTS.MOCK_UPSTREAM_PORT,

  mock_upstream_ssl_protocol = CONSTANTS.MOCK_UPSTREAM_SSL_PROTOCOL,
  mock_upstream_ssl_host     = CONSTANTS.MOCK_UPSTREAM_HOST,
  mock_upstream_ssl_port     = CONSTANTS.MOCK_UPSTREAM_SSL_PORT,
  mock_upstream_ssl_url      = CONSTANTS.MOCK_UPSTREAM_SSL_PROTOCOL .. "://" ..
                               CONSTANTS.MOCK_UPSTREAM_HOST .. ':' ..
                               CONSTANTS.MOCK_UPSTREAM_SSL_PORT,

  mock_upstream_stream_port     = CONSTANTS.MOCK_UPSTREAM_STREAM_PORT,
  mock_upstream_stream_ssl_port = CONSTANTS.MOCK_UPSTREAM_STREAM_SSL_PORT,
  mock_grpc_upstream_proto_path = CONSTANTS.MOCK_GRPC_UPSTREAM_PROTO_PATH,

  zipkin_host = CONSTANTS.ZIPKIN_HOST,
  zipkin_port = CONSTANTS.ZIPKIN_PORT,

  otelcol_host               = CONSTANTS.OTELCOL_HOST,
  otelcol_http_port          = CONSTANTS.OTELCOL_HTTP_PORT,
  otelcol_zpages_port        = CONSTANTS.OTELCOL_ZPAGES_PORT,
  otelcol_file_exporter_path = CONSTANTS.OTELCOL_FILE_EXPORTER_PATH,

  grpcbin_host     = CONSTANTS.GRPCBIN_HOST,
  grpcbin_port     = CONSTANTS.GRPCBIN_PORT,
  grpcbin_ssl_port = CONSTANTS.GRPCBIN_SSL_PORT,
  grpcbin_url      = string.format("grpc://%s:%d", CONSTANTS.GRPCBIN_HOST, CONSTANTS.GRPCBIN_PORT),
  grpcbin_ssl_url  = string.format("grpcs://%s:%d", CONSTANTS.GRPCBIN_HOST, CONSTANTS.GRPCBIN_SSL_PORT),

  redis_host     = CONSTANTS.REDIS_HOST,
  redis_port     = CONSTANTS.REDIS_PORT,
  redis_ssl_port = CONSTANTS.REDIS_SSL_PORT,
  redis_ssl_sni  = CONSTANTS.REDIS_SSL_SNI,
  redis_auth_port = CONSTANTS.REDIS_AUTH_PORT,

  blackhole_host = CONSTANTS.BLACKHOLE_HOST,

  old_version_kong_path = CONSTANTS.OLD_VERSION_KONG_PATH,

  -- Kong testing helpers
  execute = shell.exec,
  dns_mock = dns_mock,
  kong_exec = shell.kong_exec,
  get_version = cmd.get_version,
  get_running_conf = cmd.get_running_conf,
  http_client = client.http_client,
  grpc_client = client.grpc_client,
  http2_client = client.http2_client,
  make_synchronized_clients = client.make_synchronized_clients,
  wait_until = wait.wait_until,
  pwait_until = wait.pwait_until,
  wait_pid = pid.wait_pid,
  wait_timer = wait.wait_timer,
  wait_for_all_config_update = wait.wait_for_all_config_update,
  wait_for_file = wait.wait_for_file,
  wait_for_file_contents = wait.wait_for_file_contents,
  tcp_server = server.tcp_server,
  udp_server = server.udp_server,
  kill_tcp_server = server.kill_tcp_server,
  is_echo_server_ready = server.is_echo_server_ready,
  echo_server_reset = server.echo_server_reset,
  get_echo_server_received_data = server.get_echo_server_received_data,
  http_mock = server.http_mock,
  get_proxy_ip = client.get_proxy_ip,
  get_proxy_port = client.get_proxy_port,
  proxy_client = client.proxy_client,
  proxy_client_grpc = client.proxy_client_grpc,
  proxy_client_grpcs = client.proxy_client_grpcs,
  proxy_client_h2c = client.proxy_client_h2c,
  proxy_client_h2 = client.proxy_client_h2,
  admin_client = client.admin_client,
  admin_gui_client = client.admin_gui_client,
  proxy_ssl_client = client.proxy_ssl_client,
  admin_ssl_client = client.admin_ssl_client,
  admin_gui_ssl_client = client.admin_gui_ssl_client,
  prepare_prefix = cmd.prepare_prefix,
  clean_prefix = cmd.clean_prefix,
  clean_logfile = cmd.clean_logfile,
  wait_for_invalidation = wait.wait_for_invalidation,
  each_strategy = DB.each_strategy,
  all_strategies = DB.all_strategies,
  validate_plugin_config_schema = DB.validate_plugin_config_schema,
  clustering_client = client.clustering_client,
  https_server = require("spec.fixtures.https_server"),
  stress_generator = require("spec.fixtures.stress_generator"),

  -- miscellaneous
  intercept = misc.intercept,
  openresty_ver_num = misc.openresty_ver_num,
  unindent = misc.unindent,
  make_yaml_file = misc.make_yaml_file,
  setenv = misc.setenv,
  unsetenv = misc.unsetenv,
  deep_sort = misc.deep_sort,
  generate_keys = misc.generate_keys,

  -- launching Kong subprocesses
  start_kong = cmd.start_kong,
  stop_kong = cmd.stop_kong,
  cleanup_kong = cmd.cleanup_kong,
  restart_kong = cmd.restart_kong,
  reload_kong = wait.reload_kong,
  get_kong_workers = wait.get_kong_workers,
  wait_until_no_common_workers = wait.wait_until_no_common_workers,

  start_grpc_target = grpc.start_grpc_target,
  stop_grpc_target = grpc.stop_grpc_target,
  get_grpc_target_port = grpc.get_grpc_target_port,

  -- plugin compatibility test
  use_old_plugin = misc.use_old_plugin,

  -- Only use in CLI tests from spec/02-integration/01-cmd
  kill_all = cmd.kill_all,

  with_current_ws = misc.with_current_ws,

  signal = cmd.signal,

  -- send signal to all Nginx workers, not including the master
  signal_workers = cmd.signal_workers,

  -- returns the plugins and version list that is used by Hybrid mode tests
  get_plugins_list = DB.clone_plugins_list,

  get_available_port = wait.get_available_port,

  make_temp_dir = misc.make_temp_dir,

  build_go_plugins = cmd.build_go_plugins,
}
