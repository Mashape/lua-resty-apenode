return {
  postgres = {
    up = [[
      DO $$
      BEGIN
      ALTER TABLE IF EXISTS ONLY "clustering_data_planes" ADD "labels" JSONB;
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END;
      $$;
    ]]
  }
}
