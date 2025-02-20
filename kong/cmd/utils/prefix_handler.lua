local default_nginx_template = require "kong.templates.nginx"
local kong_nginx_template = require "kong.templates.nginx_kong"
local kong_nginx_gui_include_template = require "kong.templates.nginx_kong_gui_include"
local kong_nginx_stream_template = require "kong.templates.nginx_kong_stream"
local nginx_main_inject_template = require "kong.templates.nginx_inject"
local nginx_http_inject_template = require "kong.templates.nginx_kong_inject"
local nginx_stream_inject_template = require "kong.templates.nginx_kong_stream_inject"
local wasmtime_cache_template = require "kong.templates.wasmtime_cache_config"
local system_constants = require "lua_system_constants"
local process_secrets = require "kong.cmd.utils.process_secrets"
local openssl_bignum = require "resty.openssl.bn"
local openssl_rand = require "resty.openssl.rand"
local openssl_pkey = require "resty.openssl.pkey"
local x509 = require "resty.openssl.x509"
local x509_extension = require "resty.openssl.x509.extension"
local x509_name = require "resty.openssl.x509.name"
local pl_template = require "pl.template"
local pl_tablex = require "pl.tablex"
local pl_utils = require "pl.utils"
local pl_file = require "pl.file"
local pl_path = require "pl.path"
local pl_dir = require "pl.dir"
local log = require "kong.cmd.utils.log"
local ffi = require "ffi"
local bit = require "bit"
local nginx_signals = require "kong.cmd.utils.nginx_signals"
local admin_gui_utils = require "kong.admin_gui.utils"


local strip = require("kong.tools.string").strip
local split = require("kong.tools.string").split
local shallow_copy = require("kong.tools.table").shallow_copy


local getmetatable = getmetatable
local makepath = pl_dir.makepath
local tonumber = tonumber
local tostring = tostring
local assert = assert
local string = string
local exists = pl_path.exists
local ipairs = ipairs
local pairs = pairs
local table = table
local type = type
local math = math
local join = pl_path.join
local io = io
local os = os
local fmt = string.format


local function pre_create_private_file(file)
  local flags = bit.bor(system_constants.O_RDONLY(),
                        system_constants.O_CREAT())

  local mode = ffi.new("int", bit.bor(system_constants.S_IRUSR(),
                                      system_constants.S_IWUSR()))

  local fd = ffi.C.open(file, flags, mode)
  if fd == -1 then
    log.warn("unable to pre-create '%s' file: %s", file,
             ffi.string(ffi.C.strerror(ffi.errno())))

  else
    ffi.C.close(fd)
  end
end


local function gen_default_dhparams(kong_config)
  for _, name in ipairs({ kong_config.nginx_http_ssl_dhparam, kong_config.nginx_stream_ssl_dhparam }) do
    local pem
    if name then
      pem = openssl_pkey.paramgen({
        type = "DH",
        group = name,
      })
    end

    if pem then
      local ssl_path = join(kong_config.prefix, "ssl")
      if not exists(ssl_path) then
        local ok, err = makepath(ssl_path)
        if not ok then
          return nil, err
        end
      end

      local param_file = join(ssl_path, name .. ".pem")
      if not exists(param_file) then
        log.verbose("generating %s DH parameters", name)
        local fd = assert(io.open(param_file, "w+b"))
        assert(fd:write(pem))
        fd:close()
      end
    end
  end

  return true
end


local function gen_default_ssl_cert(kong_config, target)
  -- create SSL folder
  local ok, err = makepath(join(kong_config.prefix, "ssl"))
  if not ok then
    return nil, err
  end

  for _, suffix in ipairs({ "", "_ecdsa" }) do
    local ssl_cert, ssl_cert_key
    if target == "admin" then
      ssl_cert = kong_config["admin_ssl_cert_default" .. suffix]
      ssl_cert_key = kong_config["admin_ssl_cert_key_default" .. suffix]

    elseif target == "admin_gui" then
      ssl_cert = kong_config["admin_gui_ssl_cert_default" .. suffix]
      ssl_cert_key = kong_config["admin_gui_ssl_cert_key_default" .. suffix]

    elseif target == "status" then
      ssl_cert = kong_config["status_ssl_cert_default" .. suffix]
      ssl_cert_key = kong_config["status_ssl_cert_key_default" .. suffix]

    else
      ssl_cert = kong_config["ssl_cert_default" .. suffix]
      ssl_cert_key = kong_config["ssl_cert_key_default" .. suffix]
    end

    if not exists(ssl_cert) and not exists(ssl_cert_key) then
      log.verbose("generating %s SSL certificate (%s) and key (%s) for listener",
                  target or "proxy", ssl_cert, ssl_cert_key)

      local key
      if suffix == "_ecdsa" then
        key = openssl_pkey.new { type = "EC", curve = "prime256v1" }
      else
        key = openssl_pkey.new { bits = 2048 }
      end

      local crt = x509.new()
      assert(crt:set_pubkey(key))
      assert(crt:set_version(3))
      assert(crt:set_serial_number(openssl_bignum.from_binary(openssl_rand.bytes(16))))

      -- last for 20 years
      local now = os.time()
      assert(crt:set_not_before(now))
      assert(crt:set_not_after(now + 86400 * 20 * 365))

      local name = assert(x509_name.new()
        :add("C", "US")
        :add("ST", "California")
        :add("L", "San Francisco")
        :add("O", "Kong")
        :add("OU", "IT Department")
        :add("CN", "localhost"))

      assert(crt:set_subject_name(name))
      assert(crt:set_issuer_name(name))

      -- Not a CA
      assert(crt:set_basic_constraints { CA = false })
      assert(crt:set_basic_constraints_critical(true))

      -- Only allowed to be used for TLS connections (client or server)
      assert(crt:add_extension(x509_extension.new("extendedKeyUsage",
                                                  "serverAuth,clientAuth")))

      -- RFC-3280 4.2.1.2
      assert(crt:add_extension(x509_extension.new("subjectKeyIdentifier", "hash", {
        subject = crt
      })))

      -- All done; sign
      assert(crt:sign(key))

      do -- write key out
        pre_create_private_file(ssl_cert_key)
        local fd = assert(io.open(ssl_cert_key, "w+b"))
        local pem = assert(key:to_PEM("private"))
        assert(fd:write(pem))
        fd:close()
      end

      do -- write cert out
        local fd = assert(io.open(ssl_cert, "w+b"))
        local pem = assert(crt:to_PEM())
        assert(fd:write(pem))
        fd:close()
      end

    else
      log.verbose("%s SSL certificate found at %s", target or "default", ssl_cert)
    end
  end

  return true
end


local function write_ssl_cert(path, ssl_cert)
  local fd = assert(io.open(path, "w+b"))
  assert(fd:write(ssl_cert))
  fd:close()
end


local function write_ssl_cert_key(path, ssl_cert_key)
  pre_create_private_file(path)
  local fd = assert(io.open(path, "w+b"))
  assert(fd:write(ssl_cert_key))
  fd:close()
end


local function gen_trusted_certs_combined_file(combined_filepath, paths)
  log.verbose("generating trusted certs combined file in %s",
              combined_filepath)

  local fd = assert(io.open(combined_filepath, "w"))

  for _, path in ipairs(paths) do
    fd:write(assert(pl_file.read(path)))
    fd:write("\n")
  end

  io.close(fd)
end


local function get_ulimit()
  local ok, _, stdout, stderr = pl_utils.executeex "ulimit -n"
  if not ok then
    return nil, stderr
  end
  local sanitized_limit = strip(stdout)
  if sanitized_limit:lower():match("unlimited") then
    return 65536
  else
    return tonumber(sanitized_limit)
  end
end

local function quote(s)
  return fmt("%q", s)
end

local function compile_conf(kong_config, conf_template, template_env_inject)
  -- computed config properties for templating
  local compile_env = {
    _escape = ">",
    pairs = pairs,
    ipairs = ipairs,
    tostring = tostring,
    os = {
      getenv = os.getenv,
    },
    quote = quote,
  }

  local kong_proxy_access_log = kong_config.proxy_access_log
  if kong_proxy_access_log ~= "off" then
    compile_env.proxy_access_log_enabled = true
  end
  if kong_proxy_access_log then
    -- example: proxy_access_log = 'logs/some-file.log apigw_json'
    local _, custom_format_name = string.match(kong_proxy_access_log, "^(%S+)%s(%S+)")
    if custom_format_name then
      compile_env.custom_proxy_access_log = true
    end
  end

  compile_env = pl_tablex.merge(compile_env, template_env_inject or {}, true)

  do
    local worker_rlimit_nofile_auto
    if kong_config.nginx_main_directives then
      for _, directive in ipairs(kong_config.nginx_main_directives) do
        if directive.name == "worker_rlimit_nofile" then
          if directive.value == "auto" then
            worker_rlimit_nofile_auto = directive
          end
          break
        end
      end
    end

    local worker_connections_auto
    if kong_config.nginx_events_directives then
      for _, directive in ipairs(kong_config.nginx_events_directives) do
        if directive.name == "worker_connections" then
          if directive.value == "auto" then
            worker_connections_auto = directive
          end
          break
        end
      end
    end

    if worker_connections_auto or worker_rlimit_nofile_auto then
      local value, err = get_ulimit()
      if not value then
        return nil, err
      end

      value = math.min(value, 16384)
      value = math.max(value, 1024)

      if worker_rlimit_nofile_auto then
        worker_rlimit_nofile_auto.value = value
      end

      if worker_connections_auto then
        worker_connections_auto.value = value
      end
    end
  end

  compile_env = pl_tablex.merge(compile_env, kong_config, true) -- union
  compile_env.dns_resolver = table.concat(compile_env.dns_resolver or {}, " ")
  compile_env.lua_package_path = (compile_env.lua_package_path or "") .. ";" ..
                                 (os.getenv("LUA_PATH") or "")
  compile_env.lua_package_cpath = (compile_env.lua_package_cpath or "") .. ";" ..
                                  (os.getenv("LUA_CPATH") or "")

  local post_template, err = pl_template.substitute(conf_template, compile_env)
  if not post_template then
    return nil, "failed to compile nginx config template: " .. err
  end

  -- the second value(the count) should not be returned
  return (string.gsub(post_template, "(${%b{}})", function(w)
    local name = w:sub(4, -3)
    return compile_env[name:lower()] or ""
  end))
end

local function write_env_file(path, data)
  os.remove(path)

  local flags = bit.bor(system_constants.O_CREAT(),
                        system_constants.O_WRONLY())
  local mode = ffi.new("int", bit.bor(system_constants.S_IRUSR(),
                                      system_constants.S_IWUSR(),
                                      system_constants.S_IRGRP()))

  local fd = ffi.C.open(path, flags, mode)
  if fd < 0 then
    local errno = ffi.errno()
    return nil, "unable to open env path " .. path .. " (" ..
                ffi.string(ffi.C.strerror(errno)) .. ")"
  end

  local ok = ffi.C.close(fd)
  if ok ~= 0 then
    local errno = ffi.errno()
    return nil, "failed to close fd (" ..
                ffi.string(ffi.C.strerror(errno)) .. ")"
  end

  local file, err = io.open(path, "w+")
  if not file then
    return nil, "unable to open env path " .. path .. " (" .. err .. ")"
  end

  local ok, err = file:write(data)

  file:close()

  if not ok then
    return nil, "unable to write env path " .. path .. " (" .. err .. ")"
  end

  return true
end

local function write_process_secrets_file(kong_conf, data)
  local path = kong_conf.kong_process_secrets

  local function write_single_secret_file(path, data)
    os.remove(path)

    local flags = bit.bor(system_constants.O_RDONLY(),
                          system_constants.O_CREAT())

    local mode = ffi.new("int", bit.bor(system_constants.S_IRUSR(),
                                        system_constants.S_IWUSR()))

    local fd = ffi.C.open(path, flags, mode)
    if fd < 0 then
      local errno = ffi.errno()
      return nil, "unable to open process secrets path " .. path .. " (" ..
                  ffi.string(ffi.C.strerror(errno)) .. ")"
    end

    local ok = ffi.C.close(fd)
    if ok ~= 0 then
      local errno = ffi.errno()
      return nil, "failed to close fd (" ..
                  ffi.string(ffi.C.strerror(errno)) .. ")"
    end

    local file, err = io.open(path, "w+b")
    if not file then
      return nil, "unable to open process secrets path " .. path .. " (" .. err .. ")"
    end

    local ok, err = file:write(data)

    file:close()

    if not ok then
      return nil, "unable to write process secrets path " .. path .. " (" .. err .. ")"
    end

    return true

  end

  if kong_conf.role == "control_plane" or #kong_conf.proxy_listeners > 0
    or #kong_conf.admin_listeners > 0 or #kong_conf.status_listeners > 0 then
    local ok, err = write_single_secret_file(path .. "_http", data)
    if not ok then
      return nil, err
    end
  end

  if #kong_conf.stream_listeners > 0 then
    local ok, err = write_single_secret_file(path .. "_stream", data)
    if not ok then
      return nil, err
    end
  end

  return true
end

local function compile_kong_conf(kong_config, template_env_inject)
  return compile_conf(kong_config, kong_nginx_template, template_env_inject)
end

local function compile_kong_gui_include_conf(kong_config)
  -- Build connect-src in the CSP header
  -- Other parts are defined inside nginx_kong_gui_include.lua
  local csp_connect_src
  if kong_config.admin_gui_csp_header then
    -- TODO: Try bundling buttons.js with frontend assets instead of loading it from a URL
    csp_connect_src = { "'self'", "https://api.github.com/repos/kong/kong" }
    if kong_config.admin_gui_api_url then
      table.insert(csp_connect_src, kong_config.admin_gui_api_url)
    else
      -- If admin_gui_api_url is missing, we will add dynamic sources that echoes the requested host
      -- with ports defined in admin_listeners corresponding to the scheme
      local api_listen = admin_gui_utils.select_listener(kong_config.admin_listeners, { ssl = false })
      local api_port = api_listen and api_listen.port
      if api_port then
        table.insert(csp_connect_src, "http://$host:" .. api_port)
      end

      local api_ssl_listen = admin_gui_utils.select_listener(kong_config.admin_listeners, { ssl = true })
      local api_ssl_port = api_ssl_listen and api_ssl_listen.port
      if api_ssl_port then
        table.insert(csp_connect_src, "https://$host:" .. api_ssl_port)
      end
    end
    csp_connect_src = table.concat(csp_connect_src, " ")
  end

  return compile_conf(kong_config, kong_nginx_gui_include_template, {
    csp_connect_src = csp_connect_src,
  })
end

local function compile_kong_stream_conf(kong_config, template_env_inject)
  return compile_conf(kong_config, kong_nginx_stream_template, template_env_inject)
end

local function compile_nginx_conf(kong_config, template)
  template = template or default_nginx_template
  return compile_conf(kong_config, template)
end

local function compile_wasmtime_cache_conf(kong_config)
  return compile_conf(kong_config, wasmtime_cache_template)
end

local function prepare_prefixed_interface_dir(usr_path, interface_dir, kong_config)
  local usr_interface_path = usr_path .. "/" .. interface_dir
  local interface_path = kong_config.prefix .. "/" .. interface_dir

  -- if the interface directory is not exist in custom prefix directory
  -- try symlinking to the default prefix location
  -- ensure user can access the interface appliation
  if not pl_path.exists(interface_path)
     and pl_path.exists(usr_interface_path) then

    local ln_cmd = "ln -s " .. usr_interface_path .. " " .. interface_path
    local ok, _, _, err_t = pl_utils.executeex(ln_cmd)

    if not ok then
      log.warn(err_t)
    end
  end
end

local function compile_nginx_main_inject_conf(kong_config)
  return compile_conf(kong_config, nginx_main_inject_template)
end

local function compile_nginx_http_inject_conf(kong_config)
  return compile_conf(kong_config, nginx_http_inject_template)
end

local function compile_nginx_stream_inject_conf(kong_config)
  return compile_conf(kong_config, nginx_stream_inject_template)
end

local function compile_kong_test_inject_conf(kong_config, template, template_env)
  return compile_conf(kong_config, template, template_env)
end

local function prepare_prefix(kong_config, nginx_custom_template_path, skip_write, write_process_secrets, nginx_conf_flags)
  log.verbose("preparing nginx prefix directory at %s", kong_config.prefix)

  if not exists(kong_config.prefix) then
    log("prefix directory %s not found, trying to create it", kong_config.prefix)
    local ok, err = makepath(kong_config.prefix)
    if not ok then
      return nil, err
    end
  elseif not pl_path.isdir(kong_config.prefix) then
    return nil, kong_config.prefix .. " is not a directory"
  end

  if not exists(kong_config.socket_path) then
    local ok, err = makepath(kong_config.socket_path)
    if not ok then
      return nil, err
    end

    local ok, _, _, stderr = pl_utils.executeex("chmod 755 " .. kong_config.socket_path)
    if not ok then
      return nil, "can not set correct permissions for socket path: " .. kong_config.socket_path
                  .. " (" .. stderr .. ")"
    end
  end

  -- create directories in prefix
  for _, dir in ipairs {"logs", "pids"} do
    local ok, err = makepath(join(kong_config.prefix, dir))
    if not ok then
      return nil, err
    end
  end

  -- create log files in case they don't already exist
  if not exists(kong_config.nginx_err_logs) then
    local ok, err = pl_file.write(kong_config.nginx_err_logs, "")
    if not ok then
      return nil, err
    end
  end
  if not exists(kong_config.nginx_acc_logs) then
    local ok, err = pl_file.write(kong_config.nginx_acc_logs, "")
    if not ok then
      return nil, err
    end
  end
  if not exists(kong_config.admin_acc_logs) then
    local ok, err = pl_file.write(kong_config.admin_acc_logs, "")
    if not ok then
      return nil, err
    end
  end

  -- generate default SSL certs if needed
  do
    for _, target in ipairs({ "proxy", "admin", "admin_gui", "status" }) do
      local ssl_enabled = kong_config[target .. "_ssl_enabled"]
      if not ssl_enabled and target == "proxy" then
        ssl_enabled = kong_config.stream_proxy_ssl_enabled
      end

      local prefix
      if target == "proxy" then
        prefix = ""
      else
        prefix = target .. "_"
      end

      local ssl_cert = kong_config[prefix .. "ssl_cert"]
      local ssl_cert_key = kong_config[prefix .. "ssl_cert_key"]

      if ssl_enabled and #ssl_cert == 0 and #ssl_cert_key == 0 then
        log.verbose("SSL enabled on %s, no custom certificate set: using default certificates", target)
        local ok, err = gen_default_ssl_cert(kong_config, target)
        if not ok then
          return nil, err
        end

        ssl_cert[1]     = kong_config[prefix .. "ssl_cert_default"]
        ssl_cert_key[1] = kong_config[prefix .. "ssl_cert_key_default"]
        ssl_cert[2]     = kong_config[prefix .. "ssl_cert_default_ecdsa"]
        ssl_cert_key[2] = kong_config[prefix .. "ssl_cert_key_default_ecdsa"]
      end
    end
  end

  -- create certs files and assign paths when they are passed as content
  do

    local function set_dhparam_path(path)
      if kong_config["nginx_http_ssl_dhparam"] then
        kong_config["nginx_http_ssl_dhparam"] = path
      end

      if kong_config["nginx_stream_ssl_dhparam"] then
        kong_config["nginx_stream_ssl_dhparam"] = path
      end

      for _, directive in ipairs(kong_config["nginx_http_directives"]) do
        if directive.name == "ssl_dhparam" and directive.value then
          directive.value = path
        end
      end

      for _, directive in ipairs(kong_config["nginx_stream_directives"]) do
        if directive.name == "ssl_dhparam" and directive.value then
          directive.value = path
        end
      end
    end

    local function is_predefined_dhgroup(group)
      if type(group) ~= "string" then
        return false
      end

      return not not openssl_pkey.paramgen({
        type = "DH",
        group = group,
      })
    end

    -- ensure the property value is a "content" (not a path),
    -- write the content to a file and set the path in the configuration
    local function write_content_set_path(
      contents,
      format,
      write_func,
      ssl_path,
      target,
      config_key
    )
      if type(contents) == "string" then
        if not exists(contents) then
          if not exists(ssl_path) then
            makepath(ssl_path)
          end
          local path = join(ssl_path, target .. format)
          write_func(path, contents)
          kong_config[config_key] = path
          if target == "ssl-dhparam" then
            set_dhparam_path(path)
          end
        end

      elseif type(contents) == "table" then
        for i, content in ipairs(contents) do
          if not exists(content) then
            if not exists(ssl_path) then
              makepath(ssl_path)
            end
            local path = join(ssl_path, target .. "-" .. i .. format)
            write_func(path, content)
            contents[i] = path
          end
        end
      end
    end

    local ssl_path = join(kong_config.prefix, "ssl")
    for _, target in ipairs({
      "proxy",
      "admin",
      "admin_gui",
      "status",
      "client",
      "cluster",
      "lua-ssl-trusted",
      "cluster-ca"
    }) do
      local cert_name
      local key_name
      local ssl_cert
      local ssl_key

      if target == "proxy" then
        cert_name = "ssl_cert"
        key_name = "ssl_cert_key"
      elseif target == "cluster" then
        cert_name = target .. "_cert"
        key_name = target .. "_cert_key"
      elseif target == "cluster-ca" then
        cert_name = "cluster_ca_cert"
      elseif target == "lua-ssl-trusted" then
        cert_name = "lua_ssl_trusted_certificate"
      else
        cert_name = target .. "_ssl_cert"
        key_name = target .. "_ssl_cert_key"
      end

      ssl_cert = cert_name and kong_config[cert_name]
      ssl_key = key_name and kong_config[key_name]

      if ssl_cert and #ssl_cert > 0 then
        write_content_set_path(ssl_cert, ".crt", write_ssl_cert, ssl_path,
                               target, cert_name)
      end

      if ssl_key and #ssl_key > 0 then
        write_content_set_path(ssl_key, ".key", write_ssl_cert_key, ssl_path,
                               target, key_name)
      end
    end

    local dhparam_value = kong_config["ssl_dhparam"]
    if dhparam_value and not is_predefined_dhgroup(dhparam_value) then
      write_content_set_path(dhparam_value, ".pem", write_ssl_cert, ssl_path,
                             "ssl-dhparam", "ssl_dhparam")
    end
  end


  if kong_config.lua_ssl_trusted_certificate_combined then
    gen_trusted_certs_combined_file(
      kong_config.lua_ssl_trusted_certificate_combined,
      kong_config.lua_ssl_trusted_certificate
    )
  end

  -- check ulimit
  local ulimit, err = get_ulimit()
  if not ulimit then return nil, err
  elseif ulimit < 4096 then
    log.warn([[ulimit is currently set to "%d". For better performance set it]] ..
             [[ to at least "4096" using "ulimit -n"]], ulimit)
  end

  if skip_write then
    return true
  end

  if kong_config.wasm then
    if kong_config.wasmtime_cache_directory then
      local ok, err = makepath(kong_config.wasmtime_cache_directory)
      if not ok then
        return nil, err
      end
    end

    if kong_config.wasmtime_cache_config_file  then
      local wasmtime_conf, err = compile_wasmtime_cache_conf(kong_config)
      if not wasmtime_conf then
        return nil, err
      end
      pl_file.write(kong_config.wasmtime_cache_config_file, wasmtime_conf)
    end
  end

  -- compile Nginx configurations
  local nginx_template
  if nginx_custom_template_path then
    if not exists(nginx_custom_template_path) then
      return nil, "no such file: " .. nginx_custom_template_path
    end
    local read_err
    nginx_template, read_err = pl_file.read(nginx_custom_template_path)
    if not nginx_template then
      read_err = tostring(read_err or "unknown error")
      return nil, "failed reading custom nginx template file: " .. read_err
    end
  end

  if kong_config.proxy_ssl_enabled or
     kong_config.stream_proxy_ssl_enabled or
     kong_config.admin_ssl_enabled or
     kong_config.admin_gui_ssl_enabled or
     kong_config.status_ssl_enabled
  then
    gen_default_dhparams(kong_config)
  end

  local template_env = {}
  nginx_conf_flags = nginx_conf_flags and split(nginx_conf_flags, ",") or {}
  for _, flag in ipairs(nginx_conf_flags) do
    template_env[flag] = true
  end

  local nginx_conf, err = compile_nginx_conf(kong_config, nginx_template)
  if not nginx_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_conf, nginx_conf)

  -- write Kong's GUI include NGINX conf
  local nginx_kong_gui_include_conf, err = compile_kong_gui_include_conf(kong_config)
  if not nginx_kong_gui_include_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_kong_gui_include_conf, nginx_kong_gui_include_conf)

  -- write Kong's HTTP NGINX conf
  local nginx_kong_conf, err = compile_kong_conf(kong_config, template_env)
  if not nginx_kong_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_kong_conf, nginx_kong_conf)

  -- write Kong's stream NGINX conf
  local nginx_kong_stream_conf, err = compile_kong_stream_conf(kong_config, template_env)
  if not nginx_kong_stream_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_kong_stream_conf, nginx_kong_stream_conf)

  -- write NGINX MAIN inject conf
  local nginx_main_inject_conf, err = compile_nginx_main_inject_conf(kong_config)
  if not nginx_main_inject_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_inject_conf, nginx_main_inject_conf)

  -- write NGINX HTTP inject conf
  local nginx_http_inject_conf, err = compile_nginx_http_inject_conf(kong_config)
  if not nginx_http_inject_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_kong_inject_conf, nginx_http_inject_conf)

  -- write NGINX STREAM inject conf
  local nginx_stream_inject_conf, err = compile_nginx_stream_inject_conf(kong_config)
  if not nginx_stream_inject_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_kong_stream_inject_conf, nginx_stream_inject_conf)

  -- write Kong's test injected configuration files (*.test.conf)
  -- these are included in the Kong's HTTP NGINX conf by the test template
  local test_template_inj_path = "spec/fixtures/template_inject/"
  if pl_path.isdir(test_template_inj_path) then
    for _, file in ipairs(pl_dir.getfiles(test_template_inj_path, "*.lua")) do
      local t_path = pl_path.splitext(file)
      local t_module = string.gsub(t_path, "/", ".")
      local nginx_kong_test_inject_conf, err = compile_kong_test_inject_conf(
        kong_config,
        require(t_module),
        template_env
      )

      if not nginx_kong_test_inject_conf then
        return nil, err
      end

      local t_name = pl_path.basename(t_path)
      local output_path = kong_config.prefix .. "/" .. t_name .. ".test.conf"
      pl_file.write(output_path, nginx_kong_test_inject_conf)
    end
  end

  -- testing written NGINX conf
  local ok, err = nginx_signals.check_conf(kong_config)
  if not ok then
    return nil, err
  end

  -- write kong.conf in prefix (for workers and CLI)
  local buf = {
    "# *************************",
    "# * DO NOT EDIT THIS FILE *",
    "# *************************",
    "# This configuration file is auto-generated. If you want to modify",
    "# the Kong configuration please edit/create the original `kong.conf`",
    "# file. Any modifications made here will be lost.",
    "# Start Kong with `--vv` to show where it is looking for that file.",
    "",
  }

  local function quote_hash(s)
    return s:gsub("#", "\\#")
  end

  local refs = kong_config["$refs"]
  local has_refs = refs and type(refs) == "table"
  local secrets = process_secrets.extract(kong_config)

  for k, v in pairs(kong_config) do
    -- do not output secrets in .kong_env
    if has_refs and refs[k] then
      local ref = refs[k]
      if type(ref) == "table" then
        if type(v) ~= "table" then
          v = { v }
        else
          v = shallow_copy(v)
        end

        for i, r in pairs(ref) do
          v[i] = r
        end

      elseif ref then
        v = ref
      end
    end

    if type(v) == "table" then
      if (getmetatable(v) or {}).__tostring then
        -- the 'tostring' meta-method knows how to serialize
        v = tostring(v)
      else
        v = table.concat(v, ",")
      end
    end
    if v ~= "" then
      buf[#buf+1] = k .. " = " .. quote_hash(tostring(v))
    end
  end

  local env = table.concat(buf, "\n") .. "\n"
  local ok, err = write_env_file(kong_config.kong_env, env)
  if not ok then
    return nil, err
  end

  if kong_config.admin_gui_listeners then
    prepare_prefixed_interface_dir("/usr/local/kong", "gui", kong_config)
  end

  if secrets and write_process_secrets then
    secrets, err = process_secrets.serialize(secrets, kong_config.kong_env)
    if not secrets then
      return nil, err
    end

    ok, err = write_process_secrets_file(kong_config, secrets)
    if not ok then
      return nil, err
    end

  elseif not write_process_secrets then
    os.remove(kong_config.kong_process_secrets)
  end

  return true
end

return {
  get_ulimit = get_ulimit,
  prepare_prefix = prepare_prefix,
  prepare_prefixed_interface_dir = prepare_prefixed_interface_dir,
  compile_conf = compile_conf,
  compile_kong_conf = compile_kong_conf,
  compile_kong_gui_include_conf = compile_kong_gui_include_conf,
  compile_kong_stream_conf = compile_kong_stream_conf,
  compile_nginx_conf = compile_nginx_conf,
  compile_nginx_main_inject_conf = compile_nginx_main_inject_conf,
  compile_nginx_http_inject_conf = compile_nginx_http_inject_conf,
  compile_nginx_stream_inject_conf = compile_nginx_stream_inject_conf,
  gen_default_ssl_cert = gen_default_ssl_cert,
  write_env_file = write_env_file,
}
