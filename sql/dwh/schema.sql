-- =========================================
-- DWH SCHEMA OBJECTS (no data movement)
-- =========================================

CREATE SCHEMA IF NOT EXISTS dwh;

-- Main fact table used by BI
CREATE TABLE IF NOT EXISTS dwh.fact_311_requests (
  unique_key                         text PRIMARY KEY,

  -- (1) Temporal Analysis
  created_date                       timestamptz,
  due_date                           timestamptz,
  resolution_action_updated_date     timestamptz,

  -- (2) Agency & Complaint Insights
  agency                             text,
  agency_name                        text,
  complaint_type                     text,
  descriptor                         text,
  status                             text,

  -- (3) Location Intelligence
  borough                            text,
  incident_zip                       text,
  incident_address                   text,
  street_name                        text,
  community_board                    text,
  latitude                           double precision,
  longitude                          double precision,

  -- (4) Operational Metrics
  resolution_description             text,
  location_type                      text,
  facility_type                      text,
  open_data_channel_type             text,

  -- (5) Optional / Enrichment
  bbl                                text,
  address_type                       text,
  park_facility_name                 text,
  park_borough                       text,
  cross_street_1                     text,
  cross_street_2                     text,
  intersection_street_1              text,
  intersection_street_2              text,

  -- Technical
  src_file                           text,
  first_seen_ts                      timestamptz NOT NULL DEFAULT now(),
  updated_ts                         timestamptz NOT NULL DEFAULT now()
);

-- Helpful indexes for common filters
CREATE INDEX IF NOT EXISTS ix_fact311_created_date   ON dwh.fact_311_requests (created_date);
CREATE INDEX IF NOT EXISTS ix_fact311_agency         ON dwh.fact_311_requests (agency);
CREATE INDEX IF NOT EXISTS ix_fact311_complaint_type ON dwh.fact_311_requests (complaint_type);
CREATE INDEX IF NOT EXISTS ix_fact311_borough        ON dwh.fact_311_requests (borough);
CREATE INDEX IF NOT EXISTS ix_fact311_status         ON dwh.fact_311_requests (status);
CREATE INDEX IF NOT EXISTS ix_fact311_zip            ON dwh.fact_311_requests (incident_zip);

-- (Optional) a thin view for BI (friendlier names)
CREATE OR REPLACE VIEW dwh.v_311_requests AS
SELECT
  unique_key,
  created_date,
  due_date,
  resolution_action_updated_date,
  agency,
  agency_name,
  complaint_type,
  descriptor,
  status,
  borough,
  incident_zip,
  incident_address,
  street_name,
  community_board,
  latitude,
  longitude,
  resolution_description,
  location_type,
  facility_type,
  open_data_channel_type,
  bbl,
  address_type,
  park_facility_name,
  park_borough,
  cross_street_1,
  cross_street_2,
  intersection_street_1,
  intersection_street_2,
  src_file,
  first_seen_ts,
  updated_ts
FROM dwh.fact_311_requests;

