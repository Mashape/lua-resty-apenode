local writefile = require("pl.utils").writefile
local tempfilename = require("pl.path").tmpname
local pretty = require("pl.pretty").write


-- Several DNS tests use the actual DNS to verify the client behavior against real name servers.  It seems that
-- even though we have a DNS mocking system, it is good to have some coverage against actual servers to ensure that
-- we're not relying on mocked behavior.  We use the domain name kong-gateway-testing.link, which is hosted in Route53
-- in the AWS sandbox, allowing Gateway developers to make additions if required.
local TEST_DOMAIN="kong-gateway-testing.link"


-- empty records and not found errors should be identical, hence we
-- define a constant for that error message
local NOT_FOUND_ERROR = "dns server error: 3 name error"
local EMPTY_ERROR = "dns client error: 101 empty record received"
local BAD_IPV4_ERROR = "dns client error: 102 invalid name, bad IPv4"
local BAD_IPV6_ERROR = "dns client error: 103 invalid name, bad IPv6"

local gettime, sleep
if ngx then
  gettime = ngx.now
  sleep = ngx.sleep
else
  local socket = require("socket")
  gettime = socket.gettime
  sleep = socket.sleep
end

-- simple debug function
-- luacheck: push no unused
local dump = function(...)
  print(pretty({...}))
end
-- luacheck: pop

describe("[DNS client]", function()

  local client, resolver

  before_each(function()
    _G.busted_new_dns_client = false

    client = require("kong.resty.dns.client")
    resolver = require("resty.dns.resolver")

    -- `resolver.query_func` is hooked to inspect resolver query calls. New values can be assigned to it.
    -- This default will just call the original resolver (hence is transparent)
    resolver.query_func = function(self, original_query_func, name, options)
      return original_query_func(self, name, options)
    end

    -- patch the resolver lib, such that any new resolver created will query
    -- using the `resolver.query_func` defined above
    local old_new = resolver.new
    resolver.new = function(...)
      local r, err = old_new(...)
      if not r then
        return nil, err
      end
      local original_query_func = r.query

      -- remember the passed in query_func
      -- so it won't be replaced by the next resolver.new call
      -- and won't interfere with other tests
      local query_func = resolver.query_func
      r.query = function(self, ...)
        return query_func(self, original_query_func, ...)
      end
      return r
    end

  end)

  after_each(function()
    package.loaded["kong.resty.dns.client"] = nil
    package.loaded["resty.dns.resolver"] = nil
    client = nil
    resolver = nil
  end)

  describe("initialization", function()

    it("does not fail with no nameservers", function()
      -- empty list fallsback on resolv.conf
      assert.has.no.error(function() client.init( {nameservers = {} } ) end)

      assert.has.no.error(function() client.init( {nameservers = {}, resolvConf = {} } ) end)
    end)

    it("skips ipv6 nameservers with scopes", function()
      assert.has.no.error(function() client.init({
              enable_ipv6 = true,
              resolvConf = {"nameserver [fe80::1%enp0s20f0u1u1]"},
            })
          end)
      local ip, port = client.toip(TEST_DOMAIN)
      assert.is_nil(ip)
      assert.not_matches([[failed to parse host name "[fe80::1%enp0s20f0u1u1]": invalid IPv6 address]], port, nil, true)
      assert.matches([[failed to create a resolver: no nameservers specified]], port, nil, true)
    end)

    it("fails with order being empty", function()
      -- fails with an empty one
      assert.has.error(
        function() client.init({order = {}}) end,
        "Invalid order list; cannot be empty"
      )
    end)

    it("fails with order containing an unknown type", function()
      -- fails with an unknown one
      assert.has.error(
        function() client.init({order = {"LAST", "a", "aa"}}) end,
        "Invalid dns record type in order array; aa"
      )
    end)

    it("succeeds with order unset", function()
      assert.is.True(client.init({order = nil}))
    end)

    it("succeeds without i/o access", function()
      local result, err = assert(client.init({
          nameservers = { "198.51.100.0:53" },
          hosts = {},  -- empty tables to parse to prevent defaulting to /etc/hosts
          resolvConf = {},   -- and resolv.conf files
        }))
      assert.is.True(result)
      assert.is.Nil(err)
      assert.are.equal(#client.getcache(), 0) -- no hosts file record should have been imported
    end)

    describe("inject localhost:", function()

      it("if absent", function()
        local result, err, record
        result, err = assert(client.init({
            nameservers = { "198.51.100.0:53" },
            resolvConf = {},
            hosts = {},
          }))
        assert.is.True(result)
        assert.is.Nil(err)
        record = client.getcache():get("28:localhost")
        assert.equal("[::1]", record[1].address)
        record = client.getcache():get("1:localhost")
        assert.equal("127.0.0.1", record[1].address)
      end)

      it("not if ipv4 exists", function()
        local result, err, record
        result, err = assert(client.init({
            nameservers = { "198.51.100.0:53" },
            resolvConf = {},
            hosts = {"1.2.3.4 localhost"},
          }))
        assert.is.True(result)
        assert.is.Nil(err)

        -- IPv6 is not defined
        record = client.getcache():get("28:localhost")
        assert.is_nil(record)

        -- IPv4 is not overwritten
        record = client.getcache():get("1:localhost")
        assert.equal("1.2.3.4", record[1].address)
      end)

      it("not if ipv6 exists", function()
        local result, err, record
        result, err = assert(client.init({
            nameservers = { "198.51.100.0:53" },
            resolvConf = {},
            hosts = {"::1:2:3:4 localhost"},
          }))
        assert.is.True(result)
        assert.is.Nil(err)

        -- IPv6 is not overwritten
        record = client.getcache():get("28:localhost")
        assert.equal("[::1:2:3:4]", record[1].address)

        -- IPv4 is not defined
        record = client.getcache():get("1:localhost")
        assert.is_nil(record)
      end)

    end)

  end)


  describe("iterating searches", function()

    describe("without type", function()
      it("works with a 'search' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        local list = {}
        for qname, qtype in client._search_iter("host", nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.one.com:33',
            'host.two.com:33',
            'host:33',
            'host.one.com:1',
            'host.two.com:1',
            'host:1',
            'host.one.com:28',
            'host.two.com:28',
            'host:28',
            'host.one.com:5',
            'host.two.com:5',
            'host:5',
          }, list)
      end)

      it("works with a 'search .' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search .",
              "options ndots:1",
            }
          }))
        local list = {}
        for qname, qtype in client._search_iter("host", nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host:33',
            'host:1',
            'host:28',
            'host:5',
          }, list)
      end)

      it("works with a 'domain' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "domain local.domain.com",
              "options ndots:1",
            }
          }))
        local list = {}
        for qname, qtype in client._search_iter("host", nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
          'host.local.domain.com:33',
          'host:33',
          'host.local.domain.com:1',
          'host:1',
          'host.local.domain.com:28',
          'host:28',
          'host.local.domain.com:5',
          'host:5',
        }, list)
      end)

      it("handles last successful type", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        local lrucache = client.getcache()
        -- insert a last successful type
        local hostname = "host"
        lrucache:set(hostname, client.TYPE_CNAME)
        local list = {}
        for qname, qtype in client._search_iter(hostname, nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.one.com:5',
            'host.two.com:5',
            'host:5',
            'host.one.com:33',
            'host.two.com:33',
            'host:33',
            'host.one.com:1',
            'host.two.com:1',
            'host:1',
            'host.one.com:28',
            'host.two.com:28',
            'host:28',
          }, list)
      end)

    end)

    describe("FQDN without type", function()
      it("works with a 'search' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        local list = {}
        for qname, qtype in client._search_iter("host.", nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.:33',
            'host.:1',
            'host.:28',
            'host.:5',
          }, list)
      end)

      it("works with a 'search .' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search .",
              "options ndots:1",
            }
          }))
        local list = {}
        for qname, qtype in client._search_iter("host.", nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.:33',
            'host.:1',
            'host.:28',
            'host.:5',
          }, list)
      end)

      it("works with a 'domain' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "domain local.domain.com",
              "options ndots:1",
            }
          }))
        local list = {}
        for qname, qtype in client._search_iter("host.", nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
          'host.:33',
          'host.:1',
          'host.:28',
          'host.:5',
        }, list)
      end)

      it("handles last successful type", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        local lrucache = client.getcache()
        -- insert a last successful type
        local hostname = "host."
        lrucache:set(hostname, client.TYPE_CNAME)
        local list = {}
        for qname, qtype in client._search_iter(hostname, nil) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.:5',
            'host.:33',
            'host.:1',
            'host.:28',
          }, list)
      end)

    end)

    describe("with type", function()
      it("works with a 'search' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        local list = {}
        -- search using IPv6 type
        for qname, qtype in client._search_iter("host", client.TYPE_AAAA) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.one.com:28',
            'host.two.com:28',
            'host:28',
          }, list)
      end)

      it("works with a 'domain' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "domain local.domain.com",
              "options ndots:1",
            }
          }))
        local list = {}
        -- search using IPv6 type
        for qname, qtype in client._search_iter("host", client.TYPE_AAAA) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
          'host.local.domain.com:28',
          'host:28',
        }, list)
      end)

      it("ignores last successful type", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        -- insert a last successful type
        client.getcache()["host"] = client.TYPE_CNAME
        local list = {}
        -- search using IPv6 type
        for qname, qtype in client._search_iter("host", client.TYPE_AAAA) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.one.com:28',
            'host.two.com:28',
            'host:28',
          }, list)
      end)

    end)

    describe("FQDN with type", function()
      it("works with a 'search' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        local list = {}
        -- search using IPv6 type
        for qname, qtype in client._search_iter("host.", client.TYPE_AAAA) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.:28',
          }, list)
      end)

      it("works with a 'domain' option", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "domain local.domain.com",
              "options ndots:1",
            }
          }))
        local list = {}
        -- search using IPv6 type
        for qname, qtype in client._search_iter("host.", client.TYPE_AAAA) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
          'host.:28',
        }, list)
      end)

      it("ignores last successful type", function()
        assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "search one.com two.com",
              "options ndots:1",
            }
          }))
        -- insert a last successful type
        client.getcache()["host"] = client.TYPE_CNAME
        local list = {}
        -- search using IPv6 type
        for qname, qtype in client._search_iter("host.", client.TYPE_AAAA) do
          table.insert(list, tostring(qname)..":"..tostring(qtype))
        end
        assert.same({
            'host.:28',
          }, list)
      end)

    end)

    it("honours 'ndots'", function()
      assert(client.init({
          resolvConf = {
            "nameserver 198.51.100.0",
            "search one.com two.com",
            "options ndots:1",
          }
        }))
      local list = {}
      -- now use a name with a dot in it
      for qname, qtype in client._search_iter("local.host", nil) do
        table.insert(list, tostring(qname)..":"..tostring(qtype))
      end
      assert.same({
          'local.host:33',
          'local.host.one.com:33',
          'local.host.two.com:33',
          'local.host:1',
          'local.host.one.com:1',
          'local.host.two.com:1',
          'local.host:28',
          'local.host.one.com:28',
          'local.host.two.com:28',
          'local.host:5',
          'local.host.one.com:5',
          'local.host.two.com:5',
        }, list)
    end)

    it("hosts file always resolves first, overriding `ndots`", function()
      assert(client.init({
          resolvConf = {
            "nameserver 198.51.100.0",
            "search one.com two.com",
            "options ndots:1",
          },
          hosts = {
            "127.0.0.1 host",
            "::1 host",
          },
          order = { "LAST", "SRV", "A", "AAAA", "CNAME" }
        }))
      local list = {}
      for qname, qtype in client._search_iter("host", nil) do
        table.insert(list, tostring(qname)..":"..tostring(qtype))
      end
      assert.same({
          'host:1',
          'host.one.com:1',
          'host.two.com:1',
          'host.one.com:33',
          'host.two.com:33',
          'host:33',
          'host:28',
          'host.one.com:28',
          'host.two.com:28',
          'host.one.com:5',
          'host.two.com:5',
          'host:5',
        }, list)
    end)

    for retrans in ipairs({1, 2}) do
      for _, timeout in ipairs({1, 2}) do
        it("correctly observes #timeout of " .. tostring(timeout) .. " seconds with " .. tostring(retrans) .. " retries", function()
          -- KAG-2300 - https://github.com/Kong/kong/issues/10182
          -- If we encounter a timeout while talking to the DNS server, expect the total timeout to be close to the
          -- configured timeout * retrans parameters
          assert(client.init({
            resolvConf = {
              "nameserver 198.51.100.0",
              "domain one.com",
            },
            timeout = timeout * 1000,
            retrans = retrans,
            hosts = {
              "127.0.0.1 host"
            }
          }))
          resolver.query_func = function(self, original_query_func, name, options)
            -- The first request uses syncQuery not waiting on the
            -- aysncQuery timer, so the low-level r:query() could not sleep(5s),
            -- it can only sleep(timeout).
            ngx.sleep(math.min(timeout, 5))
            return nil
          end
          local start_time = ngx.now()
          client.resolve("host1.one.com.")
          local duration = ngx.now() - start_time
          assert.truthy(duration < (timeout * retrans + 1))
        end)
      end
    end

    -- The domain name below needs to have both a SRV and an A record
    local SRV_A_TEST_NAME = "timeouttest."..TEST_DOMAIN

    it("verify correctly set up test DNS entry", function()
      assert(client.init({ timeout = 1000, retrans = 2 }))
      local answers = client.resolve(SRV_A_TEST_NAME, { qtype = client.TYPE_SRV})
      assert.same(client.TYPE_SRV, answers[1].type)
      answers = client.resolve(SRV_A_TEST_NAME, { qtype = client.TYPE_A})
      assert.same(client.TYPE_A, answers[1].type)
    end)

    it("does not respond with incorrect answer on transient failure", function()
      -- KAG-2300 - https://github.com/Kong/kong/issues/10182
      -- If we encounter a timeout while talking to the DNS server, don't keep trying with other record types
      assert(client.init({ timeout = 1000, retrans = 2 }))
      resolver.query_func = function(self, original_query_func, name, options)
        if options.qtype == client.TYPE_SRV then
          ngx.sleep(10)
        else
          return original_query_func(self, name, options)
        end
      end
      local answers = client.resolve(SRV_A_TEST_NAME)
      assert.is_nil(answers)
    end)

  end)


  it("fetching a record without nameservers errors", function()
    assert(client.init({ resolvConf = {} }))

    local host = TEST_DOMAIN
    local typ = client.TYPE_A

    local answers, err, _ = client.resolve(host, { qtype = typ })
    assert.is_nil(answers)
    assert(err:find("failed to create a resolver: no nameservers specified"))
  end)

  it("fetching a TXT record", function()
    assert(client.init())

    local host = "txttest."..TEST_DOMAIN
    local typ = client.TYPE_TXT

    local answers, err, try_list = client.resolve(host, { qtype = typ })
    assert(answers, (err or "") .. tostring(try_list))
    assert.are.equal(host, answers[1].name)
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(#answers, 1)
  end)

  it("fetching a CNAME record", function()
    assert(client.init())

    local host = "smtp."..TEST_DOMAIN
    local typ = client.TYPE_CNAME

    local answers = assert(client.resolve(host, { qtype = typ }))
    assert.are.equal(host, answers[1].name)
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(#answers, 1)
  end)

  it("fetching a CNAME record FQDN", function()
    assert(client.init())

    local host = "smtp."..TEST_DOMAIN
    local typ = client.TYPE_CNAME

    local answers = assert(client.resolve(host .. ".", { qtype = typ }))
    assert.are.equal(host, answers[1].name)
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(#answers, 1)
  end)

  it("expire and touch times", function()
    assert(client.init())

    local host = "txttest."..TEST_DOMAIN
    local typ = client.TYPE_TXT

    local answers, _, _ = assert(client.resolve(host, { qtype = typ }))

    local now = gettime()
    local touch_diff = math.abs(now - answers.touch)
    local ttl_diff = math.abs((now + answers[1].ttl) - answers.expire)
    assert(touch_diff < 0.01, "Expected difference to be near 0; "..
                                tostring(touch_diff))
    assert(ttl_diff < 0.01, "Expected difference to be near 0; "..
                                tostring(ttl_diff))

    sleep(1)

    -- fetch again, now from cache
    local oldtouch = answers.touch
    local answers2 = assert(client.resolve(host, { qtype = typ }))

    assert.are.equal(answers, answers2) -- cached table, so must be same
    assert.are.not_equal(oldtouch, answers.touch)

    now = gettime()
    touch_diff = math.abs(now - answers.touch)
    ttl_diff = math.abs((now + answers[1].ttl) - answers.expire)
    assert(touch_diff < 0.01, "Expected difference to be near 0; "..
                                tostring(touch_diff))
    assert((0.990 < ttl_diff) and (ttl_diff < 1.01),
              "Expected difference to be near 1; "..tostring(ttl_diff))

  end)

  it("fetching names case insensitive", function()
    assert(client.init())

    resolver.query_func = function(self, original_query_func, name, options)
      return {
        {
          name = "some.UPPER.case",
          type = client.TYPE_A,
          ttl = 30,
        }
      }
    end

    local res, _, _ = client.resolve(
      "some.upper.CASE",
      { qtype = client.TYPE_A },
      false)
    assert.equal(1, #res)
    assert.equal("some.upper.case", res[1].name)
  end)

  it("fetching multiple A records", function()
    assert(client.init())

    local host = "atest."..TEST_DOMAIN
    local typ = client.TYPE_A

    local answers = assert(client.resolve(host, { qtype = typ }))
    assert.are.equal(#answers, 2)
    assert.are.equal(host, answers[1].name)
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(host, answers[2].name)
    assert.are.equal(typ, answers[2].type)
  end)

  it("fetching multiple A records FQDN", function()
    assert(client.init())

    local host = "atest."..TEST_DOMAIN
    local typ = client.TYPE_A

    local answers = assert(client.resolve(host .. ".", { qtype = typ }))
    assert.are.equal(#answers, 2)
    assert.are.equal(host, answers[1].name)
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(host, answers[2].name)
    assert.are.equal(typ, answers[2].type)
  end)

  it("fetching A record redirected through 2 CNAME records (un-typed)", function()
    assert(client.init({ search = {}, }))
    local lrucache = client.getcache()

    --[[
    This test might fail. Recurse flag is on by default. This means that the first return
    includes the cname records, but the second one (within the ttl) will only include the
    A-record.
    Note that this is not up to the client code, but it's done out of our control by the
    dns server.
    If we turn on the 'no_recurse = true' option, then the dns server might refuse the request
    (error nr 5).
    So effectively the first time the test runs, it's ok. Immediately running it again will
    make it fail. Wait for the ttl to expire, then it will work again.

    This does not affect client side code, as the result is always the final A record.
    --]]

    local host = "smtp."..TEST_DOMAIN
    local typ = client.TYPE_A
    local answers, _, _ = assert(client.resolve(host))

    -- check first CNAME
    local key1 = client.TYPE_CNAME..":"..host
    local entry1 = lrucache:get(key1)
    assert.is_nil(entry1)

    -- check second CNAME
    local key2 = client.TYPE_CNAME..":thuis.kong-gateway-testing.link"
    local entry2 = lrucache:get(key2)
    assert.is_nil(entry2)

    assert.are.equal(host, answers[1].name) -- we got final name same to host
    assert.are.equal(typ, answers[1].type)  -- we got a final A type record
    assert.are.equal(#answers, 1)

    -- check last successful lookup references
    local lastsuccess3 = lrucache:get(answers[1].name)
    local lastsuccess2 = lrucache:get("thuis.kong-gateway-testing.link")
    local lastsuccess1 = lrucache:get("kong-gateway-testing.link")
    assert.are.equal(client.TYPE_A, lastsuccess3)
    assert.is_nil(lastsuccess2)
    assert.is_nil(lastsuccess1)

    -- check entries in the intermediate cache against the final output result
    local key = client.TYPE_A .. ":" .. host
    local entry = lrucache:get(key)
    assert.same(answers, entry)
  end)

  it("fetching multiple SRV records (un-typed)", function()
    assert(client.init())

    local host = "srvtest."..TEST_DOMAIN
    local typ = client.TYPE_SRV

    -- un-typed lookup
    local answers = assert(client.resolve(host))
    assert.are.equal(host, answers[1].name)
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(host, answers[2].name)
    assert.are.equal(typ, answers[2].type)
    assert.are.equal(host, answers[3].name)
    assert.are.equal(typ, answers[3].type)
    assert.are.equal(#answers, 3)
  end)

  it("fetching multiple SRV records through CNAME (un-typed)", function()
    assert(client.init({ search = {}, }))
    local lrucache = client.getcache()

    local host = "cname2srv."..TEST_DOMAIN
    local typ = client.TYPE_SRV

    -- un-typed lookup
    local answers = assert(client.resolve(host))

    -- first check CNAME
    local key = client.TYPE_CNAME..":"..host
    local entry = lrucache:get(key)
    assert.is_nil(entry)

    -- check final target
    assert.are.equal(typ, answers[1].type)
    assert.are.equal(typ, answers[2].type)
    assert.are.equal(typ, answers[3].type)
    assert.are.equal(#answers, 3)

    -- check entries in the intermediate cache against the final output result
    key = client.TYPE_SRV .. ":" .. host
    entry = lrucache:get(key)
    assert.same(answers, entry)
  end)

  it("fetching non-type-matching records", function()
    assert(client.init({
          -- don't supply resolvConf and fallback to default resolver
          -- so that CI and docker can have reliable results
          -- but remove `search` and `domain`
          search = {},
        }))

    local host = "srvtest."..TEST_DOMAIN
    local typ = client.TYPE_A   --> the entry is SRV not A

    local answers, err, _ = client.resolve(host, {qtype = typ})
    assert.is_nil(answers)  -- returns nil
    assert.equal(EMPTY_ERROR, err)
  end)

  it("fetching non-existing records", function()
    assert(client.init({
          -- don't supply resolvConf and fallback to default resolver
          -- so that CI and docker can have reliable results
          -- but remove `search` and `domain`
          search = {},
        }))

    local host = "IsNotHere."..TEST_DOMAIN

    local answers, err, _ = client.resolve(host)
    assert.is_nil(answers)
    assert.equal(NOT_FOUND_ERROR, err)
  end)

  it("fetching IPv4 address as A type", function()
    assert(client.init())
    local lrucache = client.getcache()

    local host = "1.2.3.4"

    local answers = assert(client.resolve(host, { qtype = client.TYPE_A }))
    assert.are.equal(#answers, 1)
    assert.are.equal(client.TYPE_A, answers[1].type)
    assert.are.equal(10*365*24*60*60, answers[1].ttl)  -- 10 year ttl

    assert.equal(client.TYPE_A, lrucache:get(host))
  end)

  it("fetching IPv4 address as SRV type", function()
    assert(client.init())

    local callcount = 0
    resolver.query_func = function(self, original_query_func, name, options)
      callcount = callcount + 1
      return original_query_func(self, name, options)
    end

    local _, err, _ = client.resolve(
      "1.2.3.4",
      { qtype = client.TYPE_SRV },
      false
    )
    assert.equal(0, callcount)
    assert.equal(BAD_IPV4_ERROR, err)
  end)

  it("fetching IPv6 address as AAAA type", function()
    assert(client.init())

    local host = "[1:2::3:4]"

    local answers = assert(client.resolve(host, { qtype = client.TYPE_AAAA }))
    assert.are.equal(#answers, 1)
    assert.are.equal(client.TYPE_AAAA, answers[1].type)
    assert.are.equal(10*365*24*60*60, answers[1].ttl)  -- 10 year ttl
    assert.are.equal(host, answers[1].address)

    local lrucache = client.getcache()
    assert.equal(client.TYPE_AAAA, lrucache:get(host))
  end)

  it("fetching IPv6 address as AAAA type (without brackets)", function()
    assert(client.init())

    local host = "1:2::3:4"

    local answers = assert(client.resolve(host, { qtype = client.TYPE_AAAA }))
    assert.are.equal(#answers, 1)
    assert.are.equal(client.TYPE_AAAA, answers[1].type)
    assert.are.equal(10*365*24*60*60, answers[1].ttl)  -- 10 year ttl
    assert.are.equal("["..host.."]", answers[1].address) -- brackets added

    local lrucache = client.getcache()
    assert.equal(client.TYPE_AAAA, lrucache:get(host))
  end)

  it("fetching IPv6 address as SRV type", function()
    assert(client.init())

    local callcount = 0
    resolver.query_func = function(self, original_query_func, name, options)
      callcount = callcount + 1
      return original_query_func(self, name, options)
    end

    local _, err, _ = client.resolve(
      "[1:2::3:4]",
      { qtype = client.TYPE_SRV },
      false
    )
    assert.equal(0, callcount)
    assert.equal(BAD_IPV6_ERROR, err)
  end)

  it("fetching invalid IPv6 address", function()
    assert(client.init({
          resolvConf = {
            -- resolv.conf without `search` and `domain` options
            "nameserver 198.51.100.0",
          },
        }))

    local host = "[1::2:3::4]"  -- 2x double colons

    local answers, err, history = client.resolve(host)
    assert.is_nil(answers)
    assert.equal(BAD_IPV6_ERROR, err)
    assert(tostring(history):find("bad IPv6", nil, true))
  end)

  it("fetching IPv6 in an SRV record adds brackets",function()
    assert(client.init())
    local host = "hello.world"
    local address = "::1"
    local entry = {
      {
        type = client.TYPE_SRV,
        target = address,
        port = 321,
        weight = 10,
        priority = 10,
        class = 1,
        name = host,
        ttl = 10,
      },
    }

    resolver.query_func = function(self, original_query_func, name, options)
      if name == host and options.qtype == client.TYPE_SRV then
        return entry
      end
      return original_query_func(self, name, options)
    end

    local res, _, _ = client.resolve(
      host,
      { qtype = client.TYPE_SRV },
      false
    )
    assert.equal("["..address.."]", res[1].target)

  end)

  it("recursive lookups failure - single resolve", function()
    assert(client.init({
          resolvConf = {
            -- resolv.conf without `search` and `domain` options
            "nameserver 198.51.100.0",
          },
        }))
    resolver.query_func = function(self, original_query_func, name, opts)
      if name ~= "hello.world" and (opts or {}).qtype ~= client.TYPE_CNAME then
        return original_query_func(self, name, opts)
      end
      return {
                {
                  type = client.TYPE_CNAME,
                  cname = "hello.world",
                  class = 1,
                  name = "hello.world",
                  ttl = 30,
                },
              }
    end

    local result, err, _ = client.resolve("hello.world")
    assert.is_nil(result)
    assert.are.equal("recursion detected", err)
  end)

  it("recursive lookups failure - single", function()
    assert(client.init({
          resolvConf = {
            -- resolv.conf without `search` and `domain` options
            "nameserver 198.51.100.0",
          },
        }))
    local lrucache = client.getcache()
    local entry1 = {
      {
        type = client.TYPE_CNAME,
        cname = "hello.world",
        class = 1,
        name = "hello.world",
        ttl = 0,
      },
      touch = 0,
      expire = 0,
    }
    -- insert in the cache
    lrucache:set(entry1[1].type..":"..entry1[1].name, entry1)

    -- Note: the bad case would be that the below lookup would hang due to round-robin on an empty table
    local result, err, _ = client.resolve("hello.world", nil, true)
    assert.is_nil(result)
    assert.are.equal("recursion detected", err)
  end)

  it("recursive lookups failure - multi", function()
    assert(client.init({
          resolvConf = {
            -- resolv.conf without `search` and `domain` options
            "nameserver 198.51.100.0",
          },
        }))
    local lrucache = client.getcache()
    local entry1 = {
      {
        type = client.TYPE_CNAME,
        cname = "bye.bye.world",
        class = 1,
        name = "hello.world",
        ttl = 0,
      },
      touch = 0,
      expire = 0,
    }
    local entry2 = {
      {
        type = client.TYPE_CNAME,
        cname = "hello.world",
        class = 1,
        name = "bye.bye.world",
        ttl = 0,
      },
      touch = 0,
      expire = 0,
    }
    -- insert in the cache
    lrucache:set(entry1[1].type..":"..entry1[1].name, entry1)
    lrucache:set(entry2[1].type..":"..entry2[1].name, entry2)

    -- Note: the bad case would be that the below lookup would hang due to round-robin on an empty table
    local result, err, _ = client.resolve("hello.world", nil, true)
    assert.is_nil(result)
    assert.are.equal("recursion detected", err)
  end)

  it("resolving from the /etc/hosts file; preferred A or AAAA order", function()
    local f = tempfilename()
    writefile(f, [[
127.3.2.1 localhost
1::2 localhost
]])
    assert(client.init(
      {
        hosts = f,
        order = {"SRV", "CNAME", "A", "AAAA"},
      }))

    local lrucache = client.getcache()
    assert.equal(client.TYPE_A, lrucache:get("localhost")) -- success set to A as it is the preferred option

    assert(client.init(
      {
        hosts = f,
        order = {"SRV", "CNAME", "AAAA", "A"},
      }))

    lrucache = client.getcache()
    assert.equal(client.TYPE_AAAA, lrucache:get("localhost")) -- success set to AAAA as it is the preferred option
  end)


  it("resolving from the /etc/hosts file", function()
    local f = tempfilename()
    writefile(f, [[
127.3.2.1 localhost
1::2 localhost

123.123.123.123 mashape
1234::1234 kong.for.president
]])

    assert(client.init({ hosts = f }))
    os.remove(f)

    local answers, err = client.resolve("localhost", {qtype = client.TYPE_A})
    assert.is.Nil(err)
    assert.are.equal(answers[1].address, "127.3.2.1")

    answers, err = client.resolve("localhost", {qtype = client.TYPE_AAAA})
    assert.is.Nil(err)
    assert.are.equal(answers[1].address, "[1::2]")

    answers, err = client.resolve("mashape", {qtype = client.TYPE_A})
    assert.is.Nil(err)
    assert.are.equal(answers[1].address, "123.123.123.123")

    answers, err = client.resolve("kong.for.president", {qtype = client.TYPE_AAAA})
    assert.is.Nil(err)
    assert.are.equal(answers[1].address, "[1234::1234]")
  end)

  describe("toip() function", function()
    it("A/AAAA-record, round-robin",function()
      assert(client.init({ search = {}, }))
      local host = "atest."..TEST_DOMAIN
      local answers = assert(client.resolve(host))
      answers.last_index = nil -- make sure to clean
      local ips = {}
      for _,rec in ipairs(answers) do ips[rec.address] = true end
      local order = {}
      for n = 1, #answers do
        local ip = client.toip(host)
        ips[ip] = nil
        order[n] = ip
      end
      -- this table should be empty again
      assert.is_nil(next(ips))
      -- do again, and check same order
      for n = 1, #order do
        local ip = client.toip(host)
        assert.same(order[n], ip)
      end
    end)
    it("SRV-record, round-robin on lowest prio",function()
      assert(client.init())
      local lrucache = client.getcache()
      local host = "hello.world.test"
      local entry = {
        {
          type = client.TYPE_SRV,
          target = "1.2.3.4",
          port = 8000,
          weight = 5,
          priority = 10,
          class = 1,
          name = host,
          ttl = 10,
        },
        {
          type = client.TYPE_SRV,
          target = "1.2.3.4",
          port = 8001,
          weight = 5,
          priority = 20,
          class = 1,
          name = host,
          ttl = 10,
        },
        {
          type = client.TYPE_SRV,
          target = "1.2.3.4",
          port = 8002,
          weight = 5,
          priority = 10,
          class = 1,
          name = host,
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10,
      }
      -- insert in the cache
      lrucache:set(entry[1].type..":"..entry[1].name, entry)

      local results = {}
      for _ = 1,20 do
        local _, port = client.toip(host)
        results[port] = (results[port] or 0) + 1
      end

      -- 20 passes, each should get 10
      assert.equal(0, results[8001] or 0) --priority 20, no hits
      assert.equal(10, results[8000] or 0) --priority 10, 50% of hits
      assert.equal(10, results[8002] or 0) --priority 10, 50% of hits
    end)
    it("SRV-record with 1 entry, round-robin",function()
      assert(client.init())
      local lrucache = client.getcache()
      local host = "hello.world"
      local entry = {
        {
          type = client.TYPE_SRV,
          target = "1.2.3.4",
          port = 321,
          weight = 10,
          priority = 10,
          class = 1,
          name = host,
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10,
      }
      -- insert in the cache
      lrucache:set(entry[1].type..":"..entry[1].name, entry)

      -- repeated lookups, as the first will simply serve the first entry
      -- and the only second will setup the round-robin scheme, this is
      -- specific for the SRV record type, due to the weights
      for _ = 1 , 10 do
        local ip, port = assert(client.toip(host))
        assert.equal("1.2.3.4", ip)
        assert.equal(321, port)
      end
    end)
    it("SRV-record with 0-weight, round-robin",function()
      assert(client.init())
      local lrucache = client.getcache()
      local host = "hello.world"
      local entry = {
        {
          type = client.TYPE_SRV,
          target = "1.2.3.4",
          port = 321,
          weight = 0,   --> weight 0
          priority = 10,
          class = 1,
          name = host,
          ttl = 10,
        },
        {
          type = client.TYPE_SRV,
          target = "1.2.3.5",
          port = 321,
          weight = 50,   --> weight 50
          priority = 10,
          class = 1,
          name = host,
          ttl = 10,
        },
        {
          type = client.TYPE_SRV,
          target = "1.2.3.6",
          port = 321,
          weight = 50,   --> weight 50
          priority = 10,
          class = 1,
          name = host,
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10,
      }
      -- insert in the cache
      lrucache:set(entry[1].type..":"..entry[1].name, entry)

      -- weight 0 will be weight 1, without any reduction in weight
      -- of the other ones.
      local track = {}
      for _ = 1 , 202 do  --> run around twice
        local ip, _ = assert(client.toip(host))
        track[ip] = (track[ip] or 0) + 1
      end
      assert.equal(100, track["1.2.3.5"])
      assert.equal(100, track["1.2.3.6"])
      assert.equal(2, track["1.2.3.4"])
    end)
    it("port passing",function()
      assert(client.init())
      local lrucache = client.getcache()
      local entry_a = {
        {
          type = client.TYPE_A,
          address = "1.2.3.4",
          class = 1,
          name = "a.record.test",
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10,
      }
      local entry_srv = {
        {
          type = client.TYPE_SRV,
          target = "a.record.test",
          port = 8001,
          weight = 5,
          priority = 20,
          class = 1,
          name = "srv.record.test",
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10,
      }
      -- insert in the cache
      lrucache:set(entry_a[1].type..":"..entry_a[1].name, entry_a)
      lrucache:set(entry_srv[1].type..":"..entry_srv[1].name, entry_srv)
      local ip, port
      local host = "a.record.test"
      ip,port = client.toip(host)
      assert.is_string(ip)
      assert.is_nil(port)

      ip, port = client.toip(host, 1234)
      assert.is_string(ip)
      assert.equal(1234, port)

      host = "srv.record.test"
      ip, port = client.toip(host)
      assert.is_string(ip)
      assert.is_number(port)

      ip, port = client.toip(host, 0)
      assert.is_string(ip)
      assert.is_number(port)
      assert.is_not.equal(0, port)
    end)

    it("port passing if SRV port=0",function()
      assert(client.init({ search = {}, }))
      local ip, port, host

      host = "srvport0."..TEST_DOMAIN
      ip, port = client.toip(host, 10)
      assert.is_string(ip)
      assert.is_number(port)
      assert.is_equal(10, port)

      ip, port = client.toip(host)
      assert.is_string(ip)
      assert.is_nil(port)
    end)

    it("recursive SRV pointing to itself",function()
      assert(client.init({ search = {}, }))
      local ip, record, port, host, err, _
      host = "srvrecurse."..TEST_DOMAIN

      -- resolve SRV specific should return the record including its
      -- recursive entry
      record, err, _ = client.resolve(host, { qtype = client.TYPE_SRV })
      assert.is_table(record)
      assert.equal(1, #record)
      assert.equal(host, record[1].target)
      assert.equal(host, record[1].name)
      assert.is_nil(err)

      -- default order, SRV, A; the recursive SRV record fails, and it falls
      -- back to the IP4 address
      ip, port, _ = client.toip(host)
      assert.is_string(ip)
      assert.is_equal("10.0.0.44", ip)
      assert.is_nil(port)
    end)
    it("resolving in correct record-type order",function()
      local function config()
        -- function to insert 2 records in the cache
        local A_entry = {
          {
            type = client.TYPE_A,
            address = "5.6.7.8",
            class = 1,
            name = "hello.world",
            ttl = 10,
          },
          touch = 0,
          expire = gettime()+10,  -- active
        }
        local AAAA_entry = {
          {
            type = client.TYPE_AAAA,
            address = "::1",
            class = 1,
            name = "hello.world",
            ttl = 10,
          },
          touch = 0,
          expire = gettime()+10,  -- active
        }
        -- insert in the cache
        local lrucache = client.getcache()
        lrucache:set(A_entry[1].type..":"..A_entry[1].name, A_entry)
        lrucache:set(AAAA_entry[1].type..":"..AAAA_entry[1].name, AAAA_entry)
      end
      assert(client.init({order = {"AAAA", "A"}}))
      config()
      local ip = client.toip("hello.world")
      assert.equals(ip, "::1")
      assert(client.init({order = {"A", "AAAA"}}))
      config()
      ip = client.toip("hello.world")
      assert.equals(ip, "5.6.7.8")
    end)
    it("handling of empty responses", function()
      assert(client.init())
      local empty_entry = {
        touch = 0,
        expire = 0,
      }
      -- insert in the cache
      client.getcache()[client.TYPE_A..":".."hello.world"] = empty_entry

      -- Note: the bad case would be that the below lookup would hang due to round-robin on an empty table
      local ip, port = client.toip("hello.world", 123, true)
      assert.is_nil(ip)
      assert.is.string(port)  -- error message
    end)
    it("recursive lookups failure", function()
      assert(client.init({
            resolvConf = {
              -- resolv.conf without `search` and `domain` options
              "nameserver 198.51.100.0",
            },
          }))
      local lrucache = client.getcache()
      local entry1 = {
        {
          type = client.TYPE_CNAME,
          cname = "bye.bye.world",
          class = 1,
          name = "hello.world",
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10, -- active
      }
      local entry2 = {
        {
          type = client.TYPE_CNAME,
          cname = "hello.world",
          class = 1,
          name = "bye.bye.world",
          ttl = 10,
        },
        touch = 0,
        expire = gettime()+10, -- active
      }
      -- insert in the cache
      lrucache:set(entry1[1].type..":"..entry1[1].name, entry1)
      lrucache:set(entry2[1].type..":"..entry2[1].name, entry2)

      -- Note: the bad case would be that the below lookup would hang due to round-robin on an empty table
      local ip, port, _ = client.toip("hello.world", 123, true)
      assert.is_nil(ip)
      assert.are.equal("recursion detected", port)
    end)

    it("individual_toip - force no sync", function()
      local resolve_count = 10
      assert(client.init({
        noSynchronisation = false,
        order = { "A" },
        search = {},
      }))

      local callcount = 0
      resolver.query_func = function(self, original_query_func, name, options)
        callcount = callcount + 1
        -- Introducing a simulated network delay ensures individual_toip always
        -- triggers a DNS query to avoid it triggering only once due to a cache
        -- hit. 0.1 second is enough.
        ngx.sleep(0.1)
        return {{ type = client.TYPE_A, address = "1.1.1.1", class = 1, name = name, ttl = 10 } }
      end

      -- assert synchronisation is working
      local threads = {}
      for i=1,resolve_count do
        threads[i] = ngx.thread.spawn(function()
          local ip = client.toip("toip.com")
          assert.is_string(ip)
        end)
      end

      for i=1,#threads do
        ngx.thread.wait(threads[i])
      end

      -- only one thread must have called the query_func
      assert.are.equal(1, callcount,
        "synchronisation failed - out of " .. resolve_count .. " toip() calls " .. callcount ..
        " queries were made")

      callcount = 0
      threads = {}
      for i=1,resolve_count do
        threads[i] = ngx.thread.spawn(function()
          local ip = client.individual_toip("individual_toip.com")
          assert.is_string(ip)
        end)
      end

      for i=1,#threads do
        ngx.thread.wait(threads[i])
      end

      -- all threads must have called the query_func
      assert.are.equal(resolve_count, callcount,
        "force no sync failed - out of " .. resolve_count .. " toip() calls" ..
        callcount .. " queries were made")

    end)

  end)


  it("verifies validTtl", function()
    local validTtl = 0.1
    local emptyTtl = 0.1
    local staleTtl = 0.1
    local qname = "konghq.com"
    assert(client.init({
          emptyTtl = emptyTtl,
          staleTtl = staleTtl,
          validTtl = validTtl,
          resolvConf = {
            -- resolv.conf without `search` and `domain` options
            "nameserver 198.51.100.0",
          },
        }))

    -- mock query function to return a default record
    resolver.query_func = function(self, original_query_func, name, options)
      return  {
                {
                  type = client.TYPE_A,
                  address = "5.6.7.8",
                  class = 1,
                  name = qname,
                  ttl = 10,   -- should be overridden by the validTtl setting
                },
              }
    end

    -- do a query
    local res1, _, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )

    assert.equal(validTtl, res1[1].ttl)
    assert.is_near(validTtl, res1.expire - gettime(), 0.1)
  end)

  it("verifies ttl and caching of empty responses and name errors", function()
    --empty/error responses should be cached for a configurable time
    local emptyTtl = 0.1
    local staleTtl = 0.1
    local qname = "really.really.really.does.not.exist."..TEST_DOMAIN
    assert(client.init({
          emptyTtl = emptyTtl,
          staleTtl = staleTtl,
          -- don't supply resolvConf and fallback to default resolver
          -- so that CI and docker can have reliable results
          -- but remove `search` and `domain`
          search = {},
        }))

    -- mock query function to count calls
    local call_count = 0
    resolver.query_func = function(self, original_query_func, name, options)
      call_count = call_count + 1
      return original_query_func(self, name, options)
    end


    -- make a first request, populating the cache
    local res1, res2, err1, err2, _
    res1, err1, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res1)
    assert.are.equal(1, call_count)
    assert.are.equal(NOT_FOUND_ERROR, err1)
    res1 = assert(client.getcache():get(client.TYPE_A..":"..qname))


    -- make a second request, result from cache, still called only once
    res2, err2, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res2)
    assert.are.equal(1, call_count)
    assert.are.equal(NOT_FOUND_ERROR, err2)
    res2 = assert(client.getcache():get(client.TYPE_A..":"..qname))
    assert.equal(res1, res2)
    assert.falsy(res2.expired)


    -- wait for expiry of Ttl and retry, still called only once
    sleep(emptyTtl+0.5 * staleTtl)
    res2, err2 = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res2)
    assert.are.equal(1, call_count)
    assert.are.equal(NOT_FOUND_ERROR, err2)
    res2 = assert(client.getcache():get(client.TYPE_A..":"..qname))
    assert.equal(res1, res2)
    assert.is_true(res2.expired)  -- by now, record is marked as expired


    -- wait for expiry of staleTtl and retry, should be called twice now
    sleep(0.75 * staleTtl)
    res2, err2 = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res2)
    assert.are.equal(2, call_count)
    assert.are.equal(NOT_FOUND_ERROR, err2)
    res2 = assert(client.getcache():get(client.TYPE_A..":"..qname))
    assert.not_equal(res1, res2)
    assert.falsy(res2.expired)  -- new record, not expired
  end)

  it("verifies ttl and caching of (other) dns errors", function()
    --empty responses should be cached for a configurable time
    local badTtl = 0.1
    local staleTtl = 0.1
    local qname = "realname.com"
    assert(client.init({
          badTtl = badTtl,
          staleTtl = staleTtl,
          resolvConf = {
            -- resolv.conf without `search` and `domain` options
            "nameserver 198.51.100.0",
          },
        }))

    -- mock query function to count calls, and return errors
    local call_count = 0
    resolver.query_func = function(self, original_query_func, name, options)
      call_count = call_count + 1
      return { errcode = 5, errstr = "refused" }
    end


    -- initial request to populate the cache
    local res1, res2, err1, err2, _
    res1, err1, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res1)
    assert.are.equal(1, call_count)
    assert.are.equal("dns server error: 5 refused", err1)
    res1 = assert(client.getcache():get(client.TYPE_A..":"..qname))


    -- try again, from cache, should still be called only once
    res2, err2, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res2)
    assert.are.equal(call_count, 1)
    assert.are.equal(err1, err2)
    res2 = assert(client.getcache():get(client.TYPE_A..":"..qname))
    assert.are.equal(res1, res2)
    assert.falsy(res1.expired)


    -- wait for expiry of ttl and retry, still 1 call, but now stale result
    sleep(badTtl + 0.5 * staleTtl)
    res2, err2, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res2)
    assert.are.equal(call_count, 1)
    assert.are.equal(err1, err2)
    res2 = assert(client.getcache():get(client.TYPE_A..":"..qname))
    assert.are.equal(res1, res2)
    assert.is_true(res2.expired)

    -- wait for expiry of staleTtl and retry, 2 calls, new result
    sleep(0.75 * staleTtl)
    res2, err2, _ = client.resolve(
      qname,
      { qtype = client.TYPE_A }
    )
    assert.is_nil(res2)
    assert.are.equal(call_count, 2)  -- 2 calls now
    assert.are.equal(err1, err2)
    res2 = assert(client.getcache():get(client.TYPE_A..":"..qname))
    assert.are_not.equal(res1, res2)  -- a new record
    assert.falsy(res2.expired)
  end)

  describe("verifies the polling of dns queries, retries, and wait times", function()

    it("simultaneous lookups are synchronized to 1 lookup", function()
      assert(client.init())
      local coros = {}
      local results = {}

      local call_count = 0
      resolver.query_func = function(self, original_query_func, name, options)
        call_count = call_count + 1
        sleep(0.5) -- make sure we take enough time so the other threads
        -- will be waiting behind this one
        return original_query_func(self, name, options)
      end

      -- we're going to schedule a whole bunch of queries, all of this
      -- function, which does the same lookup and stores the result
      local x = function()
        -- the function is ran when started. So we must immediately yield
        -- so the scheduler loop can first schedule them all before actually
        -- starting resolving
        coroutine.yield(coroutine.running())
        local result, _, _ = client.resolve(
                                TEST_DOMAIN,
                                { qtype = client.TYPE_A }
                              )
        table.insert(results, result)
      end

      -- schedule a bunch of the same lookups
      for _ = 1, 10 do
        local co = ngx.thread.spawn(x)
        table.insert(coros, co)
      end

      -- all scheduled and waiting to start due to the yielding done.
      -- now start them all
      for i = 1, #coros do
        ngx.thread.wait(coros[i]) -- this wait will resume the scheduled ones
      end

      -- now count the unique responses we got
      local counters = {}
      for _, r in ipairs(results) do
        r = tostring(r)
        counters[r] = (counters[r] or 0) + 1
      end
      local count = 0
      for _ in pairs(counters) do count = count + 1 end

      -- we should have a single result table, as all threads are supposed to
      -- return the exact same table.
      assert.equal(1,count)
    end)

    it("timeout while waiting", function()

      local timeout = 500
      local ip = "1.4.2.3"
      -- basically the local function _synchronized_query
      assert(client.init({
        timeout = timeout,
        retrans = 1,
        resolvConf = {
          -- resolv.conf without `search` and `domain` options
          "nameserver 198.51.100.0",
        },
      }))

      -- insert a stub thats waits and returns a fixed record
      local name = TEST_DOMAIN
      resolver.query_func = function()
        local ip = ip
        local entry = {
          {
            type = client.TYPE_A,
            address = ip,
            class = 1,
            name = name,
            ttl = 10,
          },
          touch = 0,
          expire = gettime() + 10,
        }
        -- wait before we return the results
        -- `+ 2` s ensures that the semaphore:wait() expires
        sleep(timeout/1000 + 2)
        return entry
      end

      local coros = {}
      local results = {}

      -- we're going to schedule a whole bunch of queries, all of this
      -- function, which does the same lookup and stores the result
      local x = function()
        -- the function is ran when started. So we must immediately yield
        -- so the scheduler loop can first schedule them all before actually
        -- starting resolving
        coroutine.yield(coroutine.running())
        local result, err, _ = client.resolve(name, {qtype = client.TYPE_A})
        table.insert(results, (result or err))
      end

      -- schedule a bunch of the same lookups
      for _ = 1, 10 do
        local co = ngx.thread.spawn(x)
        table.insert(coros, co)
      end

      -- all scheduled and waiting to start due to the yielding done.
      -- now start them all
      for i = 1, #coros do
        ngx.thread.wait(coros[i]) -- this wait will resume the scheduled ones
      end

      -- results[1~9] are equal, as they all will wait for the first response
      for i = 1, 9 do
        assert.equal("timeout", results[i])
      end
      -- results[10] comes from synchronous DNS access of the first request
      assert.equal(ip, results[10][1]["address"])
    end)
  end)

  it("noSynchronisation == true, queries on each request", function()
    -- basically the local function _synchronized_query
    assert(client.init({
      resolvConf = {
        -- resolv.conf without `search` and `domain` options
        "nameserver 198.51.100.0",
      },
      noSynchronisation = true,
    }))

    -- insert a stub thats waits and returns a fixed record
    local call_count = 0
    local name = TEST_DOMAIN
    resolver.query_func = function()
      local ip = "1.4.2.3"
      local entry = {
        {
          type = client.TYPE_A,
          address = ip,
          class = 1,
          name = name,
          ttl = 10,
        },
        touch = 0,
        expire = gettime() + 10,
      }
      sleep(1) -- wait before we return the results
      call_count = call_count + 1
      return entry
    end

    local coros = {}

    -- we're going to schedule a whole bunch of queries, all of this
    -- function, which does the same lookup and stores the result
    local x = function()
      -- the function is ran when started. So we must immediately yield
      -- so the scheduler loop can first schedule them all before actually
      -- starting resolving
      coroutine.yield(coroutine.running())
      local _, _, _ = client.resolve(name, {qtype = client.TYPE_A})
    end

    -- schedule a bunch of the same lookups
    for _ = 1, 10 do
      local co = ngx.thread.spawn(x)
      table.insert(coros, co)
    end

    -- all scheduled and waiting to start due to the yielding done.
    -- now start them all
    for i = 1, #coros do
      ngx.thread.wait(coros[i]) -- this wait will resume the scheduled ones
    end

    -- all results are unique, each call got its own query
    assert.equal(call_count, 10)
  end)

  it("disable additional section when querying", function()

    local function build_dns_reply(id, name, ip, ns_ip1, ns_ip2)
      local function dns_encode_name(name)
        local parts = {}
        for part in string.gmatch(name, "[^.]+") do
          table.insert(parts, string.char(#part) .. part)
        end
        table.insert(parts, "\0")
        return table.concat(parts)
      end

      local function ip_to_bytes(ip)
        local bytes = { "\x00\x04" }  -- RDLENGTH:4bytes (ipv4)
        for octet in string.gmatch(ip, "%d+") do
          table.insert(bytes, string.char(tonumber(octet)))
        end
        return table.concat(bytes)
      end

      local package = {}

      -- Header
      package[#package+1] = id
      package[#package+1] = "\x85\x00"  -- QR, AA, RD
      package[#package+1] = "\x00\x01\x00\x01\x00\x00\x00\x02"  -- QD:1 AN:1 NS:0 AR:2

      -- Question
      package[#package+1] = dns_encode_name(name)
      package[#package+1] = "\x00\x01\x00\x01"  -- QTYPE A; QCLASS IN

      -- Answer
      package[#package+1] = dns_encode_name(name)
      package[#package+1] = "\x00\x01\x00\x01\x00\x00\x00\x30"  -- QTYPE:A; QCLASS:IN TTL:48
      package[#package+1] = ip_to_bytes(ip)

      -- Additional
      local function add_additional(name, ip)
        package[#package+1] = dns_encode_name(name)
        package[#package+1] = "\x00\x01\x00\x01\x00\x00\x00\x30"  -- QTYPE:A; QCLASS:IN TTL:48
        package[#package+1] = ip_to_bytes(ip)
      end

      add_additional("ns1." .. name, ns_ip1)
      add_additional("ns2." .. name, ns_ip2)

      return table.concat(package)
    end

    local force_enable_additional_section = false

    -- dns client will ignore additional section
    resolver.query_func = function(self, original_query_func, name, options)
      if options.qtype ~= client.TYPE_A then
        return { errcode = 5, errstr = "refused" }
      end

      if force_enable_additional_section then
        options.additional_section = true
      end

      self.tcp_sock = nil -- disable TCP query

      local id
      local sock = assert(self.socks[1])
      -- hook send to get id
      local orig_sock_send = sock.send
      sock.send = function (self, query)
        id = query[1] ..  query[2]
        return orig_sock_send(self, query)
      end
      -- hook receive to reply raw data
      sock.receive = function (self, size)
        return build_dns_reply(id, name, "1.1.1.1", "2.2.2.2", "3.3.3.3")
      end

      return original_query_func(self, name, options)
    end

    local name = "additional-section.test"

    -- no additional_section by default
    assert(client.init({ search = {}, }))
    local answers = client.resolve(name)
    assert.equal(#answers, 1)
    assert.same(answers[1].address, "1.1.1.1")

    -- disable the additional_section option in r_opt
    assert(client.init({ search = {}, }))
    local answers = client.resolve(name, { additional_section = true })
    assert.equal(#answers, 1)
    assert.same(answers[1].address, "1.1.1.1")

    -- test the buggy scenario
    force_enable_additional_section = true
    assert(client.init({ search = {}, }))
    local answers = client.resolve(name)
    assert.equal(#answers, 3)
    assert.same(answers[1].address, "1.1.1.1")
    assert.same(answers[2].address, "2.2.2.2")
    assert.same(answers[3].address, "3.3.3.3")
  end)

end)
