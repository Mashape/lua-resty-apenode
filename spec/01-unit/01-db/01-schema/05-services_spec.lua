local Schema = require "kong.db.schema"
local services = require "kong.db.schema.entities.services"
local certificates = require "kong.db.schema.entities.certificates"

assert(Schema.new(certificates))
local Services = assert(Schema.new(services))

local function setup_global_env()
  _G.kong = _G.kong or {}
  _G.kong.log = _G.kong.log or {
    debug = function(msg)
      ngx.log(ngx.DEBUG, msg)
    end,
    error = function(msg)
      ngx.log(ngx.ERR, msg)
    end,
    warn = function (msg)
      ngx.log(ngx.WARN, msg)
    end
  }
end

describe("services", function()
  setup_global_env()
  local a_valid_uuid = "cbb297c0-a956-486d-ad1d-f9b42df9465a"
  local uuid_pattern = "^" .. ("%x"):rep(8) .. "%-" .. ("%x"):rep(4) .. "%-"
                           .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(4) .. "%-"
                           .. ("%x"):rep(12) .. "$"


  it("validates a valid service", function()
    local service = {
      id              = a_valid_uuid,
      name            = "my_service",
      protocol        = "http",
      host            = "example.com",
      port            = 80,
      path            = "/foo",
      connect_timeout = 50,
      write_timeout   = 100,
      read_timeout    = 100,
    }
    service = Services:process_auto_fields(service, "insert")
    assert.truthy(Services:validate(service))
  end)

  it("null protocol produces error", function()
    local service = {
      protocol = ngx.null,
    }
    service = Services:process_auto_fields(service, "insert")
    local ok, errs = Services:validate(service)
    assert.falsy(ok)
    assert.truthy(errs["protocol"])
  end)

  it("null protocol produces error on update", function()
    local service = {
      protocol = ngx.null,
    }
    service = Services:process_auto_fields(service, "update")
    local ok, errs = Services:validate_update(service)
    assert.falsy(ok)
    assert.truthy(errs["protocol"])
  end)

  it("invalid protocol produces error", function()
    local service = {
      protocol = "ftp"
    }
    service = Services:process_auto_fields(service, "insert")
    local ok, errs = Services:validate(service)
    assert.falsy(ok)
    assert.truthy(errs["protocol"])
  end)

  it("missing host produces error", function()
    local service = {
    }
    service = Services:process_auto_fields(service, "insert")
    local ok, errs = Services:validate(service)
    assert.falsy(ok)
    assert.truthy(errs["host"])
  end)

  it("invalid retries produces error", function()
    local service = Services:process_auto_fields({ retries = -1 }, "insert")
    local ok, errs = Services:validate(service)
    assert.falsy(ok)
    assert.truthy(errs["retries"])
    service = Services:process_auto_fields({ retries = 10000000000 }, "insert")
    local ok, errs = Services:validate(service)
    assert.falsy(ok)
    assert.truthy(errs["retries"])
  end)

  it("produces defaults", function()
    local service = {
      host = "www.example.com",
    }
    service = Services:process_auto_fields(service, "insert")
    local ok, err = Services:validate(service)
    assert.truthy(ok)
    assert.is_nil(err)
    assert.match(uuid_pattern, service.id)
    assert.same(service.name, ngx.null)
    assert.same(service.protocol, "http")
    assert.same(service.host, "www.example.com")
    assert.same(service.port, 80)
    assert.same(service.path, ngx.null)
    assert.same(service.retries, 5)
    assert.same(service.connect_timeout, 60000)
    assert.same(service.write_timeout, 60000)
    assert.same(service.read_timeout, 60000)
  end)

  describe("timeout attributes", function()
    -- refusals
    it("should not be zero", function()
      local service = {
        host            = "example.com",
        port            = 80,
        protocol        = "https",
        connect_timeout = 0,
        read_timeout    = 0,
        write_timeout   = 0,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("value should be between 1 and 2147483646",
                   err.connect_timeout)
      assert.equal("value should be between 1 and 2147483646",
                   err.read_timeout)
      assert.equal("value should be between 1 and 2147483646",
                   err.write_timeout)
    end)

    -- acceptance
    it("should be greater than zero", function()
      local service = {
        host            = "example.com",
        port            = 80,
        protocol        = "https",
        connect_timeout = 1,
        read_timeout    = 10,
        write_timeout   = 100,
        enabled         = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)
  end)

  describe("path attribute", function()
    -- refusals
    it("must be a string", function()
      local service = {
        path = false,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("expected a string", err.path)
    end)

    it("must be a non-empty string", function()
      local service = {
        path = "",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("length must be at least 1", err.path)
    end)

    it("must start with /", function()
      local service = {
        path = "foo",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("should start with: /", err.path)
    end)

    it("must not have empty segments (/foo//bar)", function()
      local invalid_paths = {
        "/foo//bar",
        "/foo/bar//",
        "//foo/bar",
      }

      for i = 1, #invalid_paths do
        local service = {
          path = invalid_paths[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.equal("must not have empty segments", err.path)
      end
    end)

    it("rejects regular expressions & other non-rfc 3986 chars", function()
      local invalid_paths = {
        [[/users/|foo/profile]],
        [[/users/(this|foo/profile)]],
      }

      for i = 1, #invalid_paths do
        local service = {
          path = invalid_paths[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.equal("invalid path: '" ..
                     invalid_paths[i] ..
                     "' (characters outside of the reserved list of RFC 3986 found)",
                     err.path)
      end
    end)

    it("accepts \"sub-delims\" characters from RFC 3986 (#6125)", function()
      local service = {
        host = "example.com",
        port = 80,
        protocol = "http",
        path = "/hello/path$with$!&'()*+,;=stuff",
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("rejects badly percent-encoded values", function()
      local invalid_paths = {
        "/some%2words",
        "/some%0Xwords",
        "/some%2Gwords",
        "/some%20words%",
        "/some%20words%a",
        "/some%20words%ax",
      }

      local errstr = { "%2w", "%0X", "%2G", "%", "%a", "%ax" }

      for i = 1, #invalid_paths do
        local service = {
          path = invalid_paths[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.matches("invalid url-encoded value: '" .. errstr[i] .. "'",
                       err.path, nil, true)
      end
    end)

    -- acceptance
    it("accepts an apex '/'", function()
      local service = {
        protocol = "http",
        host = "example.com",
        path = "/",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("accepts unreserved characters from RFC 3986", function()
      local service = {
        protocol = "http",
        host = "example.com",
        path = "/abcd~user~2",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("accepts properly percent-encoded values", function()
      local valid_paths = { "/abcd%aa%10%ff%AA%FF" }

      for i = 1, #valid_paths do
        local service = {
          protocol = "http",
          host = "example.com",
          path = valid_paths[i],
          port = 80,
          enabled = true,
        }

        local ok, err = Services:validate(service)
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)

    it("accepts trailing slash", function()
      local service = {
        protocol = "http",
        host = "example.com",
        path = "/ovo/",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  describe("host attribute", function()
    -- refusals
    it("must be a string", function()
      local service = {
        host = false,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("expected a string", err.host)
    end)

    it("must be a non-empty string", function()
      local service = {
        host = "",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("length must be at least 1", err.host)
    end)

    it("rejects invalid hostnames", function()
      local invalid_hosts = {
        "/example",
        ".example",
        "example:",
        "mock;bin",
        "example.com/org",
        "example-.org",
        "example.org-",
        "hello..example.com",
        "hello-.example.com",
        "*example.com",
        "www.example*",
        "mock*bin.com",
      }

      for i = 1, #invalid_hosts do
        local service = {
          host = invalid_hosts[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.equal("invalid value: " .. invalid_hosts[i], err.host)
      end
    end)

    it("rejects values with a valid port", function()
      local service = {
        host = "example.com:80",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("must not have a port", err.host)
    end)

    it("rejects values with an invalid port", function()
      local service = {
        host = "example.com:1000000",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("must not have a port", err.host)
    end)

    -- acceptance
    it("accepts valid hosts", function()
      local valid_hosts = {
        "hello.com",
        "hello.fr",
        "test.hello.com",
        "1991.io",
        "hello.COM",
        "HELLO.com",
        "123helloWORLD.com",
        "example.123",
        "example-api.com",
        "hello.abcd",
        "example_api.com",
        "localhost",
        "example.test.",
        -- below:
        -- punycode examples from RFC3492;
        -- https://tools.ietf.org/html/rfc3492#page-14
        -- specifically the japanese ones as they mix
        -- ascii with escaped characters
        "3B-ww4c5e180e575a65lsy2b",
        "-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n",
        "Hello-Another-Way--fc4qua05auwb3674vfr0b",
        "2-u9tlzr9756bt3uc0v",
        "MajiKoi5-783gue6qz075azm5e",
        "de-jg4avhby1noc0d",
        "d9juau41awczczp",
      }

      for i = 1, #valid_hosts do
        local service = {
          protocol = "http",
          host = valid_hosts[i],
          port = 80,
          enabled = true,
        }

        local ok, err = Services:validate(service)
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)
  end)

  describe("name attribute", function()
    -- refusals
    it("must be a string", function()
      local service = {
        name = false,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("expected a string", err.name)
    end)

    it("must be a non-empty string", function()
      local service = {
        name = "",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("length must be at least 1", err.name)
    end)

    it("rejects invalid names", function()
      local invalid_names = {
        "examp:le",
        "examp;le",
        "examp/le",
        "examp le",
        -- see tests for utils.validate_utf8 for more invalid values
        string.char(105, 213, 205, 149),
      }

      for i = 1, #invalid_names do
        local service = {
          url = "http://example.com",
          name = invalid_names[i]
        }
        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.matches("invalid", err.name)
      end
    end)

    -- acceptance
    it("accepts valid names", function()
      local valid_names = {
        "example",
        "EXAMPLE",
        "exa.mp.le",
        "3x4mp13",
        "3x4-mp-13",
        "3x4_mp_13",
        "~3x4~mp~13",
        "~3..x4~.M-p~1__3_",
        "孔",
        "Конг",
        "🦍",
      }

      for i = 1, #valid_names do
        local service = {
          protocol = "http",
          host = "example.com",
          port = 80,
          name = valid_names[i],
          enabled = true,
        }

        local ok, err = Services:validate(service)
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)
  end)

  describe("stream context", function()
    it("'protocol' accepts 'tcp'", function()
      local service = {
        protocol = "tcp",
        host = "x.y",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("'protocol' accepts 'tls'", function()
      local service = {
        protocol = "tls",
        host = "x.y",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("'protocol' accepts 'udp'", function()
      local service = {
        protocol = "udp",
        host = "x.y",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("'protocol' accepts 'grpc'", function()
      local service = {
        protocol = "grpc",
        host = "x.y",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("'protocol' accepts 'grpcs'", function()
      local service = {
        protocol = "grpcs",
        host = "x.y",
        port = 80,
        enabled = true,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("'protocol' accepts 'grpcs' with tls_verify and ca_certificates", function()
      local service = {
        protocol = "grpcs",
        host = "x.y",
        port = 80,
        enabled = true,
        tls_verify = true,
        ca_certificates = { "41f484e9-7888-495d-9283-1d4ce2168172" },
      }
      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("if 'protocol = tcp/tls/udp/grpc/grpcs', then 'path' is empty", function()
      for _, v in ipairs({ "tcp", "tls", "udp", "grpc", "grpcs" }) do
        local service = {
          protocol = v,
          host = "x.y",
          port = 80,
          path = "/",
          enabled = true,
        }

        local ok, errs = Services:validate(service)
        assert.falsy(ok)
        assert.equal("value must be null", errs.path)
      end
    end)
  end)
end)
