-- =========================================
-- SAMPLE STAGING DATA
-- Inserts from JSON file into staging- stg.api_311_raw
-- =========================================
-- Usage:
-- psql -h <host> -d <db> -U <user> -v json_path='sql/stg/data/sample_311.json' -f sql/stg/sample_insert.sql
-- =========================================

-- Allow overriding from CLI; otherwise default path:
\if :{?json_path}
\else
  \set json_path 'sql/stg/data/sample_311.json'
\endif

\echo Loading JSON data from: :json_path

-- Read file into a psql variable; strip CR (\r) to keep JSON valid on Windows.
\set content `cat :json_path | tr -d '\r'`

-- Use quoted variables for text literals (:'var')
INSERT INTO stg.api_311_raw (src_file, payload)
VALUES (
  :'json_path',
  :'content'::jsonb
);

-- Verify
SELECT id, src_file, jsonb_array_length(payload) AS record_count, ingest_ts
FROM stg.api_311_raw
ORDER BY ingest_ts DESC
LIMIT 5;
-- End of sample_insert.sql