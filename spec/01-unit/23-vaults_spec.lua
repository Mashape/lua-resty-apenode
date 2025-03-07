local helpers = require "spec.helpers" -- initializes 'kong' global for vaults
local conf_loader = require "kong.conf_loader"


local is_ref_test_map = {
  ["{vault://x/x}"] = true,
  ["{vault://x/xx}"] = true,
  ["{vault://xx/xx-x}"] = true,
  ["{vault://xxx/xx-x}"] = true,
  ["{vault://;/xx-x}"] = true,
  ["vault:/xx-x}"] = false,
  ["{vault:/xx-x"] = false,
  ["vault:/xx-x"] = false,
  ["{valut:/xx-x}"] = false,
  ["{vault:/xx-x}"] = false,
}


local get_test_map = {
  ["{vault://env/test_secrets}"] = {
    k = "TEST_SECRETS",
    v = "test_value"
  },
  ["{vault://env/test}"] = {
    k = "TEST",
    v = ""
  },
}


describe("Vault PDK", function()
  local vaults
  local is_reference
  local parse_reference
  local dereference
  local try
  local update

  before_each(function()
    local conf = assert(conf_loader(nil, {
      vaults = "bundled",
      plugins = "bundled",
    }))

    local kong_global = require "kong.global"
    _G.kong = kong_global.new()
    kong_global.init_pdk(kong, conf)

    is_reference = _G.kong.vault.is_reference
    parse_reference = _G.kong.vault.parse_reference
    dereference = _G.kong.vault.get
    try = _G.kong.vault.try
    update = _G.kong.vault.update

    vaults = {}

    for vault in pairs(conf.loaded_vaults) do
      local init = require("kong.vaults." .. vault)
      table.insert(vaults, init)
    end
  end)

  it("test init", function()
    local res, err = parse_reference("{vault://env/test}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test", res.resource)
    assert.is_nil(res.key)
    assert.is_nil(res.version)
  end)

  it("test init path with only slashes does not work", function()
    local res, err = parse_reference("{vault://env}")
    assert.is_nil(res)
    assert.equal("reference url is missing path [{vault://env}]", err)

    local res, err = parse_reference("{vault://env/}")
    assert.is_nil(res)
    assert.equal("reference url has empty path [{vault://env/}]", err)

    local res, err = parse_reference("{vault://env/////}")
    assert.is_nil(res)
    assert.equal("reference url has invalid path [{vault://env/////}]", err)
  end)

  it("test init nested/path", function()
    local res, err = parse_reference("{vault://env/test-secret/test-key}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test-secret", res.resource)
    assert.is_equal("test-key", res.key)
    assert.is_nil(res.version)
  end)

  it("test init nested/path is url decoded", function()
    local res, err = parse_reference("{vault://env/test%3Asecret/test%3Akey}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test:secret", res.resource)
    assert.is_equal("test:key", res.key)
    assert.is_nil(res.version)
  end)

  it("test init nested/path ignores consecutive slashes", function()
    local res, err = parse_reference("{vault://env//////test-secret//////test-key}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test-secret", res.resource)
    assert.is_equal("test-key", res.key)
    assert.is_nil(res.version)
  end)

  it("test init nested/path ending with slash", function()
    local res, err = parse_reference("{vault://env/test-secret/test-key/}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test-secret/test-key", res.resource)
    assert.is_nil(res.key)
    assert.is_nil(res.version)
  end)

  it("test init nested/path ending with slash ignores consecutive slashes", function()
    local res, err = parse_reference("{vault://env//////test-secret//////test-key//////}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test-secret/test-key", res.resource)
    assert.is_nil(res.key)
    assert.is_nil(res.version)
  end)

  it("test init opts", function()
    local res, err = parse_reference("{vault://env/test?opt1=val1}")
    assert.is_nil(err)
    assert.is_same({ opt1 = "val1" }, res.config)
    assert.is_equal("env", res.name)
    assert.is_equal(res.resource, "test")
    assert.is_nil(res.key)
    assert.is_nil(res.version)
  end)

  it("test init multiple opts", function()
    local res, err = parse_reference("{vault://env/test?opt1=val1&opt2=val2}")
    assert.is_nil(err)
    assert.is_same({ opt1 = "val1", opt2 = "val2" }, res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test", res.resource)
    assert.is_nil(res.key)
    assert.is_nil(res.version)
  end)

  it("test init version", function()
    local res, err = parse_reference("{vault://env/test#1}")
    assert.is_nil(err)
    assert.is_nil(res.config)
    assert.is_equal("env", res.name)
    assert.is_equal("test", res.resource)
    assert.is_nil(res.key)
    assert.equal(1, res.version)
  end)

  it("ensure that every vault has a VERSION and a `get` field", function()
    for _, vault in ipairs(vaults) do
      assert.not_nil(vault.get)
      assert.not_nil(vault.VERSION)
    end
  end)

  for ref, exp in pairs(is_ref_test_map) do
    it("test is_reference [" .. ref .. "] -> " .. tostring(exp), function()
      assert.is_equal(exp, is_reference(ref))
    end)
  end

  for ref, cfg in pairs(get_test_map) do
    it("test get [" .. ref .. "] -> " .. tostring(cfg.k), function()
      finally(function()
        helpers.unsetenv(cfg.k)
      end)
      helpers.setenv(cfg.k, cfg.v)
      local ret, err = dereference(ref)
      assert.is_nil(err)
      assert.is_equal(cfg.v, ret)
    end)
  end

  describe("try function", function()
    local called

    before_each(function()
      called = 0
    end)

    it("calls the callback only once when successful", function()
      local ok, err = try(function()
        called = called + 1
        return true
      end)

      assert.is_nil(err)
      assert.True(ok)
      assert.equal(1, called)
    end)

    it("calls the callback only once when no options", function()
      local ok, err = try(function()
        called = called + 1
        return nil, "failed"
      end)

      assert.equal("failed", err)
      assert.is_nil(ok)
      assert.equal(1, called)
    end)

    it("calls the callback only once when no refs", function()
      local ok, err = try(function()
        called = called + 1
        return nil, "failed"
      end, {})

      assert.equal("failed", err)
      assert.is_nil(ok)
      assert.equal(1, called)
    end)

    it("calls the callback only once when refs is empty", function()
      local ok, err = try(function()
        called = called + 1
        return nil, "failed"
      end, {
        ["$refs"] = {}
      })

      assert.equal("failed", err)
      assert.is_nil(ok)
      assert.equal(1, called)
    end)

    it("calls the callback twice when current credentials doesn't work", function()
      finally(function()
        helpers.unsetenv("CREDENTIALS")
      end)

      helpers.setenv("CREDENTIALS", '{"username":"jane","password":"qwerty"}')

      local options = {
        username = "john",
        password = "secret",
        ["$refs"] = {
          username = "{vault://env/credentials/username}",
          password = "{vault://env/credentials/password}",
        },
      }

      local callback = function(options)
        called = called + 1
        if options.username ~= "jane" or options.password ~= "qwerty" then
          return nil, "failed"
        end
        return true
      end

      local ok, err = try(callback, options)

      assert.is_nil(err)
      assert.True(ok)
      assert.equal(2, called)

      assert.equal("jane", options.username)
      assert.equal("qwerty", options.password)
      assert.equal("{vault://env/credentials/username}", options["$refs"].username)
      assert.equal("{vault://env/credentials/password}", options["$refs"].password)

      -- updates values before first call from caches

      called = 0
      options = {
        username = "john",
        password = "secret",
        ["$refs"] = {
          username = "{vault://env/credentials/username}",
          password = "{vault://env/credentials/password}",
        },
      }

      local ok, err = try(callback, options)

      assert.is_nil(err)
      assert.True(ok)
      assert.equal(1, called)

      assert.equal("jane", options.username)
      assert.equal("qwerty", options.password)
      assert.equal("{vault://env/credentials/username}", options["$refs"].username)
      assert.equal("{vault://env/credentials/password}", options["$refs"].password)
    end)
  end)

  describe("update function", function()
    it("not change values on failure", function()
      finally(function()
        helpers.unsetenv("CREDENTIALS")
      end)

      helpers.setenv("CREDENTIALS", '{"username":"jane","password":"qwerty"}')

      -- warmup cache
      dereference("{vault://env/credentials/username}")
      dereference("{vault://env/credentials/password}")

      local config = {
        str_found = "found",
        str_not_found = "not found",
        str_not_found_2 = "not found",
        arr_found = { "found", "found", "found", "found", "found" },
        arr_hole = { "found", "found", "not found", "found", "found" },
        arr_not_found = { "found", "not found", "not found", "not found", "found" },
        map_found = {
          nil,
          "found",
          a = "found",
          b = "found",
          c = "found",
          d = "found",
        },
        map_not_found = {
          nil,
          "found",
          a = "found",
          b = "found",
          c = "found",
          d = "found",
        },
        ["$refs"] = {
          str_found = "{vault://env/credentials/username}",
          str_not_found = "{vault://env/not-found}",
          str_not_found_2 = "{vault://env/credentials/not-found}",
          arr_found = {
            nil,
            "{vault://env/credentials/username}",
            "{vault://env/credentials/password}",
            "{vault://env/credentials/username}",
          },
          arr_hole = {
            nil,
            "{vault://env/credentials/username}",
            "{vault://env/credentials/not-found}",
            "{vault://env/credentials/username}",
          },
          arr_not_found = {
            nil,
            "{vault://env/not-found}",
            "{vault://env/credentials/not-found}",
            "{vault://env/not-found}",
          },
          map_found = {
            a = "{vault://env/credentials/username}",
            b = "{vault://env/credentials/password}",
            c = "{vault://env/credentials/username}",
          },
          map_not_found = {
            a = "{vault://env/not-found}",
            b = "{vault://env/credentials/not-found}",
            c = "{vault://env/not-found}",
          }
        },
        sub = {
          str_found = "found",
          str_not_found = "not found",
          str_not_found_2 = "not found",
          arr_found = { "found", "found", "found", "found", "found" },
          arr_hole = { "found", "found", "not found", "found", "found" },
          arr_not_found = { "found", "not found", "not found", "not found", "found" },
          map_found = {
            nil,
            "found",
            a = "found",
            b = "found",
            c = "found",
            d = "found",
          },
          map_not_found = {
            nil,
            "found",
            a = "found",
            b = "found",
            c = "found",
            d = "found",
          },
          ["$refs"] = {
            str_found = "{vault://env/credentials/username}",
            str_not_found = "{vault://env/not-found}",
            str_not_found_2 = "{vault://env/credentials/not-found}",
            arr_found = {
              nil,
              "{vault://env/credentials/username}",
              "{vault://env/credentials/password}",
              "{vault://env/credentials/username}",
            },
            arr_hole = {
              nil,
              "{vault://env/credentials/username}",
              "{vault://env/credentials/not-found}",
              "{vault://env/credentials/username}",
            },
            arr_not_found = {
              nil,
              "{vault://env/not-found}",
              "{vault://env/credentials/not-found}",
              "{vault://env/not-found}",
            },
            map_found = {
              a = "{vault://env/credentials/username}",
              b = "{vault://env/credentials/password}",
              c = "{vault://env/credentials/username}",
            },
            map_not_found = {
              a = "{vault://env/not-found}",
              b = "{vault://env/credentials/not-found}",
              c = "{vault://env/not-found}",
            }
          },
        },
      }

      local updated_cfg = update(config)
      assert.equal(config, updated_cfg)

      for _, cfg in ipairs({ config, config.sub }) do
        assert.equal("jane", cfg.str_found)
        assert.equal("not found", cfg.str_not_found)
        assert.equal("not found", cfg.str_not_found_2)
        assert.same({ "found", "jane", "qwerty", "jane", "found" }, cfg.arr_found)
        assert.same({ "found", "jane", "not found", "jane", "found" }, cfg.arr_hole)
        assert.same({ "found", "not found", "not found", "not found", "found" }, cfg.arr_not_found)
        assert.same({
          nil,
          "found",
          a = "jane",
          b = "qwerty",
          c = "jane",
          d = "found",
        }, cfg.map_found)
        assert.same({
          nil,
          "found",
          a = "found",
          b = "found",
          c = "found",
          d = "found",
        }, cfg.map_not_found)
      end
    end)
  end)
end)
