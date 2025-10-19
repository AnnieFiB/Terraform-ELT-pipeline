-- =========================================
-- TRANSFORM & LOAD (no DDL)
--  - Flattens JSON arrays from stg.api_311_raw.payload
--  - Upserts into dwh.fact_311_requests
--  - Parameter p_since controls window (default 7 days)
-- =========================================

-- Ensure required schemas/tables exist (light guard, no-op if already created)
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dwh;

-- Transform function
CREATE OR REPLACE FUNCTION dwh.run_311_transform(p_since interval DEFAULT interval '7 days')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO dwh.fact_311_requests AS f (
    unique_key,
    created_date,
    due_date,
    resolution_action_updated_date,
    agency, agency_name, complaint_type, descriptor, status,
    borough, incident_zip, incident_address, street_name, community_board,
    latitude, longitude,
    resolution_description, location_type, facility_type, open_data_channel_type,
    bbl, address_type, park_facility_name, park_borough,
    cross_street_1, cross_street_2, intersection_street_1, intersection_street_2,
    src_file, first_seen_ts, updated_ts
  )
  SELECT
    rec->>'unique_key'                                         AS unique_key,

    NULLIF(rec->>'created_date','')::timestamptz               AS created_date,
    NULLIF(rec->>'due_date','')::timestamptz                   AS due_date,
    NULLIF(rec->>'resolution_action_updated_date','')::timestamptz AS resolution_action_updated_date,

    rec->>'agency',
    rec->>'agency_name',
    rec->>'complaint_type',
    rec->>'descriptor',
    rec->>'status',

    rec->>'borough',
    rec->>'incident_zip',
    rec->>'incident_address',
    rec->>'street_name',
    rec->>'community_board',

    NULLIF(rec->>'latitude','')::double precision,
    NULLIF(rec->>'longitude','')::double precision,

    rec->>'resolution_description',
    rec->>'location_type',
    rec->>'facility_type',
    rec->>'open_data_channel_type',

    rec->>'bbl',
    rec->>'address_type',
    rec->>'park_facility_name',
    rec->>'park_borough',
    rec->>'cross_street_1',
    rec->>'cross_street_2',
    rec->>'intersection_street_1',
    rec->>'intersection_street_2',

    r.src_file,
    now() AS first_seen_ts,
    now() AS updated_ts
  FROM stg.api_311_raw r
  CROSS JOIN LATERAL jsonb_array_elements(r.payload) rec
  WHERE r.ingest_ts >= now() - p_since
    AND rec ? 'unique_key'
  ON CONFLICT (unique_key) DO UPDATE
    SET
      created_date                   = EXCLUDED.created_date,
      due_date                       = EXCLUDED.due_date,
      resolution_action_updated_date = EXCLUDED.resolution_action_updated_date,
      agency                         = EXCLUDED.agency,
      agency_name                    = EXCLUDED.agency_name,
      complaint_type                 = EXCLUDED.complaint_type,
      descriptor                     = EXCLUDED.descriptor,
      status                         = EXCLUDED.status,
      borough                        = EXCLUDED.borough,
      incident_zip                   = EXCLUDED.incident_zip,
      incident_address               = EXCLUDED.incident_address,
      street_name                    = EXCLUDED.street_name,
      community_board                = EXCLUDED.community_board,
      latitude                       = EXCLUDED.latitude,
      longitude                      = EXCLUDED.longitude,
      resolution_description         = EXCLUDED.resolution_description,
      location_type                  = EXCLUDED.location_type,
      facility_type                  = EXCLUDED.facility_type,
      open_data_channel_type         = EXCLUDED.open_data_channel_type,
      bbl                            = EXCLUDED.bbl,
      address_type                   = EXCLUDED.address_type,
      park_facility_name             = EXCLUDED.park_facility_name,
      park_borough                   = EXCLUDED.park_borough,
      cross_street_1                 = EXCLUDED.cross_street_1,
      cross_street_2                 = EXCLUDED.cross_street_2,
      intersection_street_1          = EXCLUDED.intersection_street_1,
      intersection_street_2          = EXCLUDED.intersection_street_2,
      src_file                       = COALESCE(EXCLUDED.src_file, f.src_file),
      updated_ts                     = now();
END;
$$;

-- Optional one-liner to run immediately for last 7 days:
-- SELECT dwh.run_311_transform();

-- Or run for a different window, e.g. 1 day:
-- SELECT dwh.run_311_transform(interval '1 day');
