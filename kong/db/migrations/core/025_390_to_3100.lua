--- XXX CE [[
--- We don't need this in EE because an identical migration step is already existed.
return {
  postgres = {
    up = [[
      DO $$
      BEGIN
      DROP TABLE IF EXISTS clustering_sync_delta;
      DROP INDEX IF EXISTS clustering_sync_delta_version_idx;
      END;
      $$;

      DO $$
        DECLARE
          db_version INTEGER;
          seq_name TEXT;
        BEGIN
          -- Altering version serial and delta version to BIGINT
          -- The max value of them will be 2^63 - 1 = 9223372036854775807
          -- If we insert one delta per millisecond, it will take 290 million
          -- years to exhaust.
          SELECT current_setting('server_version_num')::integer / 10000 INTO db_version;
          SELECT pg_get_serial_sequence('clustering_sync_version', 'version') INTO seq_name;
          IF db_version > 9 THEN
            -- In PostgreSQL 10 and above, we need to alter the sequence to BIGINT
            -- Therefore, we can set the max value according to BIGINT
            EXECUTE 'ALTER SEQUENCE ' || seq_name || ' AS BIGINT NO MAXVALUE';
          ELSE
            -- In PostgreSQL 9, altering with NO MAXVALUE will set it to 2^63-1
            EXECUTE 'ALTER SEQUENCE ' || seq_name || ' NO MAXVALUE';
          END IF;
          ALTER TABLE clustering_sync_version ALTER COLUMN version TYPE BIGINT USING version::BIGINT;
        END;
      $$;

      DO $$
          BEGIN
          ALTER TABLE IF EXISTS ONLY "keys" ADD "x5t" TEXT;
          ALTER TABLE IF EXISTS ONLY "keys" ADD CONSTRAINT "keys_x5t_set_id_unique" UNIQUE ("x5t", "set_id");
          CREATE UNIQUE INDEX IF NOT EXISTS "keys_x5t_with_null_set_id_idx" ON "keys" ("x5t") WHERE "set_id" IS NULL;
          EXCEPTION WHEN DUPLICATE_COLUMN THEN
          -- Do nothing, accept existing state
          END;
      $$;
    ]]
  }
}
--- XXX CE ]]
