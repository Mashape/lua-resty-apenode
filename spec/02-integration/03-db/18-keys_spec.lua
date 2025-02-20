local helpers = require "spec.helpers"
local cjson = require "cjson"
local merge = kong.table.merge
local fmt = string.format


for _, strategy in helpers.all_strategies() do
  describe("db.keys #" .. strategy, function()
    local init_key_set, key_set2, init_pem_key, pem_pub, pem_priv, jwk
    local bp, db

    lazy_setup(function()
      helpers.setenv("JWK_SECRET", "wowsuchsecret")

      bp, db = helpers.get_db_utils(strategy ~= "off" and strategy or nil, {
        "vaults",
        "keys",
        "key_sets"
      })

      init_key_set = assert(bp.key_sets:insert {
        name = "testset",
      })

      key_set2 = assert(bp.key_sets:insert {
        name = "testset2"
      })

      local jwk_pub, jwk_priv = helpers.generate_keys("JWK")
      pem_pub, pem_priv = helpers.generate_keys("PEM")

      jwk = merge(cjson.decode(jwk_pub), cjson.decode(jwk_priv))
    end)

    after_each(function()
      db:truncate("keys")
    end)

    lazy_teardown(function()
      db:truncate("key_sets")
    end)

    it(":select returns an item [jwk]", function()
      local key, err = assert(bp.keys:insert {
        name = "testjwk",
        set = init_key_set,
        kid = jwk.kid,
        jwk = cjson.encode(jwk)
      })
      assert(key)
      assert.is_nil(err)
      local key_o, s_err = db.keys:select(key)
      assert.is_nil(s_err)
      assert.same("string", type(key_o.jwk))
    end)

    it(":select returns an item [pem]", function()
      init_pem_key = assert(bp.keys:insert {
        name = "testpem",
        set = init_key_set,
        kid = "456",
        pem = {
          public_key = pem_pub,
          private_key = pem_priv
        }
      })
      local key_o, err = db.keys:select(init_pem_key)
      assert.is_nil(err)
      assert.same('456', key_o.kid)
      assert.same(pem_priv, key_o.pem.private_key)
      assert.same(pem_pub, key_o.pem.public_key)
    end)

    it(":cache_key", function()
      local cache_key, err = db.keys:cache_key({kid = "456", set = {id = init_key_set.id}})
      assert.is_nil(err)
      assert.equal(fmt("keys:456:%s", init_key_set.id), cache_key)
    end)

    it(":cache_key no set present", function()
      local cache_key, err = db.keys:cache_key({kid = "123"})
      assert.is_nil(err)
      assert.equal("keys:123:", cache_key)
    end)

    it(":cache_key invalid set type", function()
      local cache_key, err = db.keys:cache_key({kid = "123", set = ""})
      assert.is_nil(err)
      assert.equal("keys:123:", cache_key)
    end)

    it(":cache_key must handle missing id field", function()
      local cache_key, err = db.keys:cache_key({kid = "123", set = { }})
      assert.is_nil(err)
      assert.equal("keys:123:", cache_key)
    end)

    it(":insert handles field vault references ", function()
      local reference = "{vault://env/jwk_secret}"
      local ref, insert_err = db.keys:insert {
        name = "vault references",
        set = init_key_set,
        kid = "1",
        jwk = reference
      }
      assert.is_nil(insert_err)
      assert.same(ref["$refs"]["jwk"], reference)
      assert.same(ref.jwk, "wowsuchsecret")
    end)

    it(":insert handles field private_key when passing a vault reference", function()
      local reference = "{vault://env/jwk_secret}"
      local ref, insert_err = db.keys:insert {
        name = "vault references",
        set = init_key_set,
        kid = "1",
        pem = { private_key = reference, public_key = pem_pub }
      }
      assert.is_nil(insert_err)
      assert.same(ref.pem["$refs"]["private_key"], reference)
      assert.same(ref.pem["private_key"], "wowsuchsecret")
    end)

    it(":insert handles field public_key when passing a vault reference", function()
      local reference = "{vault://env/jwk_secret}"
      local ref, insert_err = db.keys:insert {
        name = "vault references",
        set = init_key_set,
        kid = "1",
        pem = { private_key = pem_priv, public_key = reference}
      }
      assert.is_nil(insert_err)
      assert.same(ref.pem["$refs"]["public_key"], reference)
      assert.same(ref.pem["public_key"], "wowsuchsecret")
    end)

    it("kid is unique accross sets", function()
      local test2, err = db.key_sets:insert {
        name = "test2"
      }
      assert.is_nil(err)
      assert.is_not_nil(test2)
      local key, insert_err = db.keys:insert {
        name = "each_test",
        set = init_key_set,
        kid = "999",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(insert_err)
      assert.is_not_nil(key)
      -- inserting a key with the same kid in a different keyset.
      -- this should not raise a validation error
      local key2, insert2_err = db.keys:insert {
        name = "each_test_1",
        set = test2,
        kid = "999",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(insert2_err)
      assert.is_not_nil(key2)
    end)


    it(":get_pubkey and :get_privkey [pem]", function()
      local pem_t, err = db.keys:insert {
        name = "pem_key",
        set = init_key_set,
        kid = "999",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(err)
      assert(pem_t)

      local pem_pub_t, g_err = db.keys:get_pubkey(pem_t)
      assert.is_nil(g_err)
      assert.matches("-----BEGIN PUBLIC KEY", pem_pub_t)

      local pem_priv, p_err = db.keys:get_privkey(pem_t)
      assert.is_nil(p_err)
      assert.matches("-----BEGIN PRIVATE KEY", pem_priv)
    end)

    it(":get_pubkey and :get_privkey [jwk]", function()
      local jwk_t, _ = db.keys:insert {
        name = "jwk_key",
        set = init_key_set,
        kid = jwk.kid,
        jwk = cjson.encode(jwk)
      }
      assert(jwk_t)

      local jwk_pub, err = db.keys:get_pubkey(jwk_t)
      assert.is_nil(err)
      local jwk_pub_o = cjson.decode(jwk_pub)
      assert.is_not_nil(jwk_pub_o.e)
      assert.is_not_nil(jwk_pub_o.kid)
      assert.is_not_nil(jwk_pub_o.kty)
      assert.is_not_nil(jwk_pub_o.n)

      local jwk_priv, err_t = db.keys:get_privkey(jwk_t)
      local decoded_jwk = cjson.decode(jwk_priv)
      assert.is_nil(err_t)
      assert.is_not_nil(decoded_jwk.kid)
      assert.is_not_nil(decoded_jwk.kty)
      assert.is_not_nil(decoded_jwk.d)
      assert.is_not_nil(decoded_jwk.dp)
      assert.is_not_nil(decoded_jwk.dq)
      assert.is_not_nil(decoded_jwk.e)
      assert.is_not_nil(decoded_jwk.n)
      assert.is_not_nil(decoded_jwk.p)
      assert.is_not_nil(decoded_jwk.q)
      assert.is_not_nil(decoded_jwk.qi)
    end)

    it(":get_privkey errors if only got pubkey [pem]", function()
      local pem_t, err = db.keys:insert {
        name = "pem_key",
        set = init_key_set,
        kid = "999",
        pem = { public_key = pem_pub }
      }
      assert.is_nil(err)
      assert(pem_t)

      local pem_pub_t, g_err = db.keys:get_pubkey(pem_t)
      assert.is_nil(g_err)
      assert.matches("-----BEGIN PUBLIC KEY", pem_pub_t)

      local pem_priv, p_err = db.keys:get_privkey(pem_t)
      assert.is_nil(pem_priv)
      assert.matches("could not load a private key from public key material", p_err)
    end)

    it(":get_privkey errors if only got pubkey [jwk]", function()
      jwk.d = nil
      local jwk_t, _ = db.keys:insert {
        name = "jwk_key",
        set = init_key_set,
        kid = jwk.kid,
        jwk = cjson.encode(jwk)
      }
      assert(jwk_t)

      local jwk_pub_t, g_err = db.keys:get_pubkey(jwk_t)
      assert.is_nil(g_err)
      local jwk_pub_o = cjson.decode(jwk_pub_t)
      assert.is_not_nil(jwk_pub_o.e)
      assert.is_not_nil(jwk_pub_o.kid)
      assert.is_not_nil(jwk_pub_o.kty)
      assert.is_not_nil(jwk_pub_o.n)

      local jwk_priv, p_err = db.keys:get_privkey(jwk_t)
      assert.is_nil(jwk_priv)
      assert.matches("could not load a private key from public key material", p_err)
    end)

    it(":insert key with x5t", function()
      local key, err = db.keys:insert {
        name = "insert_key1",
        set = init_key_set,
        kid = "insert_kid1",
        x5t = "insert_x5t1",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(err)
      assert(key)

      key, err = db.keys:insert({
        name = "insert_key2",
        set = init_key_set,
        kid = "insert_kid2",
        x5t = "insert_x5t1",
        pem = { private_key = pem_priv, public_key = pem_pub }
      })
      assert.is_nil(key)
      assert.matches("violation on", err)

      key, err = db.keys:insert {
        name = "insert_key3",
        set = key_set2,
        kid = "insert_kid3",
        x5t = "insert_x5t1",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(err)
      assert(key)

      -- x5t should be unique even when set is not specified
      local key, err = db.keys:insert {
        name = "insert_key4",
        kid = "insert_kid1",
        x5t = "insert_x5t1",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(err)
      assert(key)

      key, err = db.keys:insert({
        name = "insert_key5",
        kid = "insert_kid2",
        x5t = "insert_x5t1",   -- unique voilation
        pem = { private_key = pem_priv, public_key = pem_pub }
      })
      assert.is_nil(key)
      assert.matches("violation on", err)
    end)

    it(":select key by x5t", function()
      local key, err = db.keys:insert {
        name = "select_key1",
        set = init_key_set,
        kid = "select_kid1",
        x5t = "select_x5t1",
        pem = { private_key = pem_priv, public_key = pem_pub }
      }
      assert.is_nil(err)
      assert(key)

      local key2, err2 = db.keys:select_by_x5t_set_id("select_x5t1", init_key_set.id)
      assert.is_nil(err2)
      assert.same("select_key1", key2.name)
      assert.same("select_x5t1", key2.x5t)

      local key3, err3 = db.keys:select_by_x5t_set_id("select_x5t1", key_set2.id)  -- inexistent
      assert.is_nil(err3)
      assert.is_nil(key3)

      local key4, err4 = db.keys:select_by_x5t_set_id("select_x5t1")  -- inexistent
      assert.is_nil(err4)
      assert.is_nil(key4)
    end)
  end)
end
