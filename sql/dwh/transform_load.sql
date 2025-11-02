-- =========================================
-- FUNCTION: dwh.run_311_transform
-- Purpose : Merge stg.api_311_flat → dwh.fact_311_requests
-- =========================================

CREATE OR REPLACE FUNCTION dwh.run_311_transform(p_since interval DEFAULT interval '1 day')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  /*
    We pull only rows from staging (stg.api_311_flat)
    loaded in roughly the last p_since (e.g. 1 day),
    BUT we also deduplicate so we only keep the latest
    version per unique_key by ingest_ts.
  */

  WITH latest_per_key AS (
    SELECT DISTINCT ON (s.unique_key)
      s.unique_key,
      s.created_date,
      s.due_date,
      s.resolution_action_updated_date,
      s.agency,
      s.agency_name,
      s.complaint_type,
      s.descriptor,
      s.status,
      s.borough,
      s.incident_zip,
      s.incident_address,
      s.street_name,
      s.community_board,
      s.latitude,
      s.longitude,
      s.resolution_description,
      s.location_type,
      s.facility_type,
      s.open_data_channel_type,
      s.bbl,
      s.address_type,
      s.park_facility_name,
      s.park_borough,
      s.cross_street_1,
      s.cross_street_2,
      s.intersection_street_1,
      s.intersection_street_2,
      s.src_file,
      s.ingest_ts
    FROM stg.api_311_flat s
    WHERE s.ingest_ts >= now() - p_since
    -- DISTINCT ON keeps the *first* row per unique_key according to ORDER BY.
    -- We want the newest ingest_ts to win.
    ORDER BY s.unique_key, s.ingest_ts DESC
  )

  INSERT INTO dwh.fact_311_requests AS f (
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
  )
  SELECT
    lk.unique_key,
    lk.created_date,
    lk.due_date,
    lk.resolution_action_updated_date,
    lk.agency,
    lk.agency_name,
    lk.complaint_type,
    lk.descriptor,
    lk.status,
    lk.borough,
    lk.incident_zip,
    lk.incident_address,
    lk.street_name,
    lk.community_board,
    lk.latitude,
    lk.longitude,
    lk.resolution_description,
    lk.location_type,
    lk.facility_type,
    lk.open_data_channel_type,
    lk.bbl,
    lk.address_type,
    lk.park_facility_name,
    lk.park_borough,
    lk.cross_street_1,
    lk.cross_street_2,
    lk.intersection_street_1,
    lk.intersection_street_2,
    lk.src_file,
    now() AS first_seen_ts,
    now() AS updated_ts
  FROM latest_per_key lk
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
      src_file                       = EXCLUDED.src_file,
      updated_ts                     = now();

END;
$$;


-- Optional: manual run
-- SELECT dwh.run_311_transform(interval '1 day');
