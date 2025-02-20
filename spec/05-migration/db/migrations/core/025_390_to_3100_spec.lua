local uh = require "spec/upgrade_helpers"

describe("database migration", function()
  uh.old_after_up("does not have \"clustering_sync_delta\" table", function()
    assert.not_database_has_relation("clustering_sync_delta")
  end)

  uh.old_after_up("has created the expected new columns", function()
    assert.table_has_column("keys", "x5t", "text")
  end)
end)
