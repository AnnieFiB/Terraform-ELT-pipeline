-- =========================================
-- File: sql/stg/api_311_raw.sql
-- Schema: stg
-- Purpose: Store raw JSON payloads from API or ADF Copy
-- =========================================

CREATE SCHEMA IF NOT EXISTS stg;

CREATE TABLE IF NOT EXISTS stg.api_311_raw (
  id         bigserial PRIMARY KEY,
  src_file   text,                               -- optional: blob path/file
  payload    jsonb NOT NULL,                     -- JSON array of 311 records
  ingest_ts  timestamptz NOT NULL DEFAULT now()
);

-- Index for time-based processing
CREATE INDEX IF NOT EXISTS ix_api_311_raw_ingest_ts 
  ON stg.api_311_raw (ingest_ts DESC);

-- Note: Further processing to unnest JSON array into normalized tables will be handled in subsequent transformations.    
-- This table serves as the initial landing zone for raw data ingestion.
-- Ensure appropriate permissions are granted to ETL service principals as needed.
-- End of file: sql/stg/api_311_raw.sql

