-- =========================================
-- FUNCTION: dwh.run_311_transform
-- Purpose : Merge stg.api_311_flat → dwh.fact_311_requests
-- =========================================
CREATE OR REPLACE FUNCTION dwh.run_311_transform(p_window interval)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    batch_limit      integer := 5000;   -- number of rows per batch
    rows_processed   integer;
    total_processed  integer := 0;

BEGIN
    RAISE NOTICE '[run_311_transform] Starting load for window: %', p_window;

    LOOP
        -- Pull the next batch of rows from staging within the given window
        WITH next_batch AS (
            SELECT *
            FROM stg.api_311_flat
            WHERE ingest_ts >= now() - p_window
            ORDER BY ingest_ts
            LIMIT batch_limit
        )
        INSERT INTO dwh.fact_311_requests AS f (
            unique_key,
            created_date,
            closed_date,
            due_date,
            resolution_action_updated_date,
            agency,
            agency_name,
            complaint_type,
            descriptor,
            status,
            borough,
            community_board,
            incident_zip,
            incident_address,
            street_name,
            cross_street_1,
            cross_street_2,
            intersection_street_1,
            intersection_street_2,
            address_type,
            city,
            facility_type,
            resolution_description,
            location_type,
            open_data_channel_type,
            bbl,
            x_coordinate_state_plane,
            y_coordinate_state_plane,
            park_facility_name,
            park_borough,
            latitude,
            longitude,
            taxi_pick_up_location,
            vehicle_type,
            taxi_company_borough,
            bridge_highway_name,
            bridge_highway_direction,
            road_ramp,
            bridge_highway_segment,
            landmark,
            src_file
        )
        SELECT
            nb.unique_key,
            nb.created_date,
            nb.closed_date,
            nb.due_date,
            nb.resolution_action_updated_date,
            nb.agency,
            nb.agency_name,
            nb.complaint_type,
            nb.descriptor,
            nb.status,
            nb.borough,
            nb.community_board,
            nb.incident_zip,
            nb.incident_address,
            nb.street_name,
            nb.cross_street_1,
            nb.cross_street_2,
            nb.intersection_street_1,
            nb.intersection_street_2,
            nb.address_type,
            nb.city,
            nb.facility_type,
            nb.resolution_description,
            nb.location_type,
            nb.open_data_channel_type,
            nb.bbl,
            nb.x_coordinate_state_plane,
            nb.y_coordinate_state_plane,
            nb.park_facility_name,
            nb.park_borough,
            nb.latitude::double precision,
            nb.longitude::double precision,
            nb.taxi_pick_up_location,
            nb.vehicle_type,
            nb.taxi_company_borough,
            nb.bridge_highway_name,
            nb.bridge_highway_direction,
            nb.road_ramp,
            nb.bridge_highway_segment,
            nb.landmark,
            nb.src_file
        FROM next_batch nb
        ON CONFLICT (unique_key)
        DO UPDATE SET
            status = EXCLUDED.status,
            resolution_description = EXCLUDED.resolution_description,
            closed_date = EXCLUDED.closed_date,
            resolution_action_updated_date = EXCLUDED.resolution_action_updated_date,
            latitude = EXCLUDED.latitude,
            longitude = EXCLUDED.longitude,
            src_file = EXCLUDED.src_file;

        -- Capture number of rows inserted/updated
        GET DIAGNOSTICS rows_processed = ROW_COUNT;
        total_processed := total_processed + rows_processed;
        RAISE NOTICE '[run_311_transform] Upserted % rows this batch (total so far: %)', rows_processed, total_processed;

        -- Exit when no more rows
        IF rows_processed < batch_limit THEN
            EXIT;
        END IF;
    END LOOP;
    RAISE NOTICE '[run_311_transform] Completed. Total rows processed: % for window %', total_processed, p_window;
END;
$$;
-- To execute the transformation for the last 1 hour:
-- SELECT dwh.run_311_transform(interval '1 hour');