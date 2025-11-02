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

-- =========================================
-- STAGING SCHEMA  (ADF loads Parquet → here)
-- =========================================

CREATE TABLE IF NOT EXISTS stg.api_311_flat (
  unique_key                         text PRIMARY KEY,

  -- (1) Temporal
  created_date                       timestamptz,
  closed_date                        timestamptz,
  due_date                           timestamptz,
  resolution_action_updated_date     timestamptz,

  -- (2) Agency & Complaint
  agency                             text,
  agency_name                        text,
  complaint_type                     text,
  descriptor                         text,
  status                             text,

  -- (3) Location
  borough                            text,
  community_board                    text,
  incident_zip                       text,
  incident_address                   text,
  street_name                        text,
  cross_street_1                     text,
  cross_street_2                     text,
  intersection_street_1              text,
  intersection_street_2              text,
  address_type                       text,
  city                               text,
  facility_type                      text,

  -- (4) Resolution & Metadata
  resolution_description              text,
  location_type                       text,
  open_data_channel_type              text,

  -- (5) Optional / Coordinates
  bbl                                text,
  x_coordinate_state_plane           text,
  y_coordinate_state_plane           text,
  park_facility_name                 text,
  park_borough                       text,
  latitude                           double precision,
  longitude                          double precision,

  -- (6) Transport / Misc
  taxi_pick_up_location              text,
  vehicle_type                       text,
  taxi_company_borough               text,
  bridge_highway_name                text,
  bridge_highway_direction           text,
  road_ramp                          text,
  bridge_highway_segment             text,
  landmark                           text,

  -- Technical
  src_file                           text,
  ingest_ts                          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE stg.api_311_flat
    DROP CONSTRAINT api_311_flat_pkey;

CREATE INDEX IF NOT EXISTS ix_api_311_flat_ingest_ts
  ON stg.api_311_flat (ingest_ts DESC);

CREATE INDEX IF NOT EXISTS ix_api_311_flat_uqk
    ON stg.api_311_flat (unique_key);

-- Note: Further processing to unnest JSON array into normalized tables will be handled in subsequent transformations.    
-- This table serves as the initial landing zone for raw data ingestion.
-- Ensure appropriate permissions are granted to ETL service principals as needed.


-- End of file: sql/stg/api_311_raw.sql

