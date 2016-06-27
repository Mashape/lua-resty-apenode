local helpers = require "spec.helpers"
local pl_dir = require "pl.dir"
local pl_path = require "pl.path"

describe("kong start/stop", function()
  setup(function()
    helpers.prepare_prefix()
  end)
  teardown(function()
    helpers.kill_all()
    helpers.clean_prefix()
  end)
  before_each(function()
    helpers.kill_all()
  end)

  it("start help", function()
    local _, stderr = helpers.kong_exec "start --help"
    assert.not_equal("", stderr)
  end)
  it("stop help", function()
    local _, stderr = helpers.kong_exec "stop --help"
    assert.not_equal("", stderr)
  end)
  it("start/stop default conf/prefix", function()
    -- don't want to force migrations to be run on default
    -- keyspace/database
    assert(helpers.kong_exec "start", {
      database = helpers.test_conf.database,
      pg_database = helpers.test_conf.pg_database,
      cassandra_keyspace = helpers.test_conf.cassandra_keyspace
    })
    assert(helpers.kong_exec "stop")
  end)
  it("#only start/stop custom Kong conf/prefix", function()
    assert(helpers.kong_exec("start --conf "..helpers.test_conf_path))
    assert.True(#pl_dir.getfiles(pl_path.join(helpers.test_conf.prefix, "pids")) > 0)
    assert(helpers.kong_exec("stop --prefix "..helpers.test_conf.prefix))
    assert.True(#pl_dir.getfiles(pl_path.join(helpers.test_conf.prefix, "pids")) == 0)
  end)
  it("start with inexistent prefix", function()
    finally(function()
      pcall(helpers.dir.rmtree, "foobar")
    end)

    assert(helpers.kong_exec "start --prefix foobar")
  end)
  it("start dumps Kong config in prefix", function()
    assert(helpers.kong_exec("start --conf "..helpers.test_conf_path))

    local conf_path = helpers.path.join(helpers.test_conf.prefix, "kong.conf")
    assert.truthy(helpers.path.exists(conf_path))
  end)

  describe("verbose args", function()
    it("accepts verbose --v", function()
      local _, stderr, stdout = helpers.kong_exec("start --v --conf "..helpers.test_conf_path)
      assert.equal("", stderr)
      assert.matches("[verbose] prefix in use: ", stdout, nil, true)
    end)
    it("accepts debug --vv", function()
      local _, stderr, stdout = helpers.kong_exec("start --vv --conf "..helpers.test_conf_path)
      assert.matches("[verbose] prefix in use: ", stdout, nil, true)
      assert.matches("[debug] prefix = ", stdout, nil, true)
      assert.matches("[debug] database = ", stdout, nil, true)
      assert.equal("", stderr)
    end)
    it("should start with an inexistent prefix", function()
      finally(function()
        helpers.kill_all()
        pcall(helpers.dir.rmtree, "foobar")
      end)

      assert(helpers.kong_exec "start --prefix foobar")
      assert.truthy(helpers.path.exists("foobar"))
    end)
  end)

  describe("Serf", function()
    it("starts Serf agent daemon", function()
      assert(helpers.kong_exec("start --conf "..helpers.test_conf_path))

      local serf_pid_path = helpers.path.join(helpers.test_conf.prefix, "pids", "serf.pid")
      local cmd = string.format("kill -0 `cat %s` >/dev/null 2>&1", serf_pid_path)
      assert(helpers.execute(cmd))
    end)
    it("recovers from expired serf.pid file", function()
      local serf_pid_path = helpers.path.join(helpers.test_conf.prefix, "pids", "serf.pid")
      assert(helpers.execute("touch "..serf_pid_path)) -- dumb pid
      assert(helpers.kong_exec("start --conf "..helpers.test_conf_path))

      local cmd = string.format("kill -0 `cat %s` >/dev/null 2>&1", serf_pid_path)
      assert(helpers.execute(cmd))
    end)
  end)

  describe("dnsmasq", function()
    it("starts dnsmasq daemon", function()
      assert(helpers.kong_exec("start --conf "..helpers.test_conf_path, {
        dnsmasq = true,
        dns_resolver = ""
      }))

      local dnsmasq_pid_path = helpers.path.join(helpers.test_conf.prefix, "pids", "dnsmasq.pid")
      local cmd = string.format("kill -0 `cat %s` >/dev/null 2>&1", dnsmasq_pid_path)
      local _, code = helpers.utils.executeex(cmd)
      assert.equal(0, code)
    end)
    it("recovers from expired dnsmasq.pid file", function()
      local dnsmasq_pid_path = helpers.path.join(helpers.test_conf.prefix, "pids", "dnsmasq.pid")
      assert(helpers.execute("touch "..dnsmasq_pid_path)) -- dumb pid

      assert(helpers.kong_exec("start --conf "..helpers.test_conf_path, {
        dnsmasq = true,
        dns_resolver = ""
      }))

      local cmd = string.format("kill -0 `cat %s` >/dev/null 2>&1", dnsmasq_pid_path)
      local _, code = helpers.utils.executeex(cmd)
      assert.equal(0, code)
    end)
  end)

  describe("errors", function()
    it("start inexistent Kong conf file", function()
      local ok, stderr = helpers.kong_exec "start --conf foobar.conf"
      assert.False(ok)
      assert.is_string(stderr)
      assert.matches("Error: no file at: foobar.conf", stderr, nil, true)
    end)
    it("stop inexistent prefix", function()
      finally(function()
        pcall(helpers.dir.rmtree, helpers.test_conf.prefix)
      end)

      local ok, stderr = helpers.kong_exec("start --prefix "..helpers.test_conf.prefix)
      assert.equal("", stderr)
      assert.True(ok)

      ok, stderr = helpers.kong_exec("stop --prefix inexistent")
      assert.False(ok)
      assert.matches("Error: no such prefix: inexistent", stderr, nil, true)
    end)
    it("notifies when Nginx is already running", function()
      finally(function()
        pcall(helpers.dir.rmtree, helpers.test_conf.prefix)
      end)

      assert(helpers.dir.makepath(helpers.test_conf.prefix))

      local ok, stderr = helpers.kong_exec("start --prefix "..helpers.test_conf.prefix)
      assert.equal("", stderr)
      assert.True(ok)

      ok, stderr = helpers.kong_exec("start --prefix "..helpers.test_conf.prefix)
      assert.False(ok)
      assert.matches("Nginx is already running in", stderr)
    end)
  end)
end)
