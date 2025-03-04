local uh = require "spec/upgrade_helpers"

describe("database migration", function()
  uh.old_after_up("does not have \"clustering_sync_delta\" table", function()
    assert.not_database_has_relation("clustering_sync_delta")
  end)

  uh.old_after_up("has altered version to big integer", function()
    assert.table_has_column("clustering_sync_version", "version", "bigint")

    local db = uh.get_database()
    local connector = db.connector
    local seq_name = assert(connector:query([[
      SELECT pg_get_serial_sequence('clustering_sync_version', 'version') AS seq_name;
    ]]))[1].seq_name

    local max_value
    if db.connector.major_version >= 10 then
      max_value = assert(connector:query(string.format([[
        SELECT seqmax FROM pg_sequence WHERE seqrelid = '%s'::regclass;
      ]], seq_name)))[1].seqmax
    else
      max_value = assert(connector:query(string.format([[
        SELECT max_value from public.clustering_sync_version_version_seq;
      ]], seq_name)))[1].max_value
    end

    assert.is.equal(max_value, 9223372036854775807)
  end)

  uh.old_after_up("has created the expected new columns", function()
    assert.table_has_column("keys", "x5t", "text")
  end)
end)
