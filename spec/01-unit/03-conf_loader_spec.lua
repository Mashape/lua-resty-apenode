local kong_meta = require "kong.meta"
local conf_loader = require "kong.conf_loader"
local log = require "kong.cmd.utils.log"
local helpers = require "spec.helpers"
local tablex = require "pl.tablex"
local pl_path = require "pl.path"
local ffi = require "ffi"


local C = ffi.C


ffi.cdef([[
  struct group *getgrnam(const char *name);
  struct passwd *getpwnam(const char *name);
]])


local KONG_VERSION = string.format("%d.%d",
                                   kong_meta._VERSION_TABLE.major,
                                   kong_meta._VERSION_TABLE.minor)


local function kong_user_group_exists()
  if C.getpwnam("kong") == nil or C.getgrnam("kong") == nil then
    return false
  else
    return true
  end
end


local function search_directive(tbl, directive_name, directive_value)
  for _, directive in pairs(tbl) do
    if directive.name == directive_name
       and directive.value == directive_value then
      return true
    end
  end

  return false
end


local DATABASE = os.getenv("KONG_DATABASE") or "postgres"


describe("Configuration loader", function()
  it("loads the defaults", function()
    local conf = assert(conf_loader())
    assert.is_string(conf.lua_package_path)
    if kong_user_group_exists() == true then
      assert.equal("kong kong", conf.nginx_main_user)
    else
      assert.is_nil(conf.nginx_main_user)
    end
    assert.equal("auto", conf.nginx_main_worker_processes)
    assert.equal("eventual", conf.worker_consistency)
    assert.same({"127.0.0.1:8001 reuseport backlog=16384", "127.0.0.1:8444 http2 ssl reuseport backlog=16384"}, conf.admin_listen)
    assert.same({"0.0.0.0:8000 reuseport backlog=16384", "0.0.0.0:8443 http2 ssl reuseport backlog=16384"}, conf.proxy_listen)
    assert.same({"0.0.0.0:8002", "0.0.0.0:8445 ssl"}, conf.admin_gui_listen)
    assert.equal("/", conf.admin_gui_path)
    assert.equal(true, conf.admin_gui_csp_header)
    assert.equal("logs/admin_gui_access.log", conf.admin_gui_access_log)
    assert.equal("logs/admin_gui_error.log", conf.admin_gui_error_log)
    assert.same({}, conf.ssl_cert) -- check placeholder value
    assert.same({}, conf.ssl_cert_key)
    assert.same({}, conf.admin_ssl_cert)
    assert.same({}, conf.admin_ssl_cert_key)
    assert.same({}, conf.admin_gui_ssl_cert)
    assert.same({}, conf.admin_gui_ssl_cert_key)
    assert.same({}, conf.status_ssl_cert)
    assert.same({}, conf.status_ssl_cert_key)
    assert.same(nil, conf.privileged_agent)
    assert.same(true, conf.dedicated_config_processing)
    assert.same(false, conf.allow_debug_header)
    assert.same(KONG_VERSION, conf.lmdb_validation_tag)
    assert.is_nil(getmetatable(conf))
  end)
  it("loads a given file, with higher precedence", function()
    local conf = assert(conf_loader(helpers.test_conf_path))
    -- defaults
    assert.equal("on", conf.nginx_main_daemon)
    -- overrides
    assert.same({"off"}, conf.admin_gui_listen)
    if kong_user_group_exists() == true then
      assert.equal("kong kong", conf.nginx_main_user)
    else
      assert.is_nil(conf.nginx_main_user)
    end
    assert.equal("1", conf.nginx_main_worker_processes)
    assert.same({"127.0.0.1:9001"}, conf.admin_listen)
    assert.same({"0.0.0.0:9000", "0.0.0.0:9443 http2 ssl",
                 "0.0.0.0:9002 http2"}, conf.proxy_listen)
    assert.same(KONG_VERSION, conf.lmdb_validation_tag)
    assert.is_nil(getmetatable(conf))
  end)
  it("preserves default properties if not in given file", function()
    local conf = assert(conf_loader(helpers.test_conf_path))
    assert.is_string(conf.lua_package_path) -- still there
  end)
  it("accepts custom params, with highest precedence", function()
    local conf = assert(conf_loader(helpers.test_conf_path, {
      admin_listen = "127.0.0.1:9001",
      nginx_main_worker_processes = "auto"
    }))
    -- defaults
    assert.equal("on", conf.nginx_main_daemon)
    -- overrides
    if kong_user_group_exists() == true then
      assert.equal("kong kong", conf.nginx_main_user)
    else
      assert.is_nil(conf.nginx_main_user)
    end
    assert.equal("auto", conf.nginx_main_worker_processes)
    assert.same({"127.0.0.1:9001"}, conf.admin_listen)
    assert.same({"0.0.0.0:9000", "0.0.0.0:9443 http2 ssl",
                 "0.0.0.0:9002 http2"}, conf.proxy_listen)
    assert.is_nil(getmetatable(conf))
  end)
  it("strips extraneous properties (not in defaults)", function()
    local conf = assert(conf_loader(nil, {
      stub_property = "leave me alone"
    }))
    assert.is_nil(conf.stub_property)
  end)
  it("returns a plugins table", function()
    local constants = require "kong.constants"
    local conf = assert(conf_loader())
    assert.same(constants.BUNDLED_PLUGINS, conf.loaded_plugins)
  end)
  it("loads custom plugins", function()
    local conf = assert(conf_loader(nil, {
      plugins = "hello-world,my-plugin"
    }))
    assert.True(conf.loaded_plugins["hello-world"])
    assert.True(conf.loaded_plugins["my-plugin"])
  end)
  it("merges plugins and custom plugins", function()
    local conf = assert(conf_loader(nil, {
      plugins = "foo, bar",
    }))
    assert.is_not_nil(conf.loaded_plugins)
    assert.same(2, tablex.size(conf.loaded_plugins))
    assert.True(conf.loaded_plugins["foo"])
    assert.True(conf.loaded_plugins["bar"])
  end)
  it("no longer applies # transformations when loading from .kong_env (issue #5761)", function()
    local conf = assert(conf_loader(nil, {
      pg_password = "!abCDefGHijKL4\\#1MN2OP3",
    }, { from_kong_env = true, }))
    assert.same("!abCDefGHijKL4\\#1MN2OP3", conf.pg_password)
  end)
  it("loads custom plugins surrounded by spaces", function()
    local conf = assert(conf_loader(nil, {
      plugins = " hello-world ,   another-one  "
    }))
    assert.True(conf.loaded_plugins["hello-world"])
    assert.True(conf.loaded_plugins["another-one"])
  end)
  it("extracts flags, ports and listen ips from proxy_listen/admin_listen/admin_gui_listen", function()
    local conf = assert(conf_loader())
    assert.equal("127.0.0.1", conf.admin_listeners[1].ip)
    assert.equal(8001, conf.admin_listeners[1].port)
    assert.equal(false, conf.admin_listeners[1].ssl)
    assert.equal(false, conf.admin_listeners[1].http2)
    assert.equal("127.0.0.1:8001 reuseport backlog=16384", conf.admin_listeners[1].listener)

    assert.equal("127.0.0.1", conf.admin_listeners[2].ip)
    assert.equal(8444, conf.admin_listeners[2].port)
    assert.equal(true, conf.admin_listeners[2].ssl)
    assert.equal(true, conf.admin_listeners[2].http2)
    assert.equal("127.0.0.1:8444 ssl reuseport backlog=16384", conf.admin_listeners[2].listener)

    assert.equal("0.0.0.0", conf.admin_gui_listeners[1].ip)
    assert.equal(8002, conf.admin_gui_listeners[1].port)
    assert.equal(false, conf.admin_gui_listeners[1].ssl)
    assert.equal(false, conf.admin_gui_listeners[1].http2)
    assert.equal("0.0.0.0:8002", conf.admin_gui_listeners[1].listener)

    assert.equal("0.0.0.0", conf.admin_gui_listeners[2].ip)
    assert.equal(8445, conf.admin_gui_listeners[2].port)
    assert.equal(true, conf.admin_gui_listeners[2].ssl)
    assert.equal(false, conf.admin_gui_listeners[2].http2)
    assert.equal("0.0.0.0:8445 ssl", conf.admin_gui_listeners[2].listener)

    assert.equal("0.0.0.0", conf.proxy_listeners[1].ip)
    assert.equal(8000, conf.proxy_listeners[1].port)
    assert.equal(false, conf.proxy_listeners[1].ssl)
    assert.equal(false, conf.proxy_listeners[1].http2)
    assert.equal("0.0.0.0:8000 reuseport backlog=16384", conf.proxy_listeners[1].listener)

    assert.equal("0.0.0.0", conf.proxy_listeners[2].ip)
    assert.equal(8443, conf.proxy_listeners[2].port)
    assert.equal(true, conf.proxy_listeners[2].ssl)
    assert.equal(true, conf.proxy_listeners[2].http2)
    assert.equal("0.0.0.0:8443 ssl reuseport backlog=16384", conf.proxy_listeners[2].listener)
  end)
  it("parses IPv6 from proxy_listen/admin_listen/admin_gui_listen", function()
    local conf = assert(conf_loader(nil, {
      proxy_listen = "[::]:8000, [::]:8443 ssl",
      admin_listen = "[::1]:8001, [::1]:8444 ssl",
      admin_gui_listen = "[::1]:8002, [::1]:8445 ssl",
    }))
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]", conf.admin_listeners[1].ip)
    assert.equal(8001, conf.admin_listeners[1].port)
    assert.equal(false, conf.admin_listeners[1].ssl)
    assert.equal(false, conf.admin_listeners[1].http2)
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]:8001", conf.admin_listeners[1].listener)

    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]", conf.admin_listeners[2].ip)
    assert.equal(8444, conf.admin_listeners[2].port)
    assert.equal(true, conf.admin_listeners[2].ssl)
    assert.equal(false, conf.admin_listeners[2].http2)
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]:8444 ssl", conf.admin_listeners[2].listener)

    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]", conf.admin_gui_listeners[1].ip)
    assert.equal(8002, conf.admin_gui_listeners[1].port)
    assert.equal(false, conf.admin_gui_listeners[1].ssl)
    assert.equal(false, conf.admin_gui_listeners[1].http2)
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]:8002", conf.admin_gui_listeners[1].listener)

    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]", conf.admin_gui_listeners[2].ip)
    assert.equal(8445, conf.admin_gui_listeners[2].port)
    assert.equal(true, conf.admin_gui_listeners[2].ssl)
    assert.equal(false, conf.admin_gui_listeners[2].http2)
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0001]:8445 ssl", conf.admin_gui_listeners[2].listener)

    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0000]", conf.proxy_listeners[1].ip)
    assert.equal(8000, conf.proxy_listeners[1].port)
    assert.equal(false, conf.proxy_listeners[1].ssl)
    assert.equal(false, conf.proxy_listeners[1].http2)
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0000]:8000", conf.proxy_listeners[1].listener)

    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0000]", conf.proxy_listeners[2].ip)
    assert.equal(8443, conf.proxy_listeners[2].port)
    assert.equal(true, conf.proxy_listeners[2].ssl)
    assert.equal(false, conf.proxy_listeners[2].http2)
    assert.equal("[0000:0000:0000:0000:0000:0000:0000:0000]:8443 ssl", conf.proxy_listeners[2].listener)
  end)
  it("extracts ssl flags properly when hostnames contain them", function()
    local conf
    conf = assert(conf_loader(nil, {
      proxy_listen = "ssl.myname.test:8000",
      admin_listen = "ssl.myname.test:8001",
      admin_gui_listen = "ssl.myname.test:8002",
    }))
    assert.equal("ssl.myname.test", conf.proxy_listeners[1].ip)
    assert.equal(false, conf.proxy_listeners[1].ssl)
    assert.equal("ssl.myname.test", conf.admin_listeners[1].ip)
    assert.equal(false, conf.admin_listeners[1].ssl)
    assert.equal("ssl.myname.test", conf.admin_gui_listeners[1].ip)
    assert.equal(false, conf.admin_gui_listeners[1].ssl)

    conf = assert(conf_loader(nil, {
      proxy_listen = "ssl_myname.test:8000 ssl",
      admin_listen = "ssl_myname.test:8001 ssl",
      admin_gui_listen = "ssl_myname.test:8002 ssl",
    }))
    assert.equal("ssl_myname.test", conf.proxy_listeners[1].ip)
    assert.equal(true, conf.proxy_listeners[1].ssl)
    assert.equal("ssl_myname.test", conf.admin_listeners[1].ip)
    assert.equal(true, conf.admin_listeners[1].ssl)
    assert.equal("ssl_myname.test", conf.admin_gui_listeners[1].ip)
    assert.equal(true, conf.admin_gui_listeners[1].ssl)
  end)
  it("extracts 'off' from proxy_listen/admin_listen/admin_gui_listen", function()
    local conf
    conf = assert(conf_loader(nil, {
      proxy_listen = "off",
      admin_listen = "off",
      admin_gui_listen = "off",
    }))
    assert.same({}, conf.proxy_listeners)
    assert.same({}, conf.admin_listeners)
    assert.same({}, conf.admin_gui_listeners)
    -- off with multiple entries
    conf = assert(conf_loader(nil, {
      proxy_listen = "off, 0.0.0.0:9000",
      admin_listen = "off, 127.0.0.1:9001",
      admin_gui_listen = "off, 127.0.0.1:9002",
    }))
    assert.same({}, conf.proxy_listeners)
    assert.same({}, conf.admin_listeners)
    assert.same({}, conf.admin_gui_listeners)
    -- not off with names containing 'off'
    conf = assert(conf_loader(nil, {
      proxy_listen = "offshore.test:9000",
      admin_listen = "offshore.test:9001",
      admin_gui_listen = "offshore.test:9002",
    }))
    assert.same("offshore.test", conf.proxy_listeners[1].ip)
    assert.same("offshore.test", conf.admin_listeners[1].ip)
    assert.same("offshore.test", conf.admin_gui_listeners[1].ip)
  end)
  it("attaches prefix paths", function()
    local conf = assert(conf_loader())
    assert.equal("/usr/local/kong/pids/nginx.pid", conf.nginx_pid)
    assert.equal("/usr/local/kong/logs/error.log", conf.nginx_err_logs)
    assert.equal("/usr/local/kong/logs/access.log", conf.nginx_acc_logs)
    assert.equal("/usr/local/kong/logs/admin_access.log", conf.admin_acc_logs)
    assert.equal("/usr/local/kong/nginx.conf", conf.nginx_conf)
    assert.equal("/usr/local/kong/nginx-kong.conf", conf.nginx_kong_conf)
    assert.equal("/usr/local/kong/.kong_env", conf.kong_env)
    -- ssl default paths
    assert.equal("/usr/local/kong/ssl/kong-default.crt", conf.ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/kong-default.key", conf.ssl_cert_key_default)
    assert.equal("/usr/local/kong/ssl/admin-kong-default.crt", conf.admin_ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/admin-kong-default.key", conf.admin_ssl_cert_key_default)
    assert.equal("/usr/local/kong/ssl/admin-gui-kong-default.crt", conf.admin_gui_ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/admin-gui-kong-default.key", conf.admin_gui_ssl_cert_key_default)
    assert.equal("/usr/local/kong/ssl/status-kong-default.crt", conf.status_ssl_cert_default)
    assert.equal("/usr/local/kong/ssl/status-kong-default.key", conf.status_ssl_cert_key_default)
  end)
  it("should populate correct admin_gui_origin", function()
    local conf, _, errors = conf_loader(nil, {})
    assert.is_nil(errors)
    assert.is_not_nil(conf)
    assert.is_nil(conf.admin_gui_origin)

    conf, _, errors = conf_loader(nil, {
      admin_gui_url = "http://localhost:8002",
    })
    assert.is_nil(errors)
    assert.is_not_nil(conf)
    assert.is_not_nil(conf.admin_gui_origin)
    assert.same({ "http://localhost:8002" }, conf.admin_gui_origin)

    conf, _, errors = conf_loader(nil, {
      admin_gui_url = "https://localhost:8002",
    })
    assert.is_nil(errors)
    assert.is_not_nil(conf)
    assert.is_not_nil(conf.admin_gui_origin)
    assert.same({ "https://localhost:8002" }, conf.admin_gui_origin)

    conf, _, errors = conf_loader(nil, {
      admin_gui_url = "http://localhost:8002/manager",
    })
    assert.is_nil(errors)
    assert.is_not_nil(conf)
    assert.is_not_nil(conf.admin_gui_origin)
    assert.same({ "http://localhost:8002" }, conf.admin_gui_origin)

    conf, _, errors = conf_loader(nil, {
      admin_gui_url = "http://localhost:8002/manager, https://localhost:8445/manager",
    })
    assert.is_nil(errors)
    assert.is_not_nil(conf)
    assert.is_not_nil(conf.admin_gui_origin)
    assert.is_table(conf.admin_gui_origin)
    assert.same({ "http://localhost:8002", "https://localhost:8445" }, conf.admin_gui_origin)
  end)
  it("strips comments ending settings", function()
    local _os_getenv = os.getenv
    finally(function()
      os.getenv = _os_getenv -- luacheck: ignore
    end)
    os.getenv = function() end -- luacheck: ignore

    local conf = assert(conf_loader("spec/fixtures/to-strip.conf"))

    assert.equal(DATABASE, conf.database)
    assert.equal("debug", conf.log_level)
  end)
  it("overcomes penlight's list_delim option", function()
    local conf = assert(conf_loader("spec/fixtures/to-strip.conf"))
    assert.False(conf.pg_ssl)
    assert.True(conf.loaded_plugins.foobar)
    assert.True(conf.loaded_plugins["hello-world"])
  end)
  it("correctly parses values containing an octothorpe", function()
    local conf = assert(conf_loader("spec/fixtures/to-strip.conf"))
    assert.equal("test#123", conf.pg_password)
  end)
  it("escapes unescaped octothorpes in environment variables", function()
    finally(function()
      helpers.unsetenv("KONG_PG_PASSWORD")
    end)
    helpers.setenv("KONG_PG_PASSWORD", "test#123")
    local conf = assert(conf_loader())
    assert.equal("test#123", conf.pg_password)

    helpers.setenv("KONG_PG_PASSWORD", "test#12#3")
    local conf = assert(conf_loader())
    assert.equal("test#12#3", conf.pg_password)

    helpers.setenv("KONG_PG_PASSWORD", "test##12##3#")
    local conf = assert(conf_loader())
    assert.equal("test##12##3#", conf.pg_password)
  end)
  it("escapes unescaped octothorpes in custom_conf overrides", function()
    local conf = assert(conf_loader(nil, {
      pg_password = "test#123",
    }))
    assert.equal("test#123", conf.pg_password)

    local conf = assert(conf_loader(nil, {
      pg_password = "test#12#3",
    }))
    assert.equal("test#12#3", conf.pg_password)

    local conf = assert(conf_loader(nil, {
      pg_password = "test##12##3#",
    }))
    assert.equal("test##12##3#", conf.pg_password)
  end)
  it("does not modify existing octothorpes in environment variables", function()
    finally(function()
      helpers.unsetenv("KONG_PG_PASSWORD")
    end)
    helpers.setenv("KONG_PG_PASSWORD", [[test#123]])
    local conf = assert(conf_loader())
    assert.equal("test#123", conf.pg_password)

    helpers.setenv("KONG_PG_PASSWORD", [[test##12##3#]])
    local conf = assert(conf_loader())
    assert.equal("test##12##3#", conf.pg_password)
  end)
  it("does not modify existing octothorpes in custom_conf overrides", function()
    local conf = assert(conf_loader(nil, {
      pg_password = [[test#123]],
    }))
    assert.equal("test#123", conf.pg_password)

    local conf = assert(conf_loader(nil, {
      pg_password = [[test##12##3#]],
    }))
    assert.equal("test##12##3#", conf.pg_password)
  end)

  describe("dynamic directives", function()
    it("loads flexible prefix based configs from a file", function()
      local conf = assert(conf_loader("spec/fixtures/nginx-directives.conf", {
        plugins = "off",
      }))
      assert.True(search_directive(conf.nginx_http_directives,
                                   "variables_hash_bucket_size", "128"))
      assert.True(search_directive(conf.nginx_stream_directives,
                                   "variables_hash_bucket_size", "128"))

      assert.True(search_directive(conf.nginx_http_directives,
                                   "lua_shared_dict", "custom_cache 5m"))
      assert.True(search_directive(conf.nginx_stream_directives,
                                   "lua_shared_dict", "custom_cache 5m"))

      assert.True(search_directive(conf.nginx_proxy_directives,
                                   "proxy_bind", "127.0.0.1"))
      assert.True(search_directive(conf.nginx_sproxy_directives,
                                   "proxy_bind", "127.0.0.1"))

      assert.True(search_directive(conf.nginx_admin_directives,
                                   "server_tokens", "off"))
    end)

    it("quotes numeric flexible prefix based configs", function()
      local conf, err = conf_loader(nil, {
        ["nginx_http_max_pending_timers"] = 4096,
      })
      assert.is_nil(err)

      assert.True(search_directive(conf.nginx_http_directives,
                  "max_pending_timers", "4096"))
    end)

    it("accepts flexible config values with precedence", function()
      local conf = assert(conf_loader("spec/fixtures/nginx-directives.conf", {
        ["nginx_http_variables_hash_bucket_size"] = "256",
        ["nginx_stream_variables_hash_bucket_size"] = "256",
        ["nginx_http_lua_shared_dict"] = "custom_cache 2m",
        ["nginx_stream_lua_shared_dict"] = "custom_cache 2m",
        ["nginx_proxy_proxy_bind"] = "127.0.0.2",
        ["nginx_sproxy_proxy_bind"] = "127.0.0.2",
        ["nginx_admin_server_tokens"] = "build",
        plugins = "off",
      }))

      assert.True(search_directive(conf.nginx_http_directives,
                                   "variables_hash_bucket_size", "256"))
      assert.True(search_directive(conf.nginx_stream_directives,
                                   "variables_hash_bucket_size", "256"))

      assert.True(search_directive(conf.nginx_http_directives,
                                   "lua_shared_dict", "custom_cache 2m"))
      assert.True(search_directive(conf.nginx_stream_directives,
                                   "lua_shared_dict", "custom_cache 2m"))

      assert.True(search_directive(conf.nginx_proxy_directives,
                                   "proxy_bind", "127.0.0.2"))
      assert.True(search_directive(conf.nginx_sproxy_directives,
                                   "proxy_bind", "127.0.0.2"))

      assert.True(search_directive(conf.nginx_admin_directives,
                                   "server_tokens", "build"))
      assert.True(search_directive(conf.nginx_status_directives,
                                   "client_body_buffer_size", "8k"))
    end)
  end)

  describe("prometheus_metrics shm", function()
    it("is injected if not provided via nginx_http_* directives", function()
      local conf = assert(conf_loader())
      assert.True(search_directive(conf.nginx_http_directives,
                  "lua_shared_dict", "prometheus_metrics 5m"))
    end)
    it("size is not modified if provided via nginx_http_* directives", function()
      local conf = assert(conf_loader(nil, {
        plugins = "bundled",
        nginx_http_lua_shared_dict = "prometheus_metrics 2m",
      }))
      assert.True(search_directive(conf.nginx_http_directives,
                  "lua_shared_dict", "prometheus_metrics 2m"))
    end)
    it("is injected in addition to any shm provided via nginx_http_* directive", function()
      local conf = assert(conf_loader(nil, {
        plugins = "bundled",
        nginx_http_lua_shared_dict = "custom_cache 2m",
      }))
      assert.True(search_directive(conf.nginx_http_directives,
                  "lua_shared_dict", "custom_cache 2m"))
      assert.True(search_directive(conf.nginx_http_directives,
                  "lua_shared_dict", "prometheus_metrics 5m"))
    end)
    it("is not injected if prometheus plugin is disabled", function()
      local conf = assert(conf_loader(nil, {
        plugins = "off",
      }))
      assert.is_nil(conf.nginx_http_directives["lua_shared_dict"])
    end)
  end)

  describe("nginx_main_user", function()
    it("is 'kong kong' by default if the kong user/group exist", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      if kong_user_group_exists() == true then
        assert.equal("kong kong", conf.nginx_main_user)
      else
        assert.is_nil(conf.nginx_main_user)
      end
    end)
    it("is nil when 'nobody'", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_main_user = "nobody"
      }))
      assert.is_nil(conf.nginx_main_user)
    end)
    it("is nil when 'nobody nobody'", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_main_user = "nobody nobody"
      }))
      assert.is_nil(conf.nginx_main_user)
    end)
    it("is 'www_data www_data' when 'www_data www_data'", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_main_user = "www_data www_data"
      }))
      assert.equal("www_data www_data", conf.nginx_main_user)
    end)
  end)

  describe("nginx_user", function()
    it("is 'kong kong' by default if the kong user/group exist", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      if kong_user_group_exists() == true then
        assert.equal("kong kong", conf.nginx_user)
      else
        assert.is_nil(conf.nginx_user)
      end
    end)

    it("is nil when 'nobody'", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_user = "nobody"
      }))
      assert.is_nil(conf.nginx_user)
    end)
    it("is nil when 'nobody nobody'", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_user = "nobody nobody"
      }))
      assert.is_nil(conf.nginx_user)
    end)
    it("is 'www_data www_data' when 'www_data www_data'", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_user = "www_data www_data"
      }))
      assert.equal("www_data www_data", conf.nginx_user)
    end)
  end)

  describe("port_maps and host_ports", function()
    it("are empty tables when not specified", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {}))
      assert.same({}, conf.port_maps)
      assert.same({}, conf.host_ports)
    end)
    it("are tables when specified", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        port_maps = "80:8000,443:8443",
      }))
      assert.same({
        "80:8000",
        "443:8443",
      }, conf.port_maps)
      assert.same({
        [8000]   = 80,
        ["8000"] = 80,
        [8443]   = 443,
        ["8443"] = 443,
      }, conf.host_ports)
    end)
    it("gives an error with invalid value", function()
      local _, err = conf_loader(helpers.test_conf_path, {
        port_maps = "src:dst",
      })
      assert.equal("invalid port mapping (`port_maps`): src:dst", err)
    end)
    it("errors with a helpful error message if cassandra is used", function()
      local _, err = conf_loader(nil, {
        database = "cassandra"
      })
      assert.equal("Cassandra as a datastore for Kong is not supported in" ..
        " versions 3.4 and above. Please use Postgres.", err)
    end)
  end)

  describe("inferences", function()
    it("infer booleans (on/off/true/false strings)", function()
      local conf = assert(conf_loader())
      assert.equal("on", conf.nginx_main_daemon)
      assert.equal(256, conf.lua_socket_pool_size)
      assert.True(conf.anonymous_reports)
      assert.False(conf.pg_ssl)
      assert.False(conf.pg_ssl_verify)

      conf = assert(conf_loader(nil, {
        pg_ssl = true
      }))
      assert.True(conf.pg_ssl)

      conf = assert(conf_loader(nil, {
        pg_ssl = "on"
      }))
      assert.True(conf.pg_ssl)

      conf = assert(conf_loader(nil, {
        pg_ssl = "true"
      }))
      assert.True(conf.pg_ssl)
    end)
    it("infer arrays (comma-separated strings)", function()
      local conf = assert(conf_loader())
      assert.same({"bundled"}, conf.plugins)
      assert.same({"LAST", "SRV", "A", "CNAME"}, conf.dns_order)
      assert.same({"A", "SRV"}, conf.resolver_family)
      assert.is_nil(getmetatable(conf.plugins))
      assert.is_nil(getmetatable(conf.dns_order))
      assert.is_nil(getmetatable(conf.resolver_family))
    end)
    it("trims array values", function()
      local conf = assert(conf_loader("spec/fixtures/to-strip.conf"))
      assert.same({"foobar", "hello-world", "bundled"}, conf.plugins)
    end)
    it("infer ngx_boolean", function()
      local conf = assert(conf_loader(nil, {
        nginx_main_daemon = true
      }))
      assert.equal("on", conf.nginx_main_daemon)

      conf = assert(conf_loader(nil, {
        nginx_main_daemon = false
      }))
      assert.equal("off", conf.nginx_main_daemon)

      conf = assert(conf_loader(nil, {
        nginx_main_daemon = "off"
      }))
      assert.equal("off", conf.nginx_main_daemon)
    end)
  end)

  describe("validations", function()
    it("enforces properties types", function()
      local conf, err = conf_loader(nil, {
        lua_package_path = 123
      })
      assert.equal("lua_package_path is not a string: '123'", err)
      assert.is_nil(conf)
    end)
    it("enforces enums", function()
      local conf, err = conf_loader(nil, {
        database = "mysql"
      })
      assert.equal("database has an invalid value: 'mysql' (postgres, cassandra, off)", err)
      assert.is_nil(conf)

      local conf, err = conf_loader(nil, {
        worker_consistency = "magical"
      })
      assert.equal("worker_consistency has an invalid value: 'magical' (strict, eventual)", err)
      assert.is_nil(conf)
    end)
    it("enforces listen addresses format", function()
      local conf, err = conf_loader(nil, {
        admin_listen = "127.0.0.1"
      })
      assert.is_nil(conf)
      assert.equal("admin_listen must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+] [ipv6only=on] [ipv6only=off] [so_keepalive=on] [so_keepalive=off] [so_keepalive=%w*:%w*:%d*], [... next entry ...]", err)

      conf, err = conf_loader(nil, {
        proxy_listen = "127.0.0.1"
      })
      assert.is_nil(conf)
      assert.equal("proxy_listen must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+] [ipv6only=on] [ipv6only=off] [so_keepalive=on] [so_keepalive=off] [so_keepalive=%w*:%w*:%d*], [... next entry ...]", err)

      conf, err = conf_loader(nil, {
        admin_gui_listen = "127.0.0.1"
      })
      assert.is_nil(conf)
      assert.equal("admin_gui_listen must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+] [ipv6only=on] [ipv6only=off] [so_keepalive=on] [so_keepalive=off] [so_keepalive=%w*:%w*:%d*], [... next entry ...]", err)
    end)
    it("rejects empty string in listen addresses", function()
      local conf, err = conf_loader(nil, {
        admin_listen = ""
      })
      assert.is_nil(conf)
      assert.equal("admin_listen must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+] [ipv6only=on] [ipv6only=off] [so_keepalive=on] [so_keepalive=off] [so_keepalive=%w*:%w*:%d*], [... next entry ...]", err)

      conf, err = conf_loader(nil, {
        proxy_listen = ""
      })
      assert.is_nil(conf)
      assert.equal("proxy_listen must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+] [ipv6only=on] [ipv6only=off] [so_keepalive=on] [so_keepalive=off] [so_keepalive=%w*:%w*:%d*], [... next entry ...]", err)

      conf, err = conf_loader(nil, {
        admin_gui_listen = ""
      })
      assert.is_nil(conf)
      assert.equal("admin_gui_listen must be of form: [off] | <ip>:<port> [ssl] [http2] [proxy_protocol] [deferred] [bind] [reuseport] [backlog=%d+] [ipv6only=on] [ipv6only=off] [so_keepalive=on] [so_keepalive=off] [so_keepalive=%w*:%w*:%d*], [... next entry ...]", err)
    end)
    it("enforces admin_gui_path values", function()
      local conf, _, errors = conf_loader(nil, {
        admin_gui_path = "without-leading-slash"
      })
      assert.equal(1, #errors)
      assert.is_nil(conf)

      conf, _, errors = conf_loader(nil, {
        admin_gui_path = "/with-trailing-slash/"
      })
      assert.equal(1, #errors)
      assert.is_nil(conf)

      conf, _, errors = conf_loader(nil, {
        admin_gui_path = "/with!invalid$characters"
      })
      assert.equal(1, #errors)
      assert.is_nil(conf)

      conf, _, errors = conf_loader(nil, {
        admin_gui_path = "/with//many///continuous////slashes"
      })
      assert.equal(1, #errors)
      assert.is_nil(conf)

      conf, _, errors = conf_loader(nil, {
        admin_gui_path = "with!invalid$characters-but-no-leading-slashes"
      })
      assert.equal(2, #errors)
      assert.is_nil(conf)

      conf, _, errors = conf_loader(nil, {
        admin_gui_path = "/kong/manager"
      })
      assert.is_nil(errors)
      assert.is_not_nil(conf)
    end)
    it("errors when dns_resolver is not a list in ipv4/6[:port] format", function()
      local conf, err = conf_loader(nil, {
        dns_resolver = "1.2.3.4:53;4.3.2.1" -- ; as separator
      })
      assert.equal("dns_resolver must be a comma separated list in the form of IPv4/6 or IPv4/6:port, got '1.2.3.4:53;4.3.2.1'", err)
      assert.is_nil(conf)

      conf, err = conf_loader(nil, {
        dns_resolver = "198.51.100.0:53"
      })
      assert.is_nil(err)
      assert.is_table(conf)

      conf, err = conf_loader(nil, {
        dns_resolver = "[::1]:53"
      })
      assert.is_nil(err)
      assert.is_table(conf)

      conf, err = conf_loader(nil, {
        dns_resolver = "198.51.100.0,1.2.3.4:53,::1,[::1]:53"
      })
      assert.is_nil(err)
      assert.is_table(conf)
    end)
    it("errors when resolver_address is not a list in ipv4/6[:port] format (new dns)", function()
      local conf, err = conf_loader(nil, {
        resolver_address = "1.2.3.4:53;4.3.2.1" -- ; as separator
      })
      assert.equal("resolver_address must be a comma separated list in the form of IPv4/6 or IPv4/6:port, got '1.2.3.4:53;4.3.2.1'", err)
      assert.is_nil(conf)

      conf, err = conf_loader(nil, {
        resolver_address = "198.51.100.0:53"
      })
      assert.is_nil(err)
      assert.is_table(conf)

      conf, err = conf_loader(nil, {
        resolver_address = "[::1]:53"
      })
      assert.is_nil(err)
      assert.is_table(conf)

      conf, err = conf_loader(nil, {
        resolver_address = "198.51.100.0,1.2.3.4:53,::1,[::1]:53"
      })
      assert.is_nil(err)
      assert.is_table(conf)
    end)
    it("errors when node_id is not a valid uuid", function()
      local conf, err = conf_loader(nil, {
        node_id = "foobar",
      })
      assert.equal("node_id must be a valid UUID", err)
      assert.is_nil(conf)
    end)
    it("accepts a valid UUID as node_id", function()
      local conf, err = conf_loader(nil, {
        node_id = "8b7de2ba-0477-4667-a811-8bca46073ca9",
      })
      assert.is_nil(err)
      assert.equal("8b7de2ba-0477-4667-a811-8bca46073ca9", conf.node_id)
    end)
    it("errors when the hosts file does not exist", function()
      local tmpfile = "/a_file_that_does_not_exist"
      local conf, err = conf_loader(nil, {
        dns_hostsfile = tmpfile,
      })
      assert.equal([[dns_hostsfile: file does not exist]], err)
      assert.is_nil(conf)
    end)
    it("errors when the hosts file does not exist (new dns)", function()
      -- new dns
      local tmpfile = "/a_file_that_does_not_exist"
      local conf, err = conf_loader(nil, {
        resolver_hosts_file = tmpfile,
      })
      assert.equal([[resolver_hosts_file: file does not exist]], err)
      assert.is_nil(conf)
    end)
    it("accepts an existing hosts file", function()
      local tmpfile = require("pl.path").tmpname()  -- this creates the file!
      finally(function() os.remove(tmpfile) end)
      local conf, err = conf_loader(nil, {
        dns_hostsfile = tmpfile,
      })
      assert.is_nil(err)
      assert.equal(tmpfile, conf.dns_hostsfile)
    end)
    it("accepts an existing hosts file (new dns)", function()
      local tmpfile = require("pl.path").tmpname()  -- this creates the file!
      finally(function() os.remove(tmpfile) end)
      local conf, err = conf_loader(nil, {
        resolver_hosts_file = tmpfile,
      })
      assert.is_nil(err)
      assert.equal(tmpfile, conf.resolver_hosts_file)
    end)
    it("errors on bad entries in the order list", function()
      local conf, err = conf_loader(nil, {
        dns_order = "A,CXAME,SRV",
      })
      assert.is_nil(conf)
      assert.equal([[dns_order: invalid entry 'CXAME']], err)
    end)
    it("errors on bad entries in the family list", function()
      local conf, err = conf_loader(nil, {
        resolver_family = "A,AAAX,SRV",
      })
      assert.is_nil(conf)
      assert.equal([[resolver_family: invalid entry 'AAAX']], err)
    end)
    it("errors on bad entries in headers", function()
      local conf, err = conf_loader(nil, {
        headers = "server_tokens,Foo-Bar",
      })
      assert.is_nil(conf)
      assert.equal([[headers: invalid entry 'Foo-Bar']], err)
    end)
    describe("SSL", function()
      it("accepts and decodes valid base64 values", function()
        local ssl_fixtures = require "spec.fixtures.ssl"
        local cert = ssl_fixtures.cert
        local cacert = ssl_fixtures.cert_ca
        local key = ssl_fixtures.key
        local dhparam = ssl_fixtures.dhparam

        local properties = {
          ssl_cert = cert,
          ssl_cert_key = key,
          admin_ssl_cert = cert,
          admin_ssl_cert_key = key,
          admin_gui_ssl_cert = cert,
          admin_gui_ssl_cert_key = key,
          status_ssl_cert = cert,
          status_ssl_cert_key = key,
          client_ssl_cert = cert,
          client_ssl_cert_key = key,
          cluster_cert = cert,
          cluster_cert_key = key,
          cluster_ca_cert = cacert,
          ssl_dhparam = dhparam,
          lua_ssl_trusted_certificate = cacert
        }
        local conf_params = {
          ssl_cipher_suite = "old",
          client_ssl = "on",
          role = "control_plane",
          database = "postgres",
          status_listen = "127.0.0.1:123 ssl",
          proxy_listen = "127.0.0.1:456 ssl",
          admin_listen = "127.0.0.1:789 ssl",
          admin_gui_listen = "127.0.0.1:8445 ssl",
        }

        for n, v in pairs(properties) do
          conf_params[n] = ngx.encode_base64(v)
        end
        local conf, err = conf_loader(nil, conf_params)

        assert.is_nil(err)
        assert.is_table(conf)
        for name, decoded_val in pairs(properties) do
          local values = conf[name]
          if type(values) == "table" then
            for i = 1, #values do
              assert.equals(decoded_val, values[i])
            end
          end

          if type(values) == "string" then
            assert.equals(decoded_val, values)
          end
        end
      end)
      describe("proxy", function()
        it("does not check SSL cert and key if SSL is off", function()
          local conf, err = conf_loader(nil, {
            proxy_listen = "127.0.0.1:123",
            ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          -- specific case with 'ssl' in the name
          local conf, err = conf_loader(nil, {
            proxy_listen = "ssl:23",
            proxy_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires both proxy SSL cert and key", function()
          local conf, err = conf_loader(nil, {
            ssl_cert = "/path/cert.pem"
          })
          assert.equal("ssl_cert_key must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            ssl_cert_key = "/path/key.pem"
          })
          assert.equal("ssl_cert must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            ssl_cert = "spec/fixtures/kong_spec.crt",
            ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires SSL cert and key to exist", function()
          local conf, _, errors = conf_loader(nil, {
            ssl_cert = "/path/cert.pem",
            ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(2, #errors)
          assert.contains("ssl_cert: failed loading certificate from /path/cert.pem", errors)
          assert.contains("ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)

          conf, _, errors = conf_loader(nil, {
            ssl_cert = "spec/fixtures/kong_spec.crt",
            ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(1, #errors)
          assert.contains("ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)
        end)
        it("requires SSL DH param file to exist", function()
          local conf, _, errors = conf_loader(nil, {
            ssl_cipher_suite = "custom",
            ssl_dhparam = "/path/dhparam.pem"
          })
          assert.equal(1, #errors)
          assert.contains("ssl_dhparam: failed loading certificate from /path/dhparam.pem", errors)
          assert.is_nil(conf)

          conf, _, errors = conf_loader(nil, {
            ssl_cipher_suite = "custom",
            nginx_http_ssl_dhparam = "/path/dhparam-http.pem",
            nginx_stream_ssl_dhparam = "/path/dhparam-stream.pem",
          })
          assert.equal(2, #errors)
          assert.contains("nginx_http_ssl_dhparam: no such file at /path/dhparam-http.pem", errors)
          assert.contains("nginx_stream_ssl_dhparam: no such file at /path/dhparam-stream.pem", errors)
          assert.is_nil(conf)
        end)
        it("requires trusted CA cert file to exist", function()
          local conf, _, errors = conf_loader(nil, {
            lua_ssl_trusted_certificate = "/path/cert.pem",
          })
          assert.equal(1, #errors)
          assert.contains("lua_ssl_trusted_certificate: failed loading certificate from /path/cert.pem", errors)
          assert.is_nil(conf)
        end)
        it("accepts several CA certs in lua_ssl_trusted_certificate, setting lua_ssl_trusted_certificate_combined", function()
          local conf, _, errors = conf_loader(nil, {
            lua_ssl_trusted_certificate = "spec/fixtures/kong_spec.crt,spec/fixtures/kong_clustering.crt",
          })
          assert.is_nil(errors)
          assert.same({
            pl_path.abspath("spec/fixtures/kong_spec.crt"),
            pl_path.abspath("spec/fixtures/kong_clustering.crt"),
          }, conf.lua_ssl_trusted_certificate)
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)
        end)
        it("expands the `system` property in lua_ssl_trusted_certificate", function()
          local utils = require "kong.tools.system"

          local old_gstcf = utils.get_system_trusted_certs_filepath
          local old_exists = pl_path.exists
          finally(function()
            utils.get_system_trusted_certs_filepath = old_gstcf
            pl_path.exists = old_exists
          end)
          local system_path = "spec/fixtures/kong_spec.crt"
          utils.get_system_trusted_certs_filepath = function()
            return system_path
          end
          pl_path.exists = function(path)
            return path == system_path or old_exists(path)
          end

          local conf, _, errors = conf_loader(nil, {
            lua_ssl_trusted_certificate = "system",
          })
          assert.is_nil(errors)
          assert.same({
            pl_path.abspath(system_path),
          }, conf.lua_ssl_trusted_certificate)
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)

          -- test default
          local conf, _, errors = conf_loader(nil, {})
          assert.is_nil(errors)
          assert.same({
            pl_path.abspath(system_path),
          }, conf.lua_ssl_trusted_certificate)
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)
        end)
        it("does not throw errors if the host doesn't have system certificates", function()
          local old_exists = pl_path.exists
          finally(function()
            pl_path.exists = old_exists
          end)
          pl_path.exists = function(path)
            return false
          end
          local _, _, errors = conf_loader(nil, {
            lua_ssl_trusted_certificate = "system",
          })
          assert.is_nil(errors)
        end)
        it("requires cluster_cert and key files to exist", function()
          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_cert = "path/kong_clustering.crt",
            cluster_cert_key = "path/kong_clustering.key",
          })
          assert.equal(2, #errors)
          assert.contains("cluster_cert: failed loading certificate from path/kong_clustering.crt", errors)
          assert.contains("cluster_cert_key: failed loading key from path/kong_clustering.key", errors)
          assert.is_nil(conf)
        end)
        it("requires cluster_ca_cert file to exist", function()
          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_ca_cert = "path/kong_clustering_ca.crt",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
          })
          assert.equal(1, #errors)
          assert.contains("cluster_ca_cert: failed loading certificate from path/kong_clustering_ca.crt", errors)
          assert.is_nil(conf)
        end)
        it("autoload cluster_cert or cluster_ca_cert for data plane in lua_ssl_trusted_certificate", function()
          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
          })
          assert.is_nil(errors)
          assert.contains(
            pl_path.abspath("spec/fixtures/kong_clustering.crt"),
            conf.lua_ssl_trusted_certificate
          )
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)

          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_mtls = "pki",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_ca_cert = "spec/fixtures/kong_clustering_ca.crt",
          })
          assert.is_nil(errors)
          assert.contains(
            pl_path.abspath("spec/fixtures/kong_clustering_ca.crt"),
            conf.lua_ssl_trusted_certificate
          )
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)
        end)

        it("autoload base64 cluster_cert or cluster_ca_cert for data plane in lua_ssl_trusted_certificate", function()
          local ssl_fixtures = require "spec.fixtures.ssl"
          local cert = ssl_fixtures.cert
          local cacert = ssl_fixtures.cert_ca
          local key = ssl_fixtures.key
          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_cert = ngx.encode_base64(cert),
            cluster_cert_key = ngx.encode_base64(key),
          })
          assert.is_nil(errors)
          assert.contains(
            cert,
            conf.lua_ssl_trusted_certificate
          )

          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_mtls = "pki",
            cluster_cert = ngx.encode_base64(cert),
            cluster_cert_key = ngx.encode_base64(key),
            cluster_ca_cert = ngx.encode_base64(cacert),
          })
          assert.is_nil(errors)
          assert.contains(
            cacert,
            conf.lua_ssl_trusted_certificate
          )
        end)

        it("validates proxy_server", function()
          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://cool:pwd@localhost:2333",
          })
          assert.is_nil(errors)
          assert.is_table(conf)

          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://😉.tld",
          })
          assert.is_nil(errors)
          assert.is_table(conf)

          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://%F0%9F%98%89.tld",
          })
          assert.is_nil(errors)
          assert.is_table(conf)

          local conf, _, errors = conf_loader(nil, {
            proxy_server = "://localhost:2333",
          })
          assert.contains("proxy_server missing scheme", errors)
          assert.is_nil(conf)


          local conf, _, errors = conf_loader(nil, {
            proxy_server = "cool://localhost:2333",
          })
          assert.contains("proxy_server only supports \"http\" and \"https\", got cool", errors)
          assert.is_nil(conf)

          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://:2333",
          })
          assert.contains("proxy_server missing host", errors)
          assert.is_nil(conf)


          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://localhost:2333/?a=1",
          })
          assert.contains("fragments, query strings or parameters are meaningless in proxy configuration", errors)
          assert.is_nil(conf)

          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://user:password%23@localhost:2333",
          })
          assert.is_nil(errors)
          assert.is_table(conf)

          local conf, _, errors = conf_loader(nil, {
            proxy_server = "http://user:password#@localhost:2333",
          })
          assert.contains("fragments, query strings or parameters are meaningless in proxy configuration", errors)
          assert.is_nil(conf)
        end)

        it("doesn't allow cluster_use_proxy on CP but allows on DP", function()
          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_use_proxy = "on",
          })
          assert.contains("cluster_use_proxy is turned on but no proxy_server is configured", errors)
          assert.is_nil(conf)

          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_use_proxy = "on",
            proxy_server = "http://user:pass@localhost:2333/",
          })
          assert.is_nil(errors)
          assert.is_table(conf)

          local conf, _, errors = conf_loader(nil, {
            role = "control_plane",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_use_proxy = "on",
          })
          assert.contains("cluster_use_proxy can not be used when role = \"control_plane\"", errors)
          assert.is_nil(conf)
        end)

        it("doen't overwrite lua_ssl_trusted_certificate when autoload cluster_cert or cluster_ca_cert", function()
          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            lua_ssl_trusted_certificate = "spec/fixtures/kong_spec.crt,spec/fixtures/kong_clustering_client.crt",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
          })
          assert.is_nil(errors)
          assert.same({
            pl_path.abspath("spec/fixtures/kong_spec.crt"),
            pl_path.abspath("spec/fixtures/kong_clustering_client.crt"),
            pl_path.abspath("spec/fixtures/kong_clustering.crt"),
          }, conf.lua_ssl_trusted_certificate)
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)

          local conf, _, errors = conf_loader(nil, {
            role = "data_plane",
            database = "off",
            lua_ssl_trusted_certificate = "spec/fixtures/kong_spec.crt,spec/fixtures/kong_clustering_client.crt",
            cluster_mtls = "pki",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_ca_cert = "spec/fixtures/kong_clustering_ca.crt",
          })
          assert.is_nil(errors)
          assert.same({
            pl_path.abspath("spec/fixtures/kong_spec.crt"),
            pl_path.abspath("spec/fixtures/kong_clustering_client.crt"),
            pl_path.abspath("spec/fixtures/kong_clustering_ca.crt"),
          }, conf.lua_ssl_trusted_certificate)
          assert.matches(".ca_combined", conf.lua_ssl_trusted_certificate_combined)
        end)
        it("doesn't load cluster_cert or cluster_ca_cert for control plane", function()
          local conf, _, errors = conf_loader(nil, {
            role = "control_plane",
            database = "postgres",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_ca_cert = "spec/fixtures/kong_clustering_ca.crt",
          })
          assert.is_nil(errors)
          assert.not_contains(
            pl_path.abspath("spec/fixtures/kong_clustering_ca.crt"),
            conf.lua_ssl_trusted_certificate
          )
        end)
        it("resolves SSL cert/key to absolute path", function()
          local conf, err = conf_loader(nil, {
            ssl_cert = "spec/fixtures/kong_spec.crt",
            ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          for i = 1, #conf.ssl_cert do
            assert.True(helpers.path.isabs(conf.ssl_cert[i]))
            assert.True(helpers.path.isabs(conf.ssl_cert_key[i]))
          end
        end)
        it("defines ssl_ciphers by default", function()
          local conf, err = conf_loader(nil, {})
          assert.is_nil(err)
          assert.equal("ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305", conf.ssl_ciphers)
        end)
        it("explicitly defines ssl_ciphers", function()
          local conf, err = conf_loader(nil, {
            ssl_cipher_suite = "old"
          })
          assert.is_nil(err)
          -- looks kinda like a cipher suite
          assert.matches(":", conf.ssl_ciphers, nil, true)
        end)
        it("errors on invalid ssl_cipher_suite", function()
          local conf, _, errors = conf_loader(nil, {
            ssl_cipher_suite = "foo"
          })
          assert.is_nil(conf)
          assert.equal(1, #errors)
          assert.matches("Undefined cipher suite foo", errors[1], nil, true)
        end)
        it("overrides ssl_ciphers when ssl_cipher_suite is custom", function()
          local conf, err = conf_loader(nil, {
            ssl_cipher_suite = "custom",
            ssl_ciphers      = "foo:bar",
          })
          assert.is_nil(err)
          assert.equals("foo:bar", conf.ssl_ciphers)
        end)
        it("doesn't override ssl_ciphers when undefined", function()
          local conf, err = conf_loader(nil, {
            ssl_cipher_suite = "custom",
          })
          assert.is_nil(err)
          assert.same(nil, conf.ssl_ciphers)
        end)
        it("defines ssl_dhparam with default cipher suite", function()
          local conf, err = conf_loader()
          assert.is_nil(err)
          assert.equal("ffdhe2048", conf.nginx_http_ssl_dhparam)
          assert.equal("ffdhe2048", conf.nginx_stream_ssl_dhparam)
        end)
        it("defines ssl_dhparam with intermediate cipher suite", function()
          local conf, err = conf_loader(nil, {
            ssl_cipher_suite = "intermediate",
          })
          assert.is_nil(err)
          assert.equal("ffdhe2048", conf.nginx_http_ssl_dhparam)
          assert.equal("ffdhe2048", conf.nginx_stream_ssl_dhparam)
        end)
        it("doesn't define ssl_dhparam with modern cipher suite", function()
          local conf, err = conf_loader(nil, {
            ssl_cipher_suite = "modern",
          })
          assert.is_nil(err)
          assert.equal(nil, conf.nginx_http_ssl_dhparam)
          assert.equal(nil, conf.nginx_stream_ssl_dhparam)
        end)
        it("doesn't define ssl_dhparam with old cipher suite (#todo)", function()
          local conf, err = conf_loader(nil, {
            ssl_cipher_suite = "old",
          })
          assert.is_nil(err)
          assert.equal(nil, conf.nginx_http_ssl_dhparam)
          assert.equal(nil, conf.nginx_stream_ssl_dhparam)
        end)
      end)
      describe("client", function()
        it("requires both proxy SSL cert and key", function()
          local conf, err = conf_loader(nil, {
            client_ssl = true,
            client_ssl_cert = "/path/cert.pem"
          })
          assert.equal("client_ssl_cert_key must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            client_ssl = true,
            client_ssl_cert_key = "/path/key.pem"
          })
          assert.equal("client_ssl_cert must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            client_ssl = true,
            client_ssl_cert = "spec/fixtures/kong_spec.crt",
            client_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires SSL cert and key to exist", function()
          local conf, _, errors = conf_loader(nil, {
            client_ssl = true,
            client_ssl_cert = "/path/cert.pem",
            client_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(2, #errors)
          assert.contains("client_ssl_cert: failed loading certificate from /path/cert.pem", errors)
          assert.contains("client_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)

          conf, _, errors = conf_loader(nil, {
            client_ssl = true,
            client_ssl_cert = "spec/fixtures/kong_spec.crt",
            client_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(1, #errors)
          assert.contains("client_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)
        end)
        it("resolves SSL cert/key to absolute path", function()
          local conf, err = conf_loader(nil, {
            client_ssl = true,
            client_ssl_cert = "spec/fixtures/kong_spec.crt",
            client_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          assert.True(helpers.path.isabs(conf.client_ssl_cert))
          assert.True(helpers.path.isabs(conf.client_ssl_cert_key))
        end)
      end)
      describe("admin", function()
        it("does not check SSL cert and key if SSL is off", function()
          local conf, err = conf_loader(nil, {
            admin_listen = "127.0.0.1:123",
            admin_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          -- specific case with 'ssl' in the name
          local conf, err = conf_loader(nil, {
            admin_listen = "ssl:23",
            admin_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires both admin SSL cert and key", function()
          local conf, err = conf_loader(nil, {
            admin_ssl_cert = "/path/cert.pem"
          })
          assert.equal("admin_ssl_cert_key must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            admin_ssl_cert_key = "/path/key.pem"
          })
          assert.equal("admin_ssl_cert must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            admin_ssl_cert = "spec/fixtures/kong_spec.crt",
            admin_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires SSL cert and key to exist", function()
          local conf, _, errors = conf_loader(nil, {
            admin_ssl_cert = "/path/cert.pem",
            admin_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(2, #errors)
          assert.contains("admin_ssl_cert: failed loading certificate from /path/cert.pem", errors)
          assert.contains("admin_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)

          conf, _, errors = conf_loader(nil, {
            admin_ssl_cert = "spec/fixtures/kong_spec.crt",
            admin_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(1, #errors)
          assert.contains("admin_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)
        end)
        it("resolves SSL cert/key to absolute path", function()
          local conf, err = conf_loader(nil, {
            admin_ssl_cert = "spec/fixtures/kong_spec.crt",
            admin_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          for i = 1, #conf.admin_ssl_cert do
            assert.True(helpers.path.isabs(conf.admin_ssl_cert[i]))
            assert.True(helpers.path.isabs(conf.admin_ssl_cert_key[i]))
          end
        end)
      end)
      describe("admin-gui", function()
        it("does not check SSL cert and key if SSL is off", function()
          local conf, err = conf_loader(nil, {
            admin_gui_listen = "127.0.0.1:123",
            admin_gui_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          -- specific case with 'ssl' in the name
          local conf, err = conf_loader(nil, {
            admin_gui_listen = "ssl:23",
            admin_gui_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires both SSL cert and key present", function()
          local conf, err = conf_loader(nil, {
            admin_gui_ssl_cert = "/path/cert.pem"
          })
          assert.equal("admin_gui_ssl_cert_key must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            admin_gui_ssl_cert_key = "/path/key.pem"
          })
          assert.equal("admin_gui_ssl_cert must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            admin_gui_ssl_cert = "spec/fixtures/kong_spec.crt",
            admin_gui_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires SSL cert and key to exist", function()
          local conf, _, errors = conf_loader(nil, {
            admin_gui_ssl_cert = "/path/cert.pem",
            admin_gui_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(2, #errors)
          assert.contains("admin_gui_ssl_cert: failed loading certificate from /path/cert.pem", errors)
          assert.contains("admin_gui_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)

          conf, _, errors = conf_loader(nil, {
            admin_gui_ssl_cert = "spec/fixtures/kong_spec.crt",
            admin_gui_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(1, #errors)
          assert.contains("admin_gui_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)
        end)
        it("resolves SSL cert/key to absolute path", function()
          local conf, err = conf_loader(nil, {
            admin_gui_ssl_cert = "spec/fixtures/kong_spec.crt",
            admin_gui_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          for i = 1, #conf.admin_gui_ssl_cert do
            assert.True(helpers.path.isabs(conf.admin_gui_ssl_cert[i]))
            assert.True(helpers.path.isabs(conf.admin_gui_ssl_cert_key[i]))
          end
        end)
      end)
      describe("status", function()
        it("does not check SSL cert and key if SSL is off", function()
          local conf, err = conf_loader(nil, {
            status_listen = "127.0.0.1:123",
            status_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          -- specific case with 'ssl' in the name
          local conf, err = conf_loader(nil, {
            status_listen = "ssl:23",
            status_ssl_cert = "/path/cert.pem"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires both status SSL cert and key", function()
          local conf, err = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl",
            status_ssl_cert = "/path/cert.pem"
          })
          assert.equal("status_ssl_cert_key must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl",
            status_ssl_cert_key = "/path/key.pem"
          })
          assert.equal("status_ssl_cert must be specified", err)
          assert.is_nil(conf)

          conf, err = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl",
            status_ssl_cert = "spec/fixtures/kong_spec.crt",
            status_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
        end)
        it("requires SSL cert and key to exist", function()
          local conf, _, errors = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl",
            status_ssl_cert = "/path/cert.pem",
            status_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(2, #errors)
          assert.contains("status_ssl_cert: failed loading certificate from /path/cert.pem", errors)
          assert.contains("status_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)

          conf, _, errors = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl",
            status_ssl_cert = "spec/fixtures/kong_spec.crt",
            status_ssl_cert_key = "/path/cert_key.pem"
          })
          assert.equal(1, #errors)
          assert.contains("status_ssl_cert_key: failed loading key from /path/cert_key.pem", errors)
          assert.is_nil(conf)
        end)
        it("resolves SSL cert/key to absolute path", function()
          local conf, err = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl",
            status_ssl_cert = "spec/fixtures/kong_spec.crt",
            status_ssl_cert_key = "spec/fixtures/kong_spec.key"
          })
          assert.is_nil(err)
          assert.is_table(conf)
          for i = 1, #conf.status_ssl_cert do
            assert.True(helpers.path.isabs(conf.status_ssl_cert[i]))
            assert.True(helpers.path.isabs(conf.status_ssl_cert_key[i]))
          end
        end)
        it("supports HTTP/2", function()
          local conf, err = conf_loader(nil, {
            status_listen = "127.0.0.1:123 ssl http2",
          })
          assert.is_nil(err)
          assert.is_table(conf)
          assert.same({ "127.0.0.1:123 ssl http2" }, conf.status_listen)
        end)
      end)

      describe("lua_ssl_protocls", function()
        it("sets lua_ssl_protocols to TLS 1.2-1.3 by default", function()
          local conf, err = conf_loader()
          assert.is_nil(err)
          assert.is_table(conf)

          assert.equal("TLSv1.2 TLSv1.3", conf.nginx_http_lua_ssl_protocols)
          assert.equal("TLSv1.2 TLSv1.3", conf.nginx_stream_lua_ssl_protocols)
        end)

        it("sets lua_ssl_protocols to user specified value", function()
          local conf, err = conf_loader(nil, {
            lua_ssl_protocols = "TLSv1.2"
          })
          assert.is_nil(err)
          assert.is_table(conf)

          assert.equal("TLSv1.2", conf.nginx_http_lua_ssl_protocols)
          assert.equal("TLSv1.2", conf.nginx_stream_lua_ssl_protocols)
        end)

        it("sets nginx_http_lua_ssl_protocols and nginx_stream_lua_ssl_protocols to different values", function()
          local conf, err = conf_loader(nil, {
            nginx_http_lua_ssl_protocols = "TLSv1.2",
            nginx_stream_lua_ssl_protocols = "TLSv1.3",
          })
          assert.is_nil(err)
          assert.is_table(conf)

          assert.equal("TLSv1.2", conf.nginx_http_lua_ssl_protocols)
          assert.equal("TLSv1.3", conf.nginx_stream_lua_ssl_protocols)
        end)
      end)
    end)
    it("honors path if provided even if a default file exists", function()
      conf_loader.add_default_path("spec/fixtures/to-strip.conf")

      local _os_getenv = os.getenv
      finally(function()
        os.getenv = _os_getenv -- luacheck: ignore
        package.loaded["kong.conf_loader"] = nil
        package.loaded["kong.conf_loader.constants"] = nil
        conf_loader = require "kong.conf_loader"
      end)
      os.getenv = function() end -- luacheck: ignore

      local conf = assert(conf_loader(helpers.test_conf_path))
      assert.equal(DATABASE, conf.database)
    end)
    it("honors path if provided even if a default file exists", function()
      conf_loader.add_default_path("spec/fixtures/to-strip.conf")

      local _os_getenv = os.getenv
      finally(function()
        os.getenv = _os_getenv -- luacheck: ignore
        package.loaded["kong.conf_loader"] = nil
        package.loaded["kong.conf_loader.constants"] = nil
        conf_loader = require "kong.conf_loader"
      end)
      os.getenv = function() end -- luacheck: ignore

      local conf = assert(conf_loader(helpers.test_conf_path))
      assert.equal(DATABASE, conf.database)
    end)
    it("should warns user if kong manager is enabled but admin API is not enabled", function ()
      local spy_log = spy.on(log, "warn")

      finally(function()
        log.warn:revert()
        assert:unregister("matcher", "str_match")
      end)

      assert:register("matcher", "str_match", function (_state, arguments)
        local expected = arguments[1]
        return function(value)
          return string.match(value, expected) ~= nil
        end
      end)

      local conf, err = conf_loader(nil, {
        admin_listen = "off",
        admin_gui_listen = "off",
      })
      assert.is_nil(err)
      assert.is_table(conf)
      assert.spy(spy_log).was_called(0)

      conf, err = conf_loader(nil, {
        admin_listen = "localhost:8001",
        admin_gui_listen = "off",
      })
      assert.is_nil(err)
      assert.is_table(conf)
      assert.spy(spy_log).was_called(0)

      conf, err = conf_loader(nil, {
        admin_listen = "localhost:8001",
        admin_gui_listen = "localhost:8002",
      })
      assert.is_nil(err)
      assert.is_table(conf)
      assert.spy(spy_log).was_called(0)

      conf, err = conf_loader(nil, {
        admin_listen = "off",
        admin_gui_listen = "localhost:8002",
      })
      assert.is_nil(err)
      assert.is_table(conf)
      assert.spy(spy_log).was_called(1)
      assert.spy(spy_log).was_called_with("Kong Manager won't be functional because the Admin API is not listened on any interface")
    end)
  end)

  describe("pg_semaphore options", function()
    it("rejects a pg_max_concurrent_queries with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_max_concurrent_queries = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_max_concurrent_queries must be greater than 0", err)
    end)

    it("rejects a pg_max_concurrent_queries with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_max_concurrent_queries = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_max_concurrent_queries must be an integer greater than 0", err)
    end)

    it("rejects a pg_semaphore_timeout with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_semaphore_timeout = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_semaphore_timeout must be greater than 0", err)
    end)

    it("rejects a pg_semaphore_timeout with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_semaphore_timeout = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_semaphore_timeout must be an integer greater than 0", err)
    end)
  end)

  describe("pg connection pool options", function()
    it("rejects a pg_keepalive_timeout with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_keepalive_timeout = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_keepalive_timeout must be greater than 0", err)
    end)

    it("rejects a pg_keepalive_timeout with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_keepalive_timeout = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_keepalive_timeout must be an integer greater than 0", err)
    end)

    it("rejects a pg_pool_size with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_pool_size = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_pool_size must be greater than 0", err)
    end)

    it("rejects a pg_pool_size with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_pool_size = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_pool_size must be an integer greater than 0", err)
    end)

    it("rejects a pg_backlog with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_backlog = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_backlog must be greater than 0", err)
    end)

    it("rejects a pg_backlog with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_backlog = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_backlog must be an integer greater than 0", err)
    end)
  end)

  describe("pg read-only connection pool options", function()
    it("rejects a pg_ro_keepalive_timeout with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_ro_keepalive_timeout = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_ro_keepalive_timeout must be greater than 0", err)
    end)

    it("rejects a pg_ro_keepalive_timeout with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_ro_keepalive_timeout = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_ro_keepalive_timeout must be an integer greater than 0", err)
    end)

    it("rejects a pg_ro_pool_size with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_ro_pool_size = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_ro_pool_size must be greater than 0", err)
    end)

    it("rejects a pg_ro_pool_size with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_ro_pool_size = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_ro_pool_size must be an integer greater than 0", err)
    end)

    it("rejects a pg_ro_backlog with a negative number", function()
      local conf, err = conf_loader(nil, {
        pg_ro_backlog = -1,
      })
      assert.is_nil(conf)
      assert.equal("pg_ro_backlog must be greater than 0", err)
    end)

    it("rejects a pg_ro_backlog with a decimal", function()
      local conf, err = conf_loader(nil, {
        pg_ro_backlog = 0.1,
      })
      assert.is_nil(conf)
      assert.equal("pg_ro_backlog must be an integer greater than 0", err)
    end)
  end)

  describe("worker_state_update_frequency option", function()
    it("is rejected with a zero", function()
      local conf, err = conf_loader(nil, {
        worker_state_update_frequency = 0,
      })
      assert.is_nil(conf)
      assert.equal("worker_state_update_frequency must be greater than 0", err)
    end)
    it("is rejected with a negative number", function()
      local conf, err = conf_loader(nil, {
        worker_state_update_frequency = -1,
      })
      assert.is_nil(conf)
      assert.equal("worker_state_update_frequency must be greater than 0", err)
    end)
    it("accepts decimal numbers", function()
      local conf, err = conf_loader(nil, {
        worker_state_update_frequency = 0.01,
      })
      assert.equal(conf.worker_state_update_frequency, 0.01)
      assert.is_nil(err)
    end)
  end)

  describe("clustering properties", function()
    it("cluster_data_plane_purge_delay is accepted", function()
      local conf = assert(conf_loader(nil, {
        cluster_data_plane_purge_delay = 100,
      }))
      assert.equal(100, conf.cluster_data_plane_purge_delay)

      conf = assert(conf_loader(nil, {
        cluster_data_plane_purge_delay = 60,
      }))
      assert.equal(60, conf.cluster_data_plane_purge_delay)
    end)

    it("cluster_data_plane_purge_delay < 60 is rejected", function()
      local conf, err = conf_loader(nil, {
        cluster_data_plane_purge_delay = 59,
      })
      assert.is_nil(conf)
      assert.equal("cluster_data_plane_purge_delay must be 60 or greater", err)
    end)

    it("cluster_max_payload is accepted", function()
      local conf = assert(conf_loader(nil, {
        cluster_max_payload = 4194304,
      }))
      assert.equal(4194304, conf.cluster_max_payload)

      conf = assert(conf_loader(nil, {
        cluster_max_payload = 8388608,
      }))
      assert.equal(8388608, conf.cluster_max_payload)
    end)

    it("cluster_max_payload < 4Mb rejected", function()
      local conf, err = conf_loader(nil, {
        cluster_max_payload = 1048576,
      })
      assert.is_nil(conf)
      assert.equal("cluster_max_payload must be 4194304 (4MB) or greater", err)
    end)
  end)

  describe("upstream keepalive properties", function()
    it("are accepted", function()
      local conf = assert(conf_loader(nil, {
        upstream_keepalive_pool_size = 10,
        upstream_keepalive_max_requests = 20,
        upstream_keepalive_idle_timeout = 30,
      }))
      assert.equal(10, conf.upstream_keepalive_pool_size)
      assert.equal(20, conf.upstream_keepalive_max_requests)
      assert.equal(30, conf.upstream_keepalive_idle_timeout)
    end)

    it("accepts upstream_keepalive_pool_size = 0", function()
      local conf = assert(conf_loader(nil, {
        upstream_keepalive_pool_size = 0,
      }))
      assert.equal(0, conf.upstream_keepalive_pool_size)
    end)

    it("accepts upstream_keepalive_max_requests = 0", function()
      local conf = assert(conf_loader(nil, {
        upstream_keepalive_max_requests = 0,
      }))
      assert.equal(0, conf.upstream_keepalive_max_requests)
    end)

    it("accepts upstream_keepalive_idle_timeout = 0", function()
      local conf = assert(conf_loader(nil, {
        upstream_keepalive_idle_timeout = 0,
      }))
      assert.equal(0, conf.upstream_keepalive_idle_timeout)
    end)

    it("rejects negative values", function()
      local conf, err = conf_loader(nil, {
        upstream_keepalive_pool_size = -1,
      })
      assert.is_nil(conf)
      assert.equal("upstream_keepalive_pool_size must be 0 or greater", err)

      local conf, err = conf_loader(nil, {
        upstream_keepalive_max_requests = -1,
      })
      assert.is_nil(conf)
      assert.equal("upstream_keepalive_max_requests must be 0 or greater", err)

      local conf, err = conf_loader(nil, {
        upstream_keepalive_idle_timeout = -1,
      })
      assert.is_nil(conf)
      assert.equal("upstream_keepalive_idle_timeout must be 0 or greater", err)
    end)
  end)

  describe("#wasm properties", function()
    local temp_dir, cleanup
    local user_filters
    local bundled_filters
    local all_filters

    lazy_setup(function()
      temp_dir, cleanup = helpers.make_temp_dir()
      assert(helpers.file.write(temp_dir .. "/filter-a.wasm", "hello!"))
      assert(helpers.file.write(temp_dir .. "/filter-b.wasm", "hello!"))

      user_filters = {
        {
          name = "filter-a",
          path = temp_dir .. "/filter-a.wasm",
        },
        {
          name = "filter-b",
          path = temp_dir .. "/filter-b.wasm",
        }
      }

      do
        -- for local builds, the bundled filter path is not constant, so we
        -- must load the config first to discover the path
        local conf = assert(conf_loader(nil, {
          wasm = "on",
          wasm_filters = "bundled",
        }))

        assert(conf.wasm_bundled_filters_path)
        bundled_filters = {}
      end

      all_filters = {}
      table.insert(all_filters, bundled_filters[1])
      table.insert(all_filters, user_filters[1])
      table.insert(all_filters, user_filters[2])
    end)

    lazy_teardown(function() cleanup() end)

    it("wasm disabled", function()
      local conf, err = conf_loader(nil, {
        wasm = "off",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.is_nil(conf.wasm_modules_parsed)
    end)

    it("wasm default disabled", function()
      local conf, err = conf_loader(nil, {
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.is_nil(conf.wasm_modules_parsed)
    end)

    it("wasm_filters_path", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.same(all_filters, conf.wasm_modules_parsed)
      assert.same(temp_dir, conf.wasm_filters_path)
    end)

    it("invalid wasm_filters_path", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters_path = "spec/fixtures/no-wasm-here/unit-test",
      })
      assert.same(err, "wasm_filters_path 'spec/fixtures/no-wasm-here/unit-test' is not a valid directory")
      assert.is_nil(conf)
    end)

    it("wasm_filters default", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.same(all_filters, conf.wasm_modules_parsed)
      assert.same({ "bundled", "user" }, conf.wasm_filters)
    end)

    it("wasm_filters = off", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters = "off",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.same({}, conf.wasm_modules_parsed)
    end)

    it("wasm_filters = 'user' allows all user filters", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters = "user",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.same(user_filters, conf.wasm_modules_parsed)
    end)

    it("wasm_filters can allow individual user filters", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters = assert(user_filters[1].name),
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.same({ user_filters[1] }, conf.wasm_modules_parsed)
    end)

    it("wasm_filters = 'bundled' allows all bundled filters", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters = "bundled",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)
      assert.same(bundled_filters, conf.wasm_modules_parsed)
    end)

    -- XXX: we don't have any bundled filters to use for this test
    pending("prefers user filters to bundled filters when a conflict exists", function()
      local user_filter = temp_dir .. "/datakit.wasm"
      assert(helpers.file.write(user_filter, "I'm a happy little wasm filter"))
      finally(function()
        assert(os.remove(user_filter))
      end)

      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters = "bundled,user",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)

      local found = false
      for _, filter in ipairs(conf.wasm_modules_parsed) do
        if filter.name == "datakit" then
          found = true
          assert.equals(user_filter, filter.path,
                        "user filter should override the bundled filter")
        end
      end

      assert.is_true(found, "expected the user filter to be enabled")
    end)

    it("populates wasmtime_cache_* properties", function()
      local conf, err = conf_loader(nil, {
        wasm = "on",
        wasm_filters = "bundled,user",
        wasm_filters_path = temp_dir,
      })
      assert.is_nil(err)

      assert.is_string(conf.wasmtime_cache_directory,
                       "wasmtime_cache_directory was not set")
      assert.is_string(conf.wasmtime_cache_config_file,
                       "wasmtime_cache_config_file was not set")
    end)
  end)

  describe("errors", function()
    it("returns inexistent file", function()
      local conf, err = conf_loader "inexistent"
      assert.equal("no file at: inexistent", err)
      assert.is_nil(conf)
    end)
    it("returns all errors in ret value #3", function()
      local conf, _, errors = conf_loader(nil, {
        worker_consistency = "magical",
        ssl_cert_key = "spec/fixtures/kong_spec.key",
      })

      assert.equal(2, #errors)
      assert.is_nil(conf)
      assert.contains("worker_consistency has an invalid value: 'magical' (strict, eventual)",
        errors, true)
      assert.contains("ssl_cert must be specified", errors)
    end)
  end)

  describe("remove_sensitive()", function()
    it("replaces sensitive settings", function()
      local conf = assert(conf_loader(nil, {
        pg_password = "hide_me",
      }))

      local purged_conf = conf_loader.remove_sensitive(conf)
      assert.not_equal("hide_me", purged_conf.pg_password)
    end)

    it("replaces sensitive vault resolved settings", function()
      finally(function()
        helpers.unsetenv("PG_PASSWORD")
        helpers.unsetenv("PG_DATABASE")
      end)

      helpers.setenv("PG_PASSWORD", "pg-password")
      helpers.setenv("PG_DATABASE", "pg-database")

      local conf = assert(conf_loader(nil, {
        pg_password = "{vault://env/pg-password}",
        pg_database = "{vault://env/pg-database}",
      }))

      local purged_conf = conf_loader.remove_sensitive(conf)
      assert.equal("******", purged_conf.pg_password)
      assert.equal("{vault://env/pg-database}", purged_conf.pg_database)
      assert.is_nil(purged_conf["$refs"])
    end)

    it("does not insert placeholder if no value", function()
      local conf = assert(conf_loader())
      local purged_conf = conf_loader.remove_sensitive(conf)
      assert.is_nil(purged_conf.pg_password)
    end)
  end)

  describe("number as string", function()
    it("force the numeric pg_password to a string", function()
      local conf = assert(conf_loader(nil, {
        pg_password = 123456,
      }))

      assert.equal("123456", conf.pg_password)
    end)
  end)

  describe("deprecated properties", function()
    it("worker_consistency -> deprecate value <strict>", function()
      local conf, err = assert(conf_loader(nil, {
        worker_consistency = "strict"
      }))
      assert.equal("strict", conf.worker_consistency)
      assert.equal(nil, err)
    end)

    it("privileged_agent -> dedicated_config_processing", function()
      local conf, err = assert(conf_loader(nil, {
        privileged_agent = "on",
      }))
      assert.same(nil, conf.privileged_agent)
      assert.same(true, conf.dedicated_config_processing)
      assert.equal(nil, err)

      -- no clobber
      conf, err = assert(conf_loader(nil, {
        privileged_agent = "on",
        dedicated_config_processing = "on",
      }))
      assert.same(true, conf.dedicated_config_processing)
      assert.same(nil, conf.privileged_agent)
      assert.equal(nil, err)

      conf, err = assert(conf_loader(nil, {
        privileged_agent = "off",
        dedicated_config_processing = "on",
      }))
      assert.same(true, conf.dedicated_config_processing)
      assert.same(nil, conf.privileged_agent)
      assert.equal(nil, err)

      conf, err = assert(conf_loader(nil, {
        privileged_agent = "on",
        dedicated_config_processing = "off",
      }))
      assert.same(false, conf.dedicated_config_processing)
      assert.same(nil, conf.privileged_agent)
      assert.equal(nil, err)

      conf, err = assert(conf_loader(nil, {
        privileged_agent = "off",
        dedicated_config_processing = "off",
      }))
      assert.same(false, conf.dedicated_config_processing)
      assert.same(nil, conf.privileged_agent)
      assert.equal(nil, err)
    end)

    it("opentelemetry_tracing", function()
      local conf, err = assert(conf_loader(nil, {
        opentelemetry_tracing = "request,router",
      }))
      assert.same({"request", "router"}, conf.tracing_instrumentations)
      assert.equal(nil, err)

      -- no clobber
      conf, err = assert(conf_loader(nil, {
        opentelemetry_tracing = "request,router",
        tracing_instrumentations = "balancer",
      }))
      assert.same({ "balancer" }, conf.tracing_instrumentations)
      assert.equal(nil, err)
    end)

    it("opentelemetry_tracing_sampling_rate", function()
      local conf, err = assert(conf_loader(nil, {
        opentelemetry_tracing_sampling_rate = 0.5,
      }))
      assert.same(0.5, conf.tracing_sampling_rate)
      assert.equal(nil, err)

      -- no clobber
      conf, err = assert(conf_loader(nil, {
        opentelemetry_tracing_sampling_rate = 0.5,
        tracing_sampling_rate = 0.75,
      }))
      assert.same(0.75, conf.tracing_sampling_rate)
      assert.equal(nil, err)
    end)
  end)

  describe("vault references", function()
    it("are collected under $refs property", function()
      finally(function()
        helpers.unsetenv("PG_DATABASE")
      end)

      helpers.setenv("PG_DATABASE", "pg-database")

      local conf = assert(conf_loader(nil, {
        pg_database = "{vault://env/pg-database}",
      }))

      assert.equal("pg-database", conf.pg_database)
      assert.equal("{vault://env/pg-database}", conf["$refs"].pg_database)
    end)
    it("are inferred and collected under $refs property", function()
      finally(function()
        helpers.unsetenv("PG_PORT")
      end)

      helpers.setenv("PG_PORT", "5000")

      local conf = assert(conf_loader(nil, {
        pg_port = "{vault://env/pg-port#0}",
      }))

      assert.equal(5000, conf.pg_port)
      assert.equal("{vault://env/pg-port#0}", conf["$refs"].pg_port)
    end)
    it("fields in CONF_BASIC can reference env non-entity vault", function()
      helpers.setenv("VAULT_TEST", "testvalue")
      helpers.setenv("VAULT_PG", "postgres")
      helpers.setenv("VAULT_CERT", "/tmp")
      helpers.setenv("VAULT_DEPTH", "3")
      finally(function()
        helpers.unsetenv("VAULT_TEST")
        helpers.unsetenv("VAULT_PG")
        helpers.unsetenv("VAULT_CERT")
        helpers.unsetenv("VAULT_DEPTH")
      end)
      local CONF_BASIC = {
        prefix = true,
        -- vaults = true, -- except this one
        database = true,
        lmdb_environment_path = true,
        lmdb_map_size = true,
        lua_ssl_trusted_certificate = true,
        lua_ssl_verify_depth = true,
        lua_ssl_protocols = true,
        nginx_http_lua_ssl_protocols = true,
        nginx_stream_lua_ssl_protocols = true,
        -- vault_env_prefix = true, -- except this one
      }
      for k, _ in pairs(CONF_BASIC) do
        if k == "database" then
          local conf, err = conf_loader(nil, {
            [k] = "{vault://env/vault_pg}",
          })
          assert.is_nil(err)
          assert.equal("postgres", conf.database)
        elseif k == "lua_ssl_trusted_certificate" then
          local conf, err = conf_loader(nil, {
            [k] = "{vault://env/vault_cert}",
          })
          assert.is_nil(err)
          assert.equal("table", type(conf.lua_ssl_trusted_certificate))
          assert.equal("/tmp", conf.lua_ssl_trusted_certificate[1])
        elseif k == "lua_ssl_verify_depth" then
          local conf, err = conf_loader(nil, {
            [k] = "{vault://env/vault_depth}",
          })
          assert.is_nil(err)
          assert.equal(3, conf.lua_ssl_verify_depth)
        else
          local conf, err = conf_loader(nil, {
            [k] = "{vault://env/vault_test}",
          })
          assert.is_nil(err)
          -- may be converted into an absolute path
          assert.matches(".*testvalue", conf[k])
        end
      end
    end)
    it("fields in CONF_BASIC will fail to reference vault if vault has other dependency", function()
      local CONF_BASIC = {
        prefix = true,
        vaults = true,
        database = true,
        lmdb_environment_path = true,
        lmdb_map_size = true,
        lua_ssl_trusted_certificate = true,
        lua_ssl_verify_depth = true,
        lua_ssl_protocols = true,
        nginx_http_lua_ssl_protocols = true,
        nginx_stream_lua_ssl_protocols = true,
        vault_env_prefix = true,
      }
      for k, _ in pairs(CONF_BASIC) do
        local conf, err = conf_loader(nil, {
          [k] = "{vault://test-env/test}",
        })
        -- fail to reference
        if k == "lua_ssl_trusted_certificate" or k == "database" then
          assert.is_not_nil(err)
        elseif k == "lua_ssl_verify_depth" then
          assert.is_nil(conf[k])
        elseif k == "vaults" then
          assert.is_nil(err)
          assert.equal("table", type(conf.vaults))
          assert.matches("{vault://test%-env/test}", conf.vaults[1])
        elseif k == "prefix" then
          assert.is_nil(err)
          assert.matches(".*{vault:/test%-env/test}", conf[k])
        else
          assert.is_nil(err)
          -- path may have a prefix added
          assert.matches(".*{vault://test%-env/test}", conf[k])
        end
      end
    end)
    it("only load a subset of fields when opts.pre_cmd=true", function()
      local FIELDS = {
        -- CONF_BASIC
        prefix = true,
        socket_path = true,
        worker_events_sock = true,
        stream_worker_events_sock = true,
        stream_rpc_sock = true,
        stream_config_sock = true,
        stream_tls_passthrough_sock = true,
        stream_tls_terminate_sock = true,
        cluster_proxy_ssl_terminator_sock = true,
        vaults = true,
        database = true,
        lmdb_environment_path = true,
        lmdb_map_size = true,
        lua_ssl_trusted_certificate = true,
        lua_ssl_verify_depth = true,
        lua_ssl_protocols = true,
        nginx_http_lua_ssl_protocols = true,
        nginx_stream_lua_ssl_protocols = true,
        vault_env_prefix = true,

        loaded_vaults = true,
        lua_ssl_trusted_certificate_combined = true,

        -- PREFIX_PATHS
        nginx_pid = true,
        nginx_err_logs = true,
        nginx_acc_logs = true,
        admin_acc_logs = true,
        nginx_conf = true,
        nginx_kong_gui_include_conf= true,
        nginx_kong_conf = true,
        nginx_kong_stream_conf = true,
        nginx_inject_conf = true,
        nginx_kong_inject_conf = true,
        nginx_kong_stream_inject_conf = true,
        kong_env = true,
        kong_process_secrets = true,
        ssl_cert_csr_default = true,
        ssl_cert_default = true,
        ssl_cert_key_default = true,
        ssl_cert_default_ecdsa = true,
        ssl_cert_key_default_ecdsa = true,
        client_ssl_cert_default = true,
        client_ssl_cert_key_default = true,
        admin_ssl_cert_default = true,
        admin_ssl_cert_key_default = true,
        admin_ssl_cert_default_ecdsa = true,
        admin_ssl_cert_key_default_ecdsa = true,
        status_ssl_cert_default = true,
        status_ssl_cert_key_default = true,
        status_ssl_cert_default_ecdsa = true,
        status_ssl_cert_key_default_ecdsa = true,
        admin_gui_ssl_cert_default = true,
        admin_gui_ssl_cert_key_default = true,
        admin_gui_ssl_cert_default_ecdsa = true,
        admin_gui_ssl_cert_key_default_ecdsa = true,
      }
      local conf = assert(conf_loader(nil, nil, { pre_cmd = true }))
      for k, _ in pairs(conf) do
        assert.equal(true, FIELDS[k], "key " .. k .. " is not in FIELDS")
      end
    end)
  end)

  describe("comments", function()
    it("are stripped", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      assert.equal("foo#bar", conf.pg_password)
    end)
  end)

  describe("lua max limits for request/response headers and request uri/post args", function()
    it("are accepted", function()
      local conf, err = assert(conf_loader(nil, {
        lua_max_req_headers = 1,
        lua_max_resp_headers = 100,
        lua_max_uri_args = 500,
        lua_max_post_args = 1000,
      }))

      assert.is_nil(err)

      assert.equal(1, conf.lua_max_req_headers)
      assert.equal(100, conf.lua_max_resp_headers)
      assert.equal(500, conf.lua_max_uri_args)
      assert.equal(1000, conf.lua_max_post_args)
    end)

    it("are not accepted with limits below 1", function()
      local _, err = conf_loader(nil, {
        lua_max_req_headers = 0,
      })
      assert.equal("lua_max_req_headers must be an integer between 1 and 1000", err)

      local _, err = conf_loader(nil, {
        lua_max_resp_headers = 0,
      })
      assert.equal("lua_max_resp_headers must be an integer between 1 and 1000", err)

      local _, err = conf_loader(nil, {
        lua_max_uri_args = 0,
      })
      assert.equal("lua_max_uri_args must be an integer between 1 and 1000", err)

      local _, err = conf_loader(nil, {
        lua_max_post_args = 0,
      })
      assert.equal("lua_max_post_args must be an integer between 1 and 1000", err)
    end)

    it("are not accepted with limits above 1000", function()
      local _, err = conf_loader(nil, {
        lua_max_req_headers = 1001,
      })
      assert.equal("lua_max_req_headers must be an integer between 1 and 1000", err)

      local _, err = conf_loader(nil, {
        lua_max_resp_headers = 1001,
      })
      assert.equal("lua_max_resp_headers must be an integer between 1 and 1000", err)

      local _, err = conf_loader(nil, {
        lua_max_uri_args = 1001,
      })
      assert.equal("lua_max_uri_args must be an integer between 1 and 1000", err)

      local _, err = conf_loader(nil, {
        lua_max_post_args = 1001,
      })
      assert.equal("lua_max_post_args must be an integer between 1 and 1000", err)
    end)
  end)

  describe("Labels", function()
    local pattern_match_err = ".+ is invalid. Must match pattern: .+"
    local size_err = ".* must have between 1 and %d+ characters"
    local invalid_key_err = "label key validation failed: "
    local invalid_val_err = "label value validation failed: "
    local valid_labels = {
      "deployment:mycloud,region:us-east-1",
      "label_0_name:label-1-value,label-1-name:label_1_value",
      "MY-LaB3L.nam_e:my_lA831..val",
      "super_kong:yey",
      "best_gateway:kong",
      "This_Key_Is_Just_The_Right_Maximum_Length_To_Pass_TheValidation:value",
      "key:This_Val_Is_Just_The_Right_Maximum_Length_To_Pass_TheValidation",
    }
    local invalid_labels = {
      {
        l = "t:h,e:s,E:a,r:e,T:o,o:m,a:n,y:l,A:b,ee:l,S:s",
        err = "labels validation failed: count exceeded %d+ max elements",
      },{
        l = "_must:start",
        err = invalid_key_err .. pattern_match_err,
      },{
        l = "and:.end",
        err = invalid_val_err .. pattern_match_err,
      },{
        l = "with-:alpha",
        err = invalid_key_err .. pattern_match_err,
      },{
        l = "numeric:characters_",
        err = invalid_val_err .. pattern_match_err,
      },{
        l = "kong_key:is_reserved",
        err = invalid_key_err .. pattern_match_err,
      },{
        l = "invalid!@chars:fail",
        err = invalid_key_err .. pattern_match_err,
      },{
        l = "the:val!dation",
        err = invalid_val_err .. pattern_match_err,
      },{
        l = "lonelykeywithnoval:",
        err = invalid_val_err .. size_err,
      },{
        l = "__look_this_key_is_way_too_long_no_way_it_will_pass_validation__:value",
        err = invalid_key_err .. size_err,
      },{
        l = "key:__look_this_val_is_way_too_long_no_way_it_will_pass_validation__",
        err = invalid_val_err .. size_err,
      },{
        l = "key",
        err = invalid_key_err .. size_err,
      }
    }

    it("succeeds to validate valid labels", function()
      for _, label in ipairs(valid_labels) do
        local conf, err = assert(conf_loader(nil, {
          role = "data_plane",
          database = "off",
          cluster_cert = "spec/fixtures/kong_clustering.crt",
          cluster_cert_key = "spec/fixtures/kong_clustering.key",
          cluster_dp_labels = label,
        }))
        assert.is_nil(err)
        assert.is_not_nil(conf.cluster_dp_labels)
      end
    end)

    it("fails validation for invalid labels", function()
      for _, label in ipairs(invalid_labels) do
        local _, err = conf_loader(nil, {
          role = "data_plane",
          database = "off",
          cluster_cert = "spec/fixtures/kong_clustering.crt",
          cluster_cert_key = "spec/fixtures/kong_clustering.key",
          cluster_dp_labels = label.l,
        })
        assert.is_not_nil(err)
        assert.matches(label.err, err)
      end
    end)
  end)

  describe("pluginserver config", function()
    describe("fails if", function()
      it("no query_command and not found in default location", function()
        local _, err = conf_loader(nil, {
          pluginserver_names = "gopher",
          -- query_command = {},
        })
        assert.is_not_nil(err)
        assert.matches("query_command undefined for pluginserver gopher", err)
      end)
    end)
    describe("warns if", function()
      it("no start_command (meaning process is externally maintained)", function()
        local spy_log = spy.on(log, "warn")

        finally(function()
          log.warn:revert()
          assert:unregister("matcher", "str_match")
        end)

        assert:register("matcher", "str_match", function (_state, arguments)
          local expected = arguments[1]
          return function(value)
            return string.match(value, expected) ~= nil
          end
        end)

        local _, err = conf_loader(nil, {
          pluginserver_names = "gopher",
          pluginserver_gopher_query_cmd = "gopher -dump",
        })
        assert.is_nil(err)
        assert.spy(spy_log).was_called(1)
        assert.spy(spy_log).was_called_with("start_command undefined for pluginserver gopher; assuming external process management")
      end)
    end)
    it("fills in default settings", function()
      -- mock default conf loader path - as we cannot
      -- reliably write in the default path (/usr/local/bin)
      package.loaded["kong.conf_loader"] = nil
      local conf_constants = require"kong.conf_loader.constants"
      conf_constants.DEFAULT_PLUGINSERVER_PATH = helpers.external_plugins_path .. "/go"
      local conf_loader = require"kong.conf_loader"

      helpers.build_go_plugins(helpers.external_plugins_path .. "/go")

      finally(function()
        package.loaded["kong.conf_loader"] = nil
        package.loaded["kong.conf_loader.constants"] = nil
      end)

      local conf, err = conf_loader(nil, {
        pluginserver_names = "go-hello",
        -- leave out start_command and query_command so that the defaults
        -- are used
      })
      assert.is_nil(err)
      assert.same("go-hello", conf.pluginservers[1].name)
      assert.same("./spec/fixtures/external_plugins/go/go-hello -dump", conf.pluginservers[1].query_command)
      assert.same("./spec/fixtures/external_plugins/go/go-hello", conf.pluginservers[1].start_command)
      assert.same(conf.prefix .. "/go-hello.socket", conf.pluginservers[1].socket)
    end)
    it("accepts custom settings", function()
      local conf, err = conf_loader(nil, {
        pluginserver_names = "gopher",
        pluginserver_gopher_query_cmd = "gopher -dump",
        pluginserver_gopher_start_cmd = "gopher -p $KONG_PREFIX",
        pluginserver_gopher_socket = "/foo/bar/gopher.socket",
      })
      assert.is_nil(err)
      assert.same("gopher", conf.pluginservers[1].name)
      assert.same("gopher -dump", conf.pluginservers[1].query_command)
      assert.same("gopher -p $KONG_PREFIX", conf.pluginservers[1].start_command)
      assert.same("/foo/bar/gopher.socket", conf.pluginservers[1].socket)
    end)
  end)
end)
