return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS "custom_auth_table" (
        "id"             UUID                         PRIMARY KEY,
        "created_at"     TIMESTAMP WITH TIME ZONE     DEFAULT (CURRENT_TIMESTAMP(0) AT TIME ZONE 'UTC'),
        "ttl"            TIMESTAMP WITH TIME ZONE,
        "expire_at"      TIMESTAMP WITH TIME ZONE,
        "key"            TEXT                         UNIQUE,
        "forward_token"  TEXT
      );

      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS "custom_auth_table_key_idx"
                                ON "custom_auth_table" ("key");
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  }
}

