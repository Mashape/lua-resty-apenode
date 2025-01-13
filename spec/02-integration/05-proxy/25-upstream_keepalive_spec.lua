local helpers = require "spec.helpers"
local ssl_fixtures = require "spec.fixtures.ssl"


local fixtures = {
  http_mock = {
    upstream_mtls = [[
      server {
          listen 16798 ssl;

          ssl_certificate        ../spec/fixtures/mtls_certs/example.com.crt;
          ssl_certificate_key    ../spec/fixtures/mtls_certs/example.com.key;
          ssl_client_certificate ../spec/fixtures/mtls_certs/ca.crt;
          ssl_verify_client      on;
          ssl_session_tickets    off;
          ssl_session_cache      off;
          keepalive_requests     10;

          location = / {
              echo '$ssl_client_fingerprint';
          }
      }
  ]]
  },
}


describe("#postgres upstream keepalive", function()
  local proxy_client
  local ca_certificate, client_cert1, client_cert2

  local function start_kong(opts)
    local kopts = {
      log_level  = "debug",
      database   = "postgres",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }

    for k, v in pairs(opts or {}) do
      kopts[k] = v
    end

    helpers.clean_logfile()

    assert(helpers.start_kong(kopts, nil, nil, fixtures))

    proxy_client = helpers.proxy_client()
  end

  lazy_setup(function()
    local bp = helpers.get_db_utils("postgres", {
      "routes",
      "services",
      "certificates",
      "ca_certificates",
    })

    ca_certificate = assert(bp.ca_certificates:insert({
      cert = ssl_fixtures.cert_ca,
    }))

    client_cert1 = bp.certificates:insert {
      cert = ssl_fixtures.cert_client,
      key = ssl_fixtures.key_client,
    }

    client_cert2 = bp.certificates:insert {
      cert = ssl_fixtures.cert_client2,
      key = ssl_fixtures.key_client2,
    }

    -- upstream TLS
    bp.routes:insert {
      hosts = { "one.test" },
      preserve_host = true,
      service = bp.services:insert {
        protocol = helpers.mock_upstream_ssl_protocol,
        host = helpers.mock_upstream_hostname,
        port = helpers.mock_upstream_ssl_port,
        tls_verify = false,
        tls_verify_depth = 3,
        ca_certificates = { ca_certificate.id },
      },
    }

    bp.routes:insert {
      hosts = { "two.test" },
      preserve_host = true,
      service = bp.services:insert {
        protocol = helpers.mock_upstream_ssl_protocol,
        host = helpers.mock_upstream_hostname,
        port = helpers.mock_upstream_ssl_port,
        tls_verify = false,
        tls_verify_depth = 3,
        ca_certificates = { ca_certificate.id },
      },
    }

    -- crc32 collision upstream TLS
    bp.routes:insert {
      hosts = { "plumless.xxx" },
      preserve_host = true,
      service = bp.services:insert {
        protocol = helpers.mock_upstream_ssl_protocol,
        host = helpers.mock_upstream_hostname,
        port = helpers.mock_upstream_ssl_port,
      },
    }

    bp.routes:insert {
      hosts = { "buckeroo.xxx" },
      preserve_host = true,
      service = bp.services:insert {
        protocol = helpers.mock_upstream_ssl_protocol,
        host = helpers.mock_upstream_hostname,
        port = helpers.mock_upstream_ssl_port,
      },
    }

    -- upstream mTLS
    bp.routes:insert {
      hosts = { "example.test", },
      service = bp.services:insert {
        url = "https://127.0.0.1:16798/",
        client_certificate = client_cert1,
        tls_verify = false,
        tls_verify_depth = 3,
        ca_certificates = { ca_certificate.id },
      },
    }

    bp.routes:insert {
      hosts = { "example2.test", },
      service = bp.services:insert {
        url = "https://127.0.0.1:16798/",
        client_certificate = client_cert2,
        tls_verify = false,
        tls_verify_depth = 3,
        ca_certificates = { ca_certificate.id },
      },
    }
  end)


  after_each(function()
    if proxy_client then
      proxy_client:close()
    end

    helpers.stop_kong()
  end)


  it("pools by host|port|sni when upstream is https", function()
    start_kong()

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "one.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=one.test", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                ca_certificate.id .. "|")

    assert.errlog()
          .has.line([[keepalive get pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, cpool: 0+]])
    assert.errlog()
          .has.line([[keepalive create pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, size: \d+]])
    assert.errlog()
          .has.line([[lua balancer: keepalive no free connection, cpool: [A-F0-9]+]])
    assert.errlog()
          .has.line([[lua balancer: keepalive saving connection [A-F0-9]+, cpool: [A-F0-9]+]])
    assert.errlog()
          .not_has.line([[keepalive free pool]], true)

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "two.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=two.test", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|two.test|false|3|]] ..
                ca_certificate.id .. "|")

    assert.errlog()
          .has.line([[keepalive get pool, name: [A-F0-9.:]+\|\d+\|two.test|false|3|]] ..
                    ca_certificate.id .. [[|, cpool: 0+]])
    assert.errlog()
          .has.line([[keepalive create pool, name: [A-F0-9.:]+\|\d+\|two.test|false|3|]] ..
                    ca_certificate.id .. [[|, size: \d+]])
    assert.errlog()
          .has.line([[lua balancer: keepalive no free connection, cpool: [A-F0-9]+]])
    assert.errlog()
          .has.line([[lua balancer: keepalive saving connection [A-F0-9]+, cpool: [A-F0-9]+]])
    assert.errlog()
          .not_has.line([[keepalive free pool]], true)

    local handle, result

    handle = io.popen([[grep 'cpool: 0000000000' servroot/logs/error.log|wc -l]])
    result = handle:read("*l")
    handle:close()
    assert(tonumber(result) == 2)

    handle = io.popen([[grep 'keepalive create pool, name:' servroot/logs/error.log|wc -l]])
    result = handle:read("*l")
    handle:close()
    assert(tonumber(result) == 2)

    handle = io.popen([[grep 'lua balancer: keepalive saving connection' servroot/logs/error.log|wc -l]])
    result = handle:read("*l")
    handle:close()
    assert(tonumber(result) == 2)
  end)


  it("pools by host|port|sni|client_cert_id when upstream requires mTLS", function()
    start_kong()

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/",
      headers = {
        Host = "example.test",
      }
    })
    local fingerprint_1 = assert.res_status(200, res)
    assert.not_equal("", fingerprint_1)

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/",
      headers = {
        Host = "example2.test",
      }
    })
    local fingerprint_2 = assert.res_status(200, res)
    assert.not_equal("", fingerprint_2)

    assert.not_equal(fingerprint_1, fingerprint_2)

    assert.errlog()
          .has.line([[enabled connection keepalive \(pool=[0-9.]+|\d+|[0-9.]+:\d+|[a-f0-9-]+|false|3|]] ..
                    ca_certificate.id .. "|" .. client_cert1.id)
    assert.errlog()
          .has.line([[keepalive get pool, name: [0-9.]+|\d+|[0-9.]+:\d+|[a-f0-9-]+|false|3|]] ..
                    ca_certificate.id .. "|" .. client_cert1.id .. [[, cpool: 0+]])
    assert.errlog()
          .has.line([[keepalive create pool, name: [0-9.]+|\d+|[0-9.]+:\d+|[a-f0-9-]+, size: \d+]])
    assert.errlog()
          .has.line([[lua balancer: keepalive no free connection, cpool: [A-F0-9]+]])
    assert.errlog()
          .has.line([[lua balancer: keepalive saving connection [A-F0-9]+, cpool: [A-F0-9]+]])

    assert.errlog()
          .not_has.line([[keepalive free pool]], true)
  end)


  it("upstream_keepalive_pool_size = 0 disables connection pooling", function()
    start_kong({
      upstream_keepalive_pool_size = 0,
    })

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "one.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=one.test", body)
    assert.errlog()
          .not_has
          .line("enabled connection keepalive", true)

    assert.errlog()
          .not_has.line([[keepalive get pool]], true)
    assert.errlog()
          .not_has.line([[keepalive create pool]], true)

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "two.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=two.test", body)
    assert.errlog()
          .not_has
          .line("enabled connection keepalive", true)

    assert.errlog()
          .not_has.line([[keepalive get pool]], true)
    assert.errlog()
          .not_has.line([[keepalive create pool]], true)
    assert.errlog()
          .not_has.line([[keepalive free pool]], true)
  end)


  it("reuse upstream keepalive pool", function()
    start_kong()

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "one.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=one.test", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                ca_certificate.id .. "|")

    assert.errlog()
          .has.line([[keepalive get pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, cpool: 0+]])
    assert.errlog()
          .has.line([[keepalive create pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, size: \d+]])
    assert.errlog()
          .has.line([[keepalive no free connection, cpool: [A-F0-9]+]])
    assert.errlog()
          .has.line([[keepalive saving connection [A-F0-9]+, cpool: [A-F0-9]+]])
    assert.errlog()
          .not_has.line([[keepalive free pool]], true)

    local handle, upool_ptr

    handle = io.popen([[grep 'lua balancer: keepalive saving connection' servroot/logs/error.log]] .. "|" ..
                      [[grep -Eo 'cpool: [A-F0-9]+']])
    upool_ptr = handle:read("*l")
    handle:close()

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "one.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=one.test", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                ca_certificate.id .. "|")

    assert.errlog()
          .has.line([[keepalive get pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, ]] .. upool_ptr)
    assert.errlog()
          .has.line([[keepalive reusing connection [A-F0-9]+, requests: \d+, ]] .. upool_ptr)
    assert.errlog()
          .has.line([[keepalive saving connection [A-F0-9]+, ]] .. upool_ptr)
    assert.errlog()
          .not_has.line([[keepalive free pool]], true)
  end)


  it("free upstream keepalive pool", function()
    start_kong({ upstream_keepalive_max_requests = 1, })

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "one.test",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=one.test", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                ca_certificate.id .. "|")

    assert.errlog()
          .has.line([[keepalive get pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, cpool: 0+]])
    assert.errlog()
          .has.line([[keepalive create pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, size: \d+]])
    assert.errlog()
          .has.line([[keepalive no free connection, cpool: [A-F0-9]+]])
    assert.errlog()
          .has.line([[keepalive not saving connection [A-F0-9]+, cpool: [A-F0-9]+]])
    assert.errlog()
          .has.line([[keepalive free pool, name: [A-F0-9.:]+\|\d+\|one.test|false|3|]] ..
                    ca_certificate.id .. [[|, cpool: [A-F0-9]+]])

    assert.errlog()
          .not_has.line([[keepalive saving connection]], true)
  end)


  -- ensure same crc32 names don't hit same keepalive pool
  it("pools with crc32 collision", function()
    start_kong()

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "plumless.xxx",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=plumless.xxx", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|plumless.xxx]])

    local res = assert(proxy_client:send {
      method = "GET",
      path = "/echo_sni",
      headers = {
        Host = "buckeroo.xxx",
      }
    })
    local body = assert.res_status(200, res)
    assert.equal("SNI=buckeroo.xxx", body)
    assert.errlog()
          .has
          .line([[enabled connection keepalive \(pool=[A-F0-9.:]+\|\d+\|buckeroo.xxx]])

    local handle

    handle = io.popen([[grep 'enabled connection keepalive ' servroot/logs/error.log]] .. "|" ..
                      [[grep -Eo 'pool=[A-F0-9.:]+\|\d+\|plumless.xxx']])
    local name1 = handle:read("*l")
    handle:close()

    handle = io.popen([[grep 'enabled connection keepalive ' servroot/logs/error.log]] .. "|" ..
                      [[grep -Eo 'pool=[A-F0-9.:]+\|\d+\|buckeroo.xxx']])
    local name2 = handle:read("*l")
    handle:close()

    local crc1 = ngx.crc32_long(name1)
    local crc2 = ngx.crc32_long(name2)
    assert.equal(crc1, crc2)

    handle = io.popen([[grep 'lua balancer: keepalive saving connection' servroot/logs/error.log]] .. "|" ..
                      [[grep -Eo 'cpool: [A-F0-9]+']])
    local upool_ptr1 = handle:read("*l")
    local upool_ptr2 = handle:read("*l")
    handle:close()

    assert.not_equal(upool_ptr1, upool_ptr2)
  end)


end)
