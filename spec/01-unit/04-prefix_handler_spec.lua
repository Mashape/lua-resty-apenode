local helpers = require "spec.helpers"
local conf_loader = require "kong.conf_loader"
local prefix_handler = require "kong.cmd.utils.prefix_handler"
local ffi = require "ffi"
local tablex = require "pl.tablex"
local ssl_fixtures = require "spec.fixtures.ssl"
local pl_path = require "pl.path"

local exists = helpers.path.exists
local join = helpers.path.join
local currentdir = pl_path.currentdir

local C = ffi.C


ffi.cdef([[
  struct group *getgrnam(const char *name);
  struct passwd *getpwnam(const char *name);
]])


-- the pattern expands to: "([%%%^%$%(%)%.%[%]%*%+%-%?])"
local escape_pattern = '(['..("%^$().[]*+-?"):gsub("(.)", "%%%1")..'])'
-- escape all the special characters %^$().[]*+-? in the string
-- e.g. "%^$().[]*+-?" ---> "%%%^%$%(%)%.%[%]%*%+%-%?"
local function escape_special_chars(str)
  return str:gsub(escape_pattern, "%%%1")
end

local function kong_user_group_exists()
  if C.getpwnam("kong") == nil or C.getgrnam("kong") == nil then
    return false
  else
    return true
  end
end


describe("NGINX conf compiler", function()
  describe("gen_default_ssl_cert()", function()
    local conf = assert(conf_loader(helpers.test_conf_path, {
      prefix = "ssl_tmp",
      ssl_cert = "spec/fixtures/kong_spec.crt",
      ssl_cert_key = "spec/fixtures/kong_spec.key",
      admin_ssl_cert = "spec/fixtures/kong_spec.crt",
      admin_ssl_cert_key = "spec/fixtures/kong_spec.key",
      admin_gui_cert = "spec/fixtures/kong_spec.crt",
      admin_gui_cert_key = "spec/fixtures/kong_spec.key",
      status_cert = "spec/fixtures/kong_spec.crt",
      status_cert_key = "spec/fixtures/kong_spec.key",
    }))
    before_each(function()
      helpers.dir.makepath("ssl_tmp")
    end)
    after_each(function()
      pcall(helpers.dir.rmtree, "ssl_tmp")
    end)
    describe("proxy", function()
      it("auto-generates SSL certificate and key", function()
        assert(prefix_handler.gen_default_ssl_cert(conf))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          assert(exists(conf["ssl_cert_default" .. suffix]))
          assert(exists(conf["ssl_cert_key_default" .. suffix]))
        end
      end)
      it("does not re-generate if they already exist", function()
        assert(prefix_handler.gen_default_ssl_cert(conf))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          local cer = helpers.file.read(conf["ssl_cert_default" .. suffix])
          local key = helpers.file.read(conf["ssl_cert_key_default" .. suffix])
          assert(prefix_handler.gen_default_ssl_cert(conf))
          assert.equal(cer, helpers.file.read(conf["ssl_cert_default" .. suffix]))
          assert.equal(key, helpers.file.read(conf["ssl_cert_key_default" .. suffix]))
        end
      end)
    end)
    describe("admin", function()
      it("auto-generates SSL certificate and key", function()
        assert(prefix_handler.gen_default_ssl_cert(conf, "admin"))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          assert(exists(conf["admin_ssl_cert_default" .. suffix]))
          assert(exists(conf["admin_ssl_cert_key_default" .. suffix]))
        end
      end)
      it("does not re-generate if they already exist", function()
        assert(prefix_handler.gen_default_ssl_cert(conf, "admin"))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          local cer = helpers.file.read(conf["admin_ssl_cert_default" .. suffix])
          local key = helpers.file.read(conf["admin_ssl_cert_key_default" .. suffix])
          assert(prefix_handler.gen_default_ssl_cert(conf, "admin"))
          assert.equal(cer, helpers.file.read(conf["admin_ssl_cert_default" .. suffix]))
          assert.equal(key, helpers.file.read(conf["admin_ssl_cert_key_default" .. suffix]))
        end
      end)
    end)
    describe("admin_gui", function()
      it("auto-generates SSL certificate and key", function()
        assert(prefix_handler.gen_default_ssl_cert(conf, "admin_gui"))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          assert(exists(conf["admin_gui_ssl_cert_default" .. suffix]))
          assert(exists(conf["admin_gui_ssl_cert_key_default" .. suffix]))
        end
      end)
      it("does not re-generate if they already exist", function()
        assert(prefix_handler.gen_default_ssl_cert(conf, "admin_gui"))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          local cer = helpers.file.read(conf["admin_gui_ssl_cert_default" .. suffix])
          local key = helpers.file.read(conf["admin_gui_ssl_cert_key_default" .. suffix])
          assert(prefix_handler.gen_default_ssl_cert(conf, "admin_gui"))
          assert.equal(cer, helpers.file.read(conf["admin_gui_ssl_cert_default" .. suffix]))
          assert.equal(key, helpers.file.read(conf["admin_gui_ssl_cert_key_default" .. suffix]))
        end
      end)
    end)
    describe("status", function()
      it("auto-generates SSL certificate and key", function()
        assert(prefix_handler.gen_default_ssl_cert(conf, "status"))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          assert(exists(conf["status_ssl_cert_default" .. suffix]))
          assert(exists(conf["status_ssl_cert_key_default" .. suffix]))
        end
      end)
      it("does not re-generate if they already exist", function()
        assert(prefix_handler.gen_default_ssl_cert(conf, "status"))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          local cer = helpers.file.read(conf["status_ssl_cert_default" .. suffix])
          local key = helpers.file.read(conf["status_ssl_cert_key_default" .. suffix])
          assert(prefix_handler.gen_default_ssl_cert(conf, "status"))
          assert.equal(cer, helpers.file.read(conf["status_ssl_cert_default" .. suffix]))
          assert.equal(key, helpers.file.read(conf["status_ssl_cert_key_default" .. suffix]))
        end
      end)
    end)
  end)

  describe("compile_kong_conf()", function()
    it("compiles the Kong NGINX conf chunk", function()
      local kong_nginx_conf = prefix_handler.compile_kong_conf(helpers.test_conf)
      assert.matches("lua_package_path%s+'%./spec/fixtures/custom_plugins/%?%.lua;.+'", kong_nginx_conf)
      assert.matches("listen%s+0%.0%.0%.0:9000;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9001;", kong_nginx_conf)
      assert.matches("server_name%s+kong;", kong_nginx_conf)
      assert.matches("server_name%s+kong_admin;", kong_nginx_conf)
      assert.matches("include 'nginx-kong-inject.conf';", kong_nginx_conf, nil, true)
    end)
    it("compiles with custom conf", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        mem_cache_size = "128k",
        proxy_listen = "0.0.0.0:80",
        admin_listen = "127.0.0.1:8001",
        admin_gui_listen = "127.0.0.1:8002",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("lua_shared_dict%s+kong_db_cache%s+128k;", kong_nginx_conf)
      assert.matches("listen%s+0%.0%.0%.0:80;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8001;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8002;", kong_nginx_conf)
    end)
    it("enables HTTP/2", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000, 0.0.0.0:9443 http2 ssl",
        admin_listen = "127.0.0.1:9001, 127.0.0.1:9444 http2 ssl",
        admin_gui_listen = "127.0.0.1:9002, 127.0.0.1:9445 http2 ssl",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000;", kong_nginx_conf)
      assert.matches("listen%s+0%.0%.0%.0:9443 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9001;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9444 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9445 ssl;", kong_nginx_conf)

      assert.match_re(kong_nginx_conf, [[server_name kong;\n.+\n.+\n\n\s+http2 on;]])
      assert.match_re(kong_nginx_conf, [[server_name kong_admin;\n.+\n.+\n\n\s+http2 on;]])
      assert.match_re(kong_nginx_conf, [[server_name kong_gui;\n.+\n.+\n\n\s+http2 on;]])

      conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000, 0.0.0.0:9443 http2 ssl",
        admin_listen = "127.0.0.1:9001, 127.0.0.1:8444 ssl",
        admin_gui_listen = "127.0.0.1:9002, 127.0.0.1:8445 ssl",
      }))
      kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000;", kong_nginx_conf)
      assert.matches("listen%s+0%.0%.0%.0:9443 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9001;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8444 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8445 ssl;", kong_nginx_conf)

      assert.match_re(kong_nginx_conf, [[server_name kong;\n.+\n.+\n\n\s+http2 on;]])
      assert.not_match_re(kong_nginx_conf, [[server_name kong_admin;\n.+\n.+\n\n\s+http2 on;]])
      assert.not_match_re(kong_nginx_conf, [[server_name kong_gui;\n.+\n.+\n\n\s+http2 on;]])

      conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000, 0.0.0.0:9443 ssl",
        admin_listen = "127.0.0.1:9001, 127.0.0.1:8444 http2 ssl",
        admin_gui_listen = "127.0.0.1:9002, 127.0.0.1:8445 ssl",
      }))
      kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000;", kong_nginx_conf)
      assert.matches("listen%s+0%.0%.0%.0:9443 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9001;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8444 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8445 ssl;", kong_nginx_conf)

      assert.match_re(kong_nginx_conf, [[server_name kong_admin;\n.+\n.+\n\n\s+http2 on;]])
      assert.not_match_re(kong_nginx_conf, [[server_name kong;\n.+\n.+\n\n\s+http2 on;]])
      assert.not_match_re(kong_nginx_conf, [[server_name kong_gui;\n.+\n.+\n\n\s+http2 on;]])

      conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000, 0.0.0.0:9443 ssl",
        admin_listen = "127.0.0.1:9001, 127.0.0.1:8444 ssl",
        admin_gui_listen = "127.0.0.1:9002, 127.0.0.1:8445 http2 ssl",
      }))
      kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000;", kong_nginx_conf)
      assert.matches("listen%s+0%.0%.0%.0:9443 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:9001;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8444 ssl;", kong_nginx_conf)
      assert.matches("listen%s+127%.0%.0%.1:8445 ssl;", kong_nginx_conf)

      assert.match_re(kong_nginx_conf, [[server_name kong_gui;\n.+\n.+\n\n\s+http2 on;]])
      assert.not_match_re(kong_nginx_conf, [[server_name kong;\n.+\n.+\n\n\s+http2 on;]])
      assert.not_match_re(kong_nginx_conf, [[server_name kong_admin;\n.+\n.+\n\n\s+http2 on;]])
    end)
    it("enables proxy_protocol", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 proxy_protocol",
        nginx_proxy_real_ip_header = "proxy_protocol",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 proxy_protocol;", kong_nginx_conf)
      assert.matches("real_ip_header%s+proxy_protocol;", kong_nginx_conf)
    end)
    it("enables proxy_protocol", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 proxy_protocol",
        real_ip_header = "proxy_protocol",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 proxy_protocol;", kong_nginx_conf)
      assert.matches("real_ip_header%s+proxy_protocol;", kong_nginx_conf)
    end)
    it("enables deferred", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 deferred",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 deferred;", kong_nginx_conf)
    end)
    it("enables bind", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 bind",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 bind;", kong_nginx_conf)
    end)
    it("enables reuseport", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 reuseport",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 reuseport;", kong_nginx_conf)
    end)
    it("enables ipv6only", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "[::1]:9000 ipv6only=on",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+%[0000:0000:0000:0000:0000:0000:0000:0001%]:9000 ipv6only=on;", kong_nginx_conf)
    end)
    it("disables ipv6only", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 ipv6only=off",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 ipv6only=off;", kong_nginx_conf)
    end)
    it("enables so_keepalive", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 so_keepalive=on",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 so_keepalive=on;", kong_nginx_conf)
    end)
    it("disables so_keepalive", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 so_keepalive=off",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 so_keepalive=off;", kong_nginx_conf)
    end)
    it("configures so_keepalive", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "0.0.0.0:9000 so_keepalive=30m::10",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("listen%s+0%.0%.0%.0:9000 so_keepalive=30m::10;", kong_nginx_conf)
    end)
    it("disables SSL", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        proxy_listen = "127.0.0.1:8000",
        admin_listen = "127.0.0.1:8001",
        admin_gui_listen = "127.0.0.1:8002",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.not_matches("listen%s+%d+%.%d+%.%d+%.%d+:%d+ ssl;", kong_nginx_conf)
      assert.not_matches("ssl_certificate", kong_nginx_conf)
      assert.not_matches("ssl_certificate_key", kong_nginx_conf)
      assert.not_matches("ssl_certificate_by_lua_block", kong_nginx_conf)
      assert.not_matches("ssl_dhparam", kong_nginx_conf)
    end)

    it("renders RPC server", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        cluster_listen = "127.0.0.1:9005",
        cluster_rpc = "on",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("location = /v2/outlet {", kong_nginx_conf)
    end)

    it("does not renders RPC server when inert", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        role = "control_plane",
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        cluster_listen = "127.0.0.1:9005",
        cluster_rpc = "off",
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
      local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.not_matches("location = /v2/outlet {", kong_nginx_conf)
    end)

    describe("handles client_ssl", function()
      it("on", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          client_ssl = true,
          client_ssl_cert = "spec/fixtures/kong_spec.crt",
          client_ssl_cert_key = "spec/fixtures/kong_spec.key",
        }))
        local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("proxy_ssl_certificate%s+.*spec/fixtures/kong_spec%.crt", kong_nginx_conf)
        assert.matches("proxy_ssl_certificate_key%s+.*spec/fixtures/kong_spec%.key", kong_nginx_conf)
      end)
      it("off", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          client_ssl = false,
        }))
        local kong_nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.not_matches("proxy_ssl_certificate%s+.*spec/fixtures/kong_spec%.crt", kong_nginx_conf)
        assert.not_matches("proxy_ssl_certificate_key%s+.*spec/fixtures/kong_spec%.key", kong_nginx_conf)
      end)
    end)
    it("writes the client_max_body_size as defined", function()
      local conf = assert(conf_loader(nil, {
        nginx_http_client_max_body_size = "1m",
      }))
      local nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("client_max_body_size%s+1m", nginx_conf)
    end)
    it("writes the client_max_body_size as defined (admin)", function()
      local conf = assert(conf_loader(nil, {
        nginx_admin_client_max_body_size = "50m",
      }))
      local nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("client_max_body_size%s+50m", nginx_conf)
    end)
    it("writes the client_body_buffer_size directive as defined", function()
      local conf = assert(conf_loader(nil, {
        nginx_http_client_body_buffer_size = "128k",
      }))
      local nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("client_body_buffer_size%s+128k", nginx_conf)
    end)
    it("writes the client_body_buffer_size directive as defined (admin)", function()
      local conf = assert(conf_loader(nil, {
        nginx_admin_client_body_buffer_size = "50m",
      }))
      local nginx_conf = prefix_handler.compile_kong_conf(conf)
      assert.matches("client_body_buffer_size%s+50m", nginx_conf)
    end)

    describe("user directive", function()
      it("is included by default if the kong user/group exist", function()
        local conf = assert(conf_loader(helpers.test_conf_path))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        if kong_user_group_exists() == true then
          assert.matches("user kong kong;", nginx_conf)
        else
          assert.not_matches("user%s+[^;]*;", nginx_conf)
        end
      end)
      it("is not included when 'nobody'", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          nginx_main_user = "nobody"
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.not_matches("user%s+[^;]*;", nginx_conf)
      end)
      it("is not included when 'nobody nobody'", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          nginx_main_user = "nobody nobody"
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.not_matches("user%s+[^;]*;", nginx_conf)
      end)
      it("is included when otherwise", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          nginx_main_user = "www_data www_data"
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("user%s+www_data www_data;", nginx_conf)
      end)
    end)

    describe("user directive (alias)", function()
      it("is not included when 'nobody'", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          nginx_user = "nobody"
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.not_matches("user%s+[^;]*;", nginx_conf)
      end)
      it("is not included when 'nobody nobody'", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          nginx_user = "nobody nobody"
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.not_matches("user%s+[^;]*;", nginx_conf)
      end)
      it("is included when otherwise", function()
        local conf = assert(conf_loader(helpers.test_conf_path, {
          nginx_user = "www_data www_data"
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("user%s+www_data www_data;", nginx_conf)
      end)
    end)

    describe("ngx_http_realip_module settings", function()
      it("defaults", function()
        local conf = assert(conf_loader())
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_header%s+X%-Real%-IP;", nginx_conf)
        assert.matches("real_ip_recursive%s+off;", nginx_conf)
        assert.not_matches("set_real_ip_from", nginx_conf)
      end)

      it("real_ip_recursive on", function()
        local conf = assert(conf_loader(nil, {
          nginx_proxy_real_ip_recursive = true,
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_recursive%s+on;", nginx_conf)
      end)

      it("real_ip_recursive on", function()
        local conf = assert(conf_loader(nil, {
          real_ip_recursive = true,
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_recursive%s+on;", nginx_conf)
      end)

      it("real_ip_recursive off", function()
        local conf = assert(conf_loader(nil, {
          nginx_proxy_real_ip_recursive = false,
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_recursive%s+off;", nginx_conf)
      end)

      it("real_ip_recursive off", function()
        local conf = assert(conf_loader(nil, {
          real_ip_recursive = false,
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_recursive%s+off;", nginx_conf)
      end)

      it("set_real_ip_from", function()
        local conf = assert(conf_loader(nil, {
          trusted_ips = "192.168.1.0/24,192.168.2.1,2001:0db8::/32"
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("set_real_ip_from%s+192%.168%.1%.0/24", nginx_conf)
        assert.matches("set_real_ip_from%s+192%.168%.1%.0",    nginx_conf)
        assert.matches("set_real_ip_from%s+2001:0db8::/32", nginx_conf)
      end)
      it("set_real_ip_from (stream proxy)", function()
        local conf = assert(conf_loader(nil, {
          trusted_ips = "192.168.1.0/24,192.168.2.1,2001:0db8::/32",
          stream_listen = "127.0.0.1:8888",
          proxy_listen = "off",
          admin_listen = "off",
          admin_gui_listen = "off",
          status_listen = "off",
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("set_real_ip_from%s+192%.168%.1%.0/24", nginx_conf)
        assert.matches("set_real_ip_from%s+192%.168%.1%.0",    nginx_conf)
        assert.matches("set_real_ip_from%s+2001:0db8::/32", nginx_conf)
      end)
      it("proxy_protocol", function()
        local conf = assert(conf_loader(nil, {
          proxy_listen = "0.0.0.0:8000 proxy_protocol, 0.0.0.0:8443 ssl",
          nginx_proxy_real_ip_header = "proxy_protocol",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_header%s+proxy_protocol", nginx_conf)
        assert.matches("listen%s0%.0%.0%.0:8000 proxy_protocol;", nginx_conf)
        assert.matches("listen%s0%.0%.0%.0:8443 ssl;", nginx_conf)
      end)
      it("proxy_protocol", function()
        local conf = assert(conf_loader(nil, {
          proxy_listen = "0.0.0.0:8000 proxy_protocol, 0.0.0.0:8443 ssl",
          real_ip_header = "proxy_protocol",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("real_ip_header%s+proxy_protocol", nginx_conf)
        assert.matches("listen%s0%.0%.0%.0:8000 proxy_protocol;", nginx_conf)
        assert.matches("listen%s0%.0%.0%.0:8443 ssl;", nginx_conf)
      end)
    end)

    describe("injected NGINX directives", function()
      it("injects proxy_access_log directive", function()
        local conf, nginx_conf
        conf = assert(conf_loader(nil, {
          proxy_access_log = "/dev/stdout",
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("access_log%s/dev/stdout%skong_log_format;", nginx_conf)
        nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("access_log%slogs/access.log%sbasic;", nginx_conf)

        conf = assert(conf_loader(nil, {
          proxy_access_log = "off",
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("access_log%soff;", nginx_conf)
        nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("access_log%slogs/access.log%sbasic;", nginx_conf)

        conf = assert(conf_loader(nil, {
          proxy_access_log = "/dev/stdout apigw-json",
          nginx_http_log_format = 'apigw-json "$kong_request_id"',
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("access_log%s/dev/stdout%sapigw%-json;", nginx_conf)
        nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("access_log%slogs/access.log%sbasic;", nginx_conf)

        -- configure an undefined log format will error
        -- on kong start. This is expected
        conf = assert(conf_loader(nil, {
          proxy_access_log = "/dev/stdout not-exist",
          nginx_http_log_format = 'apigw-json "$kong_request_id"',
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("access_log%s/dev/stdout%snot%-exist;", nginx_conf)
        nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("access_log%slogs/access.log%sbasic;", nginx_conf)

        conf = assert(conf_loader(nil, {
          proxy_access_log = "/tmp/not-exist.log",
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("access_log%s/tmp/not%-exist.log%skong_log_format;", nginx_conf)
        nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("access_log%slogs/access.log%sbasic;", nginx_conf)

        conf = assert(conf_loader(nil, {
          prefix = "servroot_tmp",
          nginx_stream_log_format = "custom '$protocol $status'",
          proxy_stream_access_log = "/dev/stdout custom",
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        assert(prefix_handler.prepare_prefix(conf))
        nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("access_log%slogs/access.log%skong_log_format;", nginx_conf)
        nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("access_log%s/dev/stdout%scustom;", nginx_conf)
      end)

      it("injects proxy_error_log directive", function()
        local conf = assert(conf_loader(nil, {
          proxy_error_log = "/dev/stdout",
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("error_log%s/dev/stdout%snotice;", nginx_conf)
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("error_log%slogs/error.log%snotice;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          proxy_stream_error_log = "/dev/stdout",
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("error_log%slogs/error.log%snotice;", nginx_conf)
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("error_log%s/dev/stdout%snotice;", nginx_conf)
      end)

      it("injects nginx_main_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_main_pcre_jit = "on",
        }))

        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("pcre_jit%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_main_pcre_jit = true,
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("pcre_jit%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_main_pcre_jit = "off",
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("pcre_jit%s+off;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_main_pcre_jit = false,
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("pcre_jit%s+off;", nginx_conf)
      end)

      it("injects nginx_events_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_events_accept_mutex = "on",
        }))

        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("accept_mutex%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_events_accept_mutex = true,
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("accept_mutex%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_events_accept_mutex = "off",
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("accept_mutex%s+off;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_events_accept_mutex = false,
        }))
        local nginx_conf = prefix_handler.compile_nginx_conf(conf)
        assert.matches("accept_mutex%s+off;", nginx_conf)
      end)

      it("injects nginx_http_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_http_large_client_header_buffers = "8 24k",
          nginx_http_log_format = "custom_fmt '$connection $request_time'"
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("large_client_header_buffers%s+8 24k;", nginx_conf)
        assert.matches("log_format%s+custom_fmt '$connection $request_time';", nginx_conf)
      end)

      it("injects nginx_proxy_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_proxy_large_client_header_buffers = "16 24k",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("large_client_header_buffers%s+16 24k;", nginx_conf)
      end)

      it("injects nginx_location_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_location_proxy_ignore_headers = "X-Accel-Redirect",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("proxy_ignore_headers%sX%-Accel%-Redirect;", nginx_conf)
      end)

      it("injects nginx_admin_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_admin_large_client_header_buffers = "4 24k",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("large_client_header_buffers%s+4 24k;", nginx_conf)
      end)

      it("injects nginx_status_* directives", function()
        local conf = assert(conf_loader(nil, {
          status_listen = "0.0.0.0:8005",
          nginx_status_large_client_header_buffers = "4 24k",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("large_client_header_buffers%s+4 24k;", nginx_conf)
      end)

      it("injects nginx_upstream_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_upstream_keepalive = "120",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.matches("keepalive%s+120;", nginx_conf)
      end)

      it("injects nginx_stream_* directives", function()
        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "on",
        }))

        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          nginx_stream_tcp_nodelay = true,
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = "off",
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+off;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_stream_tcp_nodelay = false,
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+off;", nginx_conf)
      end)

      it("injects nginx_sproxy_* directives", function()
        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_sproxy_tcp_nodelay = "on",
        }))

        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_sproxy_tcp_nodelay = true,
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+on;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_sproxy_tcp_nodelay = "off",
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+off;", nginx_conf)

        local conf = assert(conf_loader(nil, {
          stream_listen = "0.0.0.0:9100",
          nginx_sproxy_tcp_nodelay = false,
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("tcp_nodelay%s+off;", nginx_conf)
      end)

      it("injects nginx_supstream_* directives", function()
        local conf = assert(conf_loader(nil, {
          nginx_supstream_keepalive = "120",
        }))
        local nginx_conf = prefix_handler.compile_kong_stream_conf(conf)
        assert.matches("keepalive%s120;", nginx_conf)
      end)

      it("does not inject directives if value is 'NONE'", function()
        local conf = assert(conf_loader(nil, {
          nginx_upstream_keepalive = "NONE",
        }))
        local nginx_conf = prefix_handler.compile_kong_conf(conf)
        assert.not_matches("keepalive%s+%d+;", nginx_conf)
      end)

      describe("default injected NGINX directives (proxy)", function()
        it("configures default body buffering directives", function()
          local conf = assert(conf_loader(nil, {
            admin_listen = "off",
            stream_listen = "off",
          }))
          local nginx_conf = prefix_handler.compile_kong_conf(conf)
          assert.matches("client_max_body_size%s+10m;", nginx_conf)
          assert.matches("client_body_buffer_size%s+8k;", nginx_conf)
         end)
      end)

      describe("default injected NGINX directives (admin)", function()
        it("configures default body buffering directives", function()
          local conf = assert(conf_loader(nil, {
            proxy_listen = "off",
            stream_listen = "off",
          }))
          local nginx_conf = prefix_handler.compile_kong_conf(conf)
          assert.matches("client_max_body_size%s+10m;", nginx_conf)
          assert.matches("client_body_buffer_size%s+8k;", nginx_conf)
        end)
      end)

    end)
  end)

  describe("compile_kong_gui_include_conf()", function ()
    describe("admin_gui_path", function ()
      it("set admin_gui_path to /", function ()
        local conf = assert(conf_loader(nil, {
          admin_gui_path = "/",
        }))
        local kong_gui_include_conf = prefix_handler.compile_kong_gui_include_conf(conf)
        assert.matches("location%s+~%*%s+%^%(%?<path>/%.%*%)%?%$", kong_gui_include_conf)   -- location ~* ^(?<path>/.**)?$
        assert.matches("sub_filter '/__km_base__/' '/';", kong_gui_include_conf)
      end)
      it("set admin_gui_path to /manager", function ()
        local conf = assert(conf_loader(nil, {
          admin_gui_path = "/manager",
        }))
        local kong_gui_include_conf = prefix_handler.compile_kong_gui_include_conf(conf)
        assert.matches("location%s+=%s+/manager/kconfig%.js", kong_gui_include_conf)                 -- location = /manager/kconfig.js
        assert.matches("location%s+~%*%s+%^/manager%(%?<path>/%.%*%)%?%$", kong_gui_include_conf)    -- location ~* ^/manager(?<path>/.**)?$
        assert.matches("sub_filter%s+'/__km_base__/'%s+'/manager/';", kong_gui_include_conf)  -- sub_filter '/__km_base__/' '/manager/';
      end)
    end)
  end)

  describe("compile_nginx_conf()", function()
    it("compiles a main NGINX conf", function()
      local nginx_conf = prefix_handler.compile_nginx_conf(helpers.test_conf)
      assert.matches("worker_processes%s+1;", nginx_conf)
      assert.matches("daemon%s+on;", nginx_conf)
      assert.matches("include 'nginx-inject.conf';", nginx_conf, nil, true)
    end)
    it("compiles with custom conf", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_main_daemon = "off"
      }))
      local nginx_conf = prefix_handler.compile_nginx_conf(conf)
      assert.matches("daemon%s+off;", nginx_conf)
    end)
    it("compiles with custom conf (alias)", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        nginx_daemon = "off"
      }))
      local nginx_conf = prefix_handler.compile_nginx_conf(conf)
      assert.matches("daemon%s+off;", nginx_conf)
    end)
    it("compiles without opinionated nginx optimizations", function()
      local conf = assert(conf_loader(nil, {
        nginx_main_worker_rlimit_nofile = "NONE",
        nginx_events_worker_connections = "NONE",
        nginx_events_multi_accept = "NONE",
      }))
      local nginx_conf = prefix_handler.compile_nginx_conf(conf)
      assert.not_matches("worker_rlimit_nofile%s+%d+;", nginx_conf)
      assert.not_matches("worker_connections%s+%d+;", nginx_conf)
      assert.not_matches("multi_accept%s+on;", nginx_conf)
    end)
    it("compiles with opinionated nginx optimizations", function()
      local conf = assert(conf_loader())
      local nginx_conf = prefix_handler.compile_nginx_conf(conf)
      assert.matches("worker_rlimit_nofile%s+%d+;", nginx_conf)
      assert.matches("worker_connections%s+%d+;", nginx_conf)
      assert.matches("multi_accept%s+on;", nginx_conf)
    end)
    it("compiles with correct auto values", function()
      local conf = assert(conf_loader(nil, {
        nginx_main_worker_rlimit_nofile = "auto",
        nginx_events_worker_connections = "auto",
      }))

      local ulimit = prefix_handler.get_ulimit()
      ulimit = math.min(ulimit, 16384)
      ulimit = math.max(ulimit, 1024)

      local nginx_conf = prefix_handler.compile_nginx_conf(conf)
      assert.matches("worker_rlimit_nofile%s+" .. ulimit .. ";", nginx_conf)
      assert.matches("worker_connections%s+" .. ulimit .. ";", nginx_conf)
    end)
    it("converts dns_resolver to string", function()
      local nginx_conf = prefix_handler.compile_nginx_conf({
        dns_resolver = { "1.2.3.4", "5.6.7.8" }
      }, [[
        "resolver ${{DNS_RESOLVER}} ipv6=off;"
      ]])
      assert.matches("resolver%s+1%.2%.3%.4 5%.6%.7%.8 ipv6=off;", nginx_conf)
    end)

    describe("#wasm subsystem", function()
      local temp_dir, cleanup
      local filter

      lazy_setup(function()
        temp_dir, cleanup = helpers.make_temp_dir()
        filter = temp_dir .. "/empty-filter.wasm"
        assert(helpers.file.write(filter, "testme"))
      end)

      lazy_teardown(function() cleanup() end)

      local _compile = function(cfg, config_compiler, debug)
        local ngx_conf = config_compiler(assert(conf_loader(nil, cfg)))
        if debug then
          print(ngx_conf)
        end
        return ngx_conf
      end
      local ngx_cfg = function(cfg, debug) return _compile(cfg, prefix_handler.compile_nginx_conf, debug) end
      local kong_ngx_cfg = function(cfg, debug) return _compile(cfg, prefix_handler.compile_kong_conf, debug) end

      local debug = false
      it("has no wasm{} block by default", function()
        assert.not_matches("wasm {", ngx_cfg({ wasm = nil }, debug))
      end)
      it("injects global wasm{} block", function()
        assert.matches("wasm {", ngx_cfg({ wasm = true }, debug))
      end)
      it("injects a filter", function()
        assert.matches(("module empty-filter %s;"):format(filter), ngx_cfg({ wasm = true, wasm_filters_path = temp_dir }, debug), nil, true)
      end)
      it("injects a main block directive", function()
        assert.matches("wasm {.+socket_connect_timeout 10s;.+}", ngx_cfg({ wasm = true, nginx_wasm_socket_connect_timeout="10s" }, debug))
      end)
      it("injects a shm_kv", function()
        assert.matches("wasm {.+shm_kv counters 10m;.+}", ngx_cfg({ wasm = true, nginx_wasm_shm_kv_counters="10m" }, debug))
      end)
      it("injects a general shm_kv", function()
        assert.matches("wasm {.+shm_kv %* 10m;.+}", ngx_cfg({ wasm = true, nginx_wasm_shm_kv = "10m" }, debug))
      end)
      it("injects multiple shm_kvs", function()
        assert.matches(
          "wasm {.+shm_kv cache 10m.+shm_kv counters 10m;.+shm_kv %* 5m;.+}",
          ngx_cfg({
            wasm = true,
            nginx_wasm_shm_kv_cache = "10m",
            nginx_wasm_shm_kv_counters = "10m",
            nginx_wasm_shm_kv = "5m",
          }, debug)
        )
      end)
      it("injects default configurations if wasm=on", function()
        assert.matches(
          ".+proxy_wasm_lua_resolver on;.+",
          kong_ngx_cfg({ wasm = true, }, debug)
        )
      end)
      it("does not inject default configurations if wasm=off", function()
        assert.not_matches(
          ".+proxy_wasm_lua_resolver.+",
          kong_ngx_cfg({ wasm = false, }, debug)
        )
      end)
      it("permits overriding proxy_wasm_lua_resolver to off", function()
        assert.matches(
          ".+proxy_wasm_lua_resolver off;.+",
          kong_ngx_cfg({ wasm = true,
                         nginx_http_proxy_wasm_lua_resolver = "off",
                       }, debug)
        )
      end)
      it("injects runtime-specific directives (wasmtime)", function()
        assert.matches(
          "wasm {.+wasmtime {.+flag flag1 on;.+flag flag2 1m;.+}.+",
          ngx_cfg({
            wasm = true,
            nginx_wasm_wasmtime_flag1=true,
            nginx_wasm_wasmtime_flag2="1m",
          }, debug)
        )
      end)
      it("injects runtime-specific directives (v8)", function()
        assert.matches(
          "wasm {.+v8 {.+flag flag1 on;.+flag flag2 1m;.+}.+",
          ngx_cfg({
            wasm = true,
            nginx_wasm_v8_flag1=true,
            nginx_wasm_v8_flag2="1m",
          }, debug)
        )
      end)
      it("injects runtime-specific directives (wasmer)", function()
        assert.matches(
          "wasm {.+wasmer {.+flag flag1 on;.+flag flag2 1m;.+}.+",
          ngx_cfg({
            wasm = true,
            nginx_wasm_wasmer_flag1=true,
            nginx_wasm_wasmer_flag2="1m",
          }, debug)
        )
      end)
      it("injects wasmtime cache_config", function()
        assert.matches(
          "wasm {.+wasmtime {.+cache_config .+%.wasmtime_config%.toml.*;",
          ngx_cfg({
            wasm = true,
          }, debug)
        )
      end)
      describe("injects inherited directives", function()
        it("only if one isn't explicitly set", function()
          assert.matches(
            ".+wasm_socket_connect_timeout 2s;.+",
            kong_ngx_cfg({
              wasm = true,
              nginx_http_wasm_socket_connect_timeout = "2s",
              nginx_http_lua_socket_connect_timeout = "1s",
            }, debug)
          )
        end)
        describe("lua_ssl_trusted_certificate", function()
          local cwd = currentdir()
          cwd = escape_special_chars(cwd) -- escape the possible special characters in the prefix
          it("with one cert", function()
            assert.matches(
              string.format("wasm {.+tls_trusted_certificate %s/spec/fixtures/kong_clustering_ca.crt;.+}", cwd),
              ngx_cfg({
                wasm = true,
                lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering_ca.crt",
              }, debug)
            )
          end)
          it("with more than one cert, picks first", function()
            assert.matches(
            string.format("wasm {.+tls_trusted_certificate %s/spec/fixtures/kong_clustering_ca.crt;.+}", cwd),
            ngx_cfg({
              wasm = true,
              lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering_ca.crt,spec/fixtures/kong_clustering.crt",
            }, debug)
            )
          end)
        end)
        it("lua_ssl_verify_depth", function()
          assert.matches(
            "wasm {.+tls_verify_cert on;.+}",
            ngx_cfg({
              wasm = true,
              lua_ssl_verify_depth = 2,
            }, debug)
          )
          assert.matches(
            "wasm {.+tls_verify_host on;.+}",
            ngx_cfg({
              wasm = true,
              lua_ssl_verify_depth = 2,
            }, debug)
          )
          assert.matches(
            "wasm {.+tls_no_verify_warn on;.+}",
            ngx_cfg({
              wasm = true,
              lua_ssl_verify_depth = 2,
            }, debug)
          )
        end)
        it("lua_socket_connect_timeout (http)", function()
          assert.matches(
            ".+wasm_socket_connect_timeout 1s;.+",
            kong_ngx_cfg({
              wasm = true,
              nginx_http_lua_socket_connect_timeout = "1s",
            }, debug)
          )
        end)
        it("lua_socket_connect_timeout (proxy)", function()
          assert.matches(
            "server {.+wasm_socket_connect_timeout 1s;.+}",
            kong_ngx_cfg({
              wasm = true,
              nginx_proxy_lua_socket_connect_timeout = "1s",
            }, debug)
          )
        end)
        it("lua_socket_read_timeout (http)", function()
          assert.matches(
            ".+wasm_socket_read_timeout 1s;.+",
            kong_ngx_cfg({
              wasm = true,
              nginx_http_lua_socket_read_timeout = "1s",
            }, debug)
          )
        end)
        it("lua_socket_read_timeout (proxy)", function()
          assert.matches(
            "server {.+wasm_socket_read_timeout 1s;.+}",
            kong_ngx_cfg({
              wasm = true,
              nginx_proxy_lua_socket_read_timeout = "1s",
            }, debug)
          )
        end)
        it("proxy_send_timeout (http)", function()
          assert.matches(
            ".+wasm_socket_send_timeout 1s;.+",
            kong_ngx_cfg({
              wasm = true,
              nginx_http_lua_socket_send_timeout = "1s",
            }, debug)
          )
        end)
        it("proxy_send_timeout (proxy)", function()
          assert.matches(
            "server {.+wasm_socket_send_timeout 1s;.+}",
            kong_ngx_cfg({
              wasm = true,
              nginx_proxy_lua_socket_send_timeout = "1s",
            }, debug)
          )
        end)
        it("proxy_buffer_size (http)", function()
          assert.matches(
            ".+wasm_socket_buffer_size 1m;.+",
            kong_ngx_cfg({
              wasm = true,
              nginx_http_lua_socket_buffer_size = "1m",
            }, debug)
          )
        end)
        it("proxy_buffer_size (proxy)", function()
          assert.matches(
            "server {.+wasm_socket_buffer_size 1m;.+}",
            kong_ngx_cfg({
              wasm = true,
              nginx_proxy_lua_socket_buffer_size = "1m",
            }, debug)
          )
        end)
      end)
    end)
  end)

  describe("prepare_prefix()", function()
    local tmp_config = conf_loader(helpers.test_conf_path, {
      prefix = "servroot_tmp"
    })

    before_each(function()
      pcall(helpers.dir.rmtree, tmp_config.prefix)
      helpers.dir.makepath(tmp_config.prefix)
    end)
    after_each(function()
      pcall(helpers.dir.rmtree, tmp_config.prefix)
    end)

    it("creates inexistent prefix", function()
      finally(function()
        pcall(helpers.dir.rmtree, "inexistent")
      end)

      local config = assert(conf_loader(helpers.test_conf_path, {
        prefix = "inexistent"
      }))
      assert(prefix_handler.prepare_prefix(config))
      assert.truthy(exists("inexistent"))
    end)
    it("ensures prefix is a directory", function()
      local tmp = os.tmpname()
      finally(function()
        os.remove(tmp)
      end)

      local config = assert(conf_loader(helpers.test_conf_path, {
        prefix = tmp
      }))
      local ok, err = prefix_handler.prepare_prefix(config)
      assert.equal(tmp .. " is not a directory", err)
      assert.is_nil(ok)
    end)
    it("creates pids folder", function()
      assert(prefix_handler.prepare_prefix(tmp_config))
      assert.truthy(exists(join(tmp_config.prefix, "pids")))
    end)
    it("creates NGINX conf and log files", function()
      assert(prefix_handler.prepare_prefix(tmp_config))
      assert.truthy(exists(tmp_config.kong_env))
      assert.truthy(exists(tmp_config.nginx_kong_conf))
      assert.truthy(exists(tmp_config.nginx_err_logs))
      assert.truthy(exists(tmp_config.nginx_acc_logs))
      assert.truthy(exists(tmp_config.admin_acc_logs))
    end)
    it("dumps Kong conf", function()
      assert(prefix_handler.prepare_prefix(tmp_config))
      local in_prefix_kong_conf = assert(conf_loader(tmp_config.kong_env))
      assert.same(tmp_config, in_prefix_kong_conf)
    end)
    it("dump Kong conf (custom conf)", function()
      local conf = assert(conf_loader(nil, {
        pg_database = "foobar",
        pg_schema   = "foo",
        prefix = tmp_config.prefix,
        nginx_main_worker_rlimit_nofile = 65536,
        nginx_events_worker_connections = 65536,
      }))
      assert.equal("foobar", conf.pg_database)
      assert.equal("foo", conf.pg_schema)
      assert(prefix_handler.prepare_prefix(conf))
      local in_prefix_kong_conf = assert(conf_loader(tmp_config.kong_env, {
        pg_database = "foobar",
        pg_schema = "foo",
        prefix = tmp_config.prefix,
      }))
      assert.same(conf, in_prefix_kong_conf)
    end)
    it("writes custom plugins in Kong conf", function()
      local conf = assert(conf_loader(nil, {
        plugins = { "foo", "bar" },
        prefix = tmp_config.prefix
      }))

      assert(prefix_handler.prepare_prefix(conf))

      local in_prefix_kong_conf = assert(conf_loader(tmp_config.kong_env))
      assert.True(in_prefix_kong_conf.loaded_plugins.foo)
      assert.True(in_prefix_kong_conf.loaded_plugins.bar)
    end)

    describe("vault references", function()
      it("are kept as references in .kong_env", function()
        finally(function()
          helpers.unsetenv("PG_DATABASE")
        end)

        helpers.setenv("PG_DATABASE", "pg-database")

        local conf = assert(conf_loader(nil, {
          prefix = tmp_config.prefix,
          pg_database = "{vault://env/pg-database}",
        }))

        assert.equal("pg-database", conf.pg_database)
        assert.equal("{vault://env/pg-database}", conf["$refs"].pg_database)

        assert(prefix_handler.prepare_prefix(conf))

        local contents = helpers.file.read(tmp_config.kong_env)

        assert.matches("pg_database = {vault://env/pg-database}", contents, nil, true)
        assert.not_matches("resolved-kong-database", contents, nil, true)
      end)
    end)

    describe("ssl", function()
      it("does not create SSL dir if disabled", function()
        local conf = conf_loader(nil, {
          prefix = tmp_config.prefix,
          proxy_listen = "127.0.0.1:8000",
          admin_listen = "127.0.0.1:8001",
          admin_gui_listen = "127.0.0.1:8002",
        })

        assert(prefix_handler.prepare_prefix(conf))
        assert.falsy(exists(join(conf.prefix, "ssl")))
      end)
      it("does not create SSL dir if using custom cert", function()
        local conf = conf_loader(nil, {
          prefix = tmp_config.prefix,
          proxy_listen = "127.0.0.1:8000 ssl",
          admin_listen = "127.0.0.1:8001 ssl",
          admin_gui_listen = "127.0.0.1:8002 ssl",
          status_listen = "127.0.0.1:8003 ssl",
          ssl_cipher_suite = "custom",
          ssl_cert = "spec/fixtures/kong_spec.crt",
          ssl_cert_key = "spec/fixtures/kong_spec.key",
          admin_ssl_cert = "spec/fixtures/kong_spec.crt",
          admin_ssl_cert_key = "spec/fixtures/kong_spec.key",
          admin_gui_ssl_cert = "spec/fixtures/kong_spec.crt",
          admin_gui_ssl_cert_key = "spec/fixtures/kong_spec.key",
          status_ssl_cert = "spec/fixtures/kong_spec.crt",
          status_ssl_cert_key = "spec/fixtures/kong_spec.key",
        })

        assert(prefix_handler.prepare_prefix(conf))
        assert.falsy(exists(join(conf.prefix, "ssl")))
      end)
      it("generates default SSL cert", function()
        local conf = conf_loader(nil, {
          prefix = tmp_config.prefix,
          proxy_listen  = "127.0.0.1:8000 ssl",
          admin_listen  = "127.0.0.1:8001 ssl",
          admin_gui_listen = "127.0.0.1:8002 ssl",
          status_listen = "127.0.0.1:8003 ssl",
        })

        assert(prefix_handler.prepare_prefix(conf))
        assert.truthy(exists(join(conf.prefix, "ssl")))
        for _, suffix in ipairs({ "", "_ecdsa" }) do
          assert.truthy(exists(conf["ssl_cert_default" .. suffix]))
          assert.truthy(exists(conf["ssl_cert_key_default" .. suffix]))
          assert.truthy(exists(conf["admin_ssl_cert_default" .. suffix]))
          assert.truthy(exists(conf["admin_ssl_cert_key_default" .. suffix]))
          assert.truthy(exists(conf["admin_gui_ssl_cert_default" .. suffix]))
          assert.truthy(exists(conf["admin_gui_ssl_cert_key_default" .. suffix]))
          assert.truthy(exists(conf["status_ssl_cert_default" .. suffix]))
          assert.truthy(exists(conf["status_ssl_cert_key_default" .. suffix]))
        end
      end)
      it("generates default SSL certs with correct permissions", function()
        local conf = conf_loader(nil, {
          prefix = tmp_config.prefix,
          proxy_listen  = "127.0.0.1:8000 ssl",
          admin_listen  = "127.0.0.1:8001 ssl",
          admin_gui_listen = "127.0.0.1:8002 ssl",
          status_listen = "127.0.0.1:8003 ssl",
        })

        assert(prefix_handler.prepare_prefix(conf))
        for _, prefix in ipairs({ "", "status_", "admin_", "admin_gui_" }) do
          for _, suffix in ipairs({ "", "_ecdsa" }) do
            local handle = io.popen("ls -l " .. conf[prefix .. "ssl_cert_default" .. suffix])
            local result = handle:read("*a")
            handle:close()
            assert.matches("%-rw%-r[-w]%-r%-%-", result, nil, false)

            handle = io.popen("ls -l " .. conf[prefix .. "ssl_cert_key_default" .. suffix])
            result = handle:read("*a")
            handle:close()
            assert.matches("-rw-------", result, nil, true)
          end
        end
      end)
      it("generates default SSL DH params", function()
        local conf = conf_loader(nil, {
          prefix = tmp_config.prefix,
          proxy_listen  = "127.0.0.1:8000 ssl",
          admin_listen  = "127.0.0.1:8001 ssl",
          admin_gui_listen = "127.0.0.1:8002 ssl",
          status_listen = "127.0.0.1:8003 ssl",
          stream_listen = "127.0.0.1:7000 ssl",
        })

        assert(prefix_handler.prepare_prefix(conf))
        assert.truthy(exists(join(conf.prefix, "ssl")))
        assert.truthy(exists(join(conf.prefix, "ssl", conf.ssl_dhparam .. ".pem")))
        assert.truthy(exists(join(conf.prefix, "ssl", conf.nginx_http_ssl_dhparam .. ".pem")))
        assert.truthy(exists(join(conf.prefix, "ssl", conf.nginx_stream_ssl_dhparam .. ".pem")))
      end)
      describe("accept raw content for configuration properties", function()
        it("writes files and re-configures valid paths", function()
          local cert = ssl_fixtures.cert
          local cacert = ssl_fixtures.cert_ca
          local key = ssl_fixtures.key
          local dhparam = ssl_fixtures.dhparam

          local params = {
            ssl_cipher_suite = "old",
            prefix = tmp_config.prefix,
          }
          local ssl_params = {
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

          local conf, err = conf_loader(nil, tablex.merge(params, ssl_params, true))
          assert(prefix_handler.prepare_prefix(conf))
          assert.is_nil(err)
          assert.is_table(conf)

          for name, input_content in pairs(ssl_params) do
            local paths = conf[name]
            if type(paths) == "table" then
              for i = 1, #paths do
                assert.truthy(exists(paths[i]))
                local configured_content = assert(helpers.file.read(paths[i]))
                assert.equals(input_content, configured_content)
              end
            end

            if type(paths) == "string" then
              assert.truthy(exists(paths))
              local configured_content = assert(helpers.file.read(paths))
              assert.equals(input_content, configured_content)
            end
          end
        end)
        it("sets lua_ssl_trusted_certificate to a combined file" ..
           "(multiple content entries)", function()
          local cacerts = string.format(
            "%s,%s",
            ssl_fixtures.cert_ca,
            ssl_fixtures.cert_ca
          )
          local conf = assert(conf_loader(nil, {
            lua_ssl_trusted_certificate = cacerts,
            prefix = tmp_config.prefix
          }))
          assert(prefix_handler.prepare_prefix(conf))
          assert.is_table(conf)
          local trusted_certificates = conf["lua_ssl_trusted_certificate"]
          assert.equal(2, #trusted_certificates)
          local combined = assert(
            helpers.file.read(conf["lua_ssl_trusted_certificate_combined"])
          )
          assert.equal(
            combined,
            string.format(
              "%s\n%s\n",
              ssl_fixtures.cert_ca,
              ssl_fixtures.cert_ca
            )
          )
        end)
      end)
    end)

    describe("custom template", function()
      local templ_fixture = "spec/fixtures/custom_nginx.template"

      lazy_setup(function()
        pcall(helpers.dir.rmtree, "/tmp/not-a-file")
        assert(helpers.dir.makepath("/tmp/not-a-file"))
      end)

      lazy_teardown(function()
        pcall(helpers.dir.rmtree, "/tmp/not-a-file")
      end)

      it("accepts a custom NGINX conf template", function()
        assert(prefix_handler.prepare_prefix(tmp_config, templ_fixture))
        assert.truthy(exists(tmp_config.nginx_conf))

        local contents = helpers.file.read(tmp_config.nginx_conf)
        assert.matches("# This is a custom nginx configuration template for Kong specs", contents, nil, true)
        assert.matches("daemon%s+on;", contents)
        local contents_kong_conf = helpers.file.read(tmp_config.nginx_kong_conf)
        assert.matches("listen%s+0%.0%.0%.0:9000;", contents_kong_conf)
      end)
      it("errors on non-existing file", function()
        local ok, err = prefix_handler.prepare_prefix(tmp_config, "spec/fixtures/inexistent.template")
        assert.is_nil(ok)
        assert.equal("no such file: spec/fixtures/inexistent.template", err)
      end)
      it("errors on file read failures", function()
        local ok, err = prefix_handler.prepare_prefix(tmp_config, "/tmp/not-a-file")
        assert.is_nil(ok)
        assert.matches("failed reading custom nginx template file: /tmp/not-a-file", err, nil, true)
      end)
      it("reports Penlight templating errors", function()
        local u = helpers.unindent
        local tmp = os.tmpname()

        helpers.file.write(tmp, u[[
          > if t.hello then

          > end
        ]])

        finally(function()
          helpers.file.delete(tmp)
        end)

        local ok, err = prefix_handler.prepare_prefix(helpers.test_conf, tmp)
        assert.is_nil(ok)
        assert.matches("failed to compile nginx config template: .* " ..
                       "attempt to index global 't' %(a nil value%)", err)
      end)
    end)

    describe("nginx_* injected directives aliases", function()
      -- Aliases maintained for pre-established Nginx directives specified
      -- as Kong config properties

      describe("'upstream_keepalive'", function()

        describe("1.2 Nginx template", function()
          local templ_fixture = "spec/fixtures/1.2_custom_nginx.template"

          it("compiles", function()
            assert(prefix_handler.prepare_prefix(tmp_config, templ_fixture))
            assert.truthy(exists(tmp_config.nginx_conf))

            local contents = helpers.file.read(tmp_config.nginx_conf)
            assert.matches("# This is the Kong 1.2 default template", contents,
                           nil, true)
            assert.matches("daemon on;", contents, nil, true)
            assert.matches("listen 0.0.0.0:9000;", contents, nil, true)
            assert.not_matches("keepalive%s+%d+", contents)
          end)
        end)
      end)
    end)
  end)

  describe("compile_nginx_main_inject_conf()", function()
    it("compiles a main NGINX inject conf", function()
      local main_inject_conf = prefix_handler.compile_nginx_main_inject_conf(helpers.test_conf)
      assert.not_matches("lmdb_environment_path", main_inject_conf, nil, true)
      assert.not_matches("lmdb_map_size", main_inject_conf, nil, true)
      assert.not_matches("lmdb_validation_tag", main_inject_conf, nil, true)
    end)

    it("compiles a main NGINX inject conf #database=off", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        database = "off",
      }))
      local main_inject_conf = prefix_handler.compile_nginx_main_inject_conf(conf)
      assert.matches("lmdb_environment_path%s+dbless.lmdb;", main_inject_conf)
      assert.matches("lmdb_map_size%s+2048m;", main_inject_conf)

      local kong_meta = require "kong.meta"
      local major = kong_meta._VERSION_TABLE.major
      local minor = kong_meta._VERSION_TABLE.minor
      assert.matches("lmdb_validation_tag%s+" .. major .. "%." .. minor .. ";", main_inject_conf)
    end)
  end)

  describe("compile_nginx_http_inject_conf()", function()
    it("compiles a http NGINX inject conf", function()
      local http_inject_conf = prefix_handler.compile_nginx_http_inject_conf(helpers.test_conf)
      assert.matches("lua_ssl_verify_depth%s+1;", http_inject_conf)
      assert.matches("lua_ssl_trusted_certificate.+;", http_inject_conf)
      assert.matches("lua_ssl_protocols%s+TLSv1.2 TLSv1.3;", http_inject_conf)
    end)
    it("sets lua_ssl_verify_depth", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        lua_ssl_verify_depth = "2"
      }))
      local http_inject_conf = prefix_handler.compile_nginx_http_inject_conf(conf)
      assert.matches("lua_ssl_verify_depth%s+2;", http_inject_conf)
    end)
    it("includes default lua_ssl_verify_depth", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      local http_inject_conf = prefix_handler.compile_nginx_http_inject_conf(conf)
      assert.matches("lua_ssl_verify_depth%s+1;", http_inject_conf)
    end)
    it("includes default lua_ssl_trusted_certificate", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      local http_inject_conf = prefix_handler.compile_nginx_http_inject_conf(conf)
      assert.matches("lua_ssl_trusted_certificate.+;", http_inject_conf)
    end)
    it("sets lua_ssl_trusted_certificate to a combined file (single entry)", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        lua_ssl_trusted_certificate = "spec/fixtures/kong_spec.crt",
      }))
      local http_inject_conf = prefix_handler.compile_nginx_http_inject_conf(conf)
      assert.matches("lua_ssl_trusted_certificate%s+.*ca_combined", http_inject_conf)
    end)
    it("sets lua_ssl_trusted_certificate to a combined file (multiple entries)", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering_ca.crt,spec/fixtures/kong_clustering.crt",
      }))
      local http_inject_conf = prefix_handler.compile_nginx_http_inject_conf(conf)
      assert.matches("lua_ssl_trusted_certificate%s+.*ca_combined", http_inject_conf)
    end)
  end)

  describe("compile_nginx_stream_inject_conf()", function()
    it("compiles a stream NGINX inject conf", function()
      local stream_inject_conf = prefix_handler.compile_nginx_stream_inject_conf(helpers.test_conf)
      assert.matches("lua_ssl_verify_depth%s+1;", stream_inject_conf)
      assert.matches("lua_ssl_trusted_certificate.+;", stream_inject_conf)
      assert.matches("lua_ssl_protocols%s+TLSv1.2 TLSv1.3;", stream_inject_conf)
    end)
    it("sets lua_ssl_verify_depth", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        lua_ssl_verify_depth = "2"
      }))
      local stream_inject_conf = prefix_handler.compile_nginx_stream_inject_conf(conf)
      assert.matches("lua_ssl_verify_depth%s+2;", stream_inject_conf)
    end)
    it("includes default lua_ssl_verify_depth", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      local stream_inject_conf = prefix_handler.compile_nginx_stream_inject_conf(conf)
      assert.matches("lua_ssl_verify_depth%s+1;", stream_inject_conf)
    end)
    it("includes default lua_ssl_trusted_certificate", function()
      local conf = assert(conf_loader(helpers.test_conf_path))
      local stream_inject_conf = prefix_handler.compile_nginx_stream_inject_conf(conf)
      assert.matches("lua_ssl_trusted_certificate.+;", stream_inject_conf)
    end)
    it("sets lua_ssl_trusted_certificate to a combined file (single entry)", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        lua_ssl_trusted_certificate = "spec/fixtures/kong_spec.crt",
      }))
      local stream_inject_conf = prefix_handler.compile_nginx_stream_inject_conf(conf)
      assert.matches("lua_ssl_trusted_certificate%s+.*ca_combined", stream_inject_conf)
    end)
    it("sets lua_ssl_trusted_certificate to a combined file (multiple entries)", function()
      local conf = assert(conf_loader(helpers.test_conf_path, {
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering_ca.crt,spec/fixtures/kong_clustering.crt",
      }))
      local stream_inject_conf = prefix_handler.compile_nginx_stream_inject_conf(conf)
      assert.matches("lua_ssl_trusted_certificate%s+.*ca_combined", stream_inject_conf)
    end)

    it("include nginx-kong-stream-inject.conf in nginx-kong-stream.conf", function()
      local nginx_conf = prefix_handler.compile_kong_stream_conf(helpers.test_conf)
      assert.matches("include 'nginx-kong-stream-inject.conf';", nginx_conf, nil, true)
    end)
  end)
end)
