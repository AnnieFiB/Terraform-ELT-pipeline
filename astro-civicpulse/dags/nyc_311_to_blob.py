from __future__ import annotations
import os, time, logging
from datetime import datetime, timedelta

import pandas as pd
import requests
from airflow.decorators import dag, task
from airflow.models import Variable
from airflow.exceptions import AirflowFailException

log = logging.getLogger("airflow.task")

# -----------------------------
# Config (from Airflow Variables)
# -----------------------------
URL      = Variable.get("NYC_DATASOURCE_URL")
APP_TOKEN = Variable.get("NYC_APP_TOKEN", "")
BATCH_SIZE = int(Variable.get("BATCH_SIZE", "10000"))
ACCOUNT  = Variable.get("AZURE_STORAGE_ACCOUNT")
CONTAINER = Variable.get("AZURE_STORAGE_CONTAINER", "raw")
CONN_STR = Variable.get("AZURE_STORAGE_CONNECTION_STRING", "")
DOMAIN   = Variable.get("DOMAIN", "api/311")
SOURCE   = Variable.get("SOURCE", "nyc")

# -----------------------------
# Helper: Azure Blob client
# -----------------------------
def get_blob_service_client():
    from azure.storage.blob import BlobServiceClient
    from azure.identity import AzureCliCredential, DefaultAzureCredential

    if CONN_STR:
        return BlobServiceClient.from_connection_string(CONN_STR)
    if not ACCOUNT:
        raise AirflowFailException("Missing Azure config.")
    try:
        cred = AzureCliCredential()
    except Exception:
        cred = DefaultAzureCredential(exclude_interactive_browser_credential=False)
    return BlobServiceClient(
        account_url=f"https://{ACCOUNT}.blob.core.windows.net", credential=cred
    )

# -----------------------------
# Main DAG
# -----------------------------
@dag(
    dag_id="nyc_311_to_blob",
    description="Backfill + incremental loader for NYC 311 → Azure Blob",
    schedule=Variable.get("SCHEDULE_CRON", "0 * * * *"),  # hourly by default
    start_date=datetime(2024,1,1),
    catchup=False,
    tags=["nyc311","blob","simple"],
)
def nyc_311_to_blob():
    @task()
    def extract_and_load():
        """Fetch 311 data (either backfill or incremental) and upload page by page."""
        # --- read control vars ---
        backfill_start = Variable.get("BACKFILL_START", default_var=None)
        backfill_end   = Variable.get("BACKFILL_END", default_var=None)
        watermark      = Variable.get("NYC311_WATERMARK", default_var=None)

        if backfill_start and backfill_end:
            # backfill window mode
            since = datetime.fromisoformat(backfill_start)
            until = datetime.fromisoformat(backfill_end)
            where = f"created_date between '{since:%Y-%m-%dT%H:%M:%S}' and '{until:%Y-%m-%dT%H:%M:%S}'"
            window_label = f"{since:%Y%m%d}_{until:%Y%m%d}"
            Variable.set("NYC311_MODE", "backfill")
        else:
            # incremental mode
            if watermark:
                since = datetime.fromisoformat(watermark)
            else:
                since = datetime.utcnow() - timedelta(days=90)
            where = f"created_date > '{since:%Y-%m-%dT%H:%M:%S}'"
            window_label = f"inc_since_{since:%Y%m%dT%H%M%S}"
            Variable.set("NYC311_MODE", "incremental")

        headers = {"X-App-Token": APP_TOKEN} if APP_TOKEN else {}
        limit = min(BATCH_SIZE, 50000)
        offset = 0
        svc = get_blob_service_client()

        latest_created = since
        while True:
            params = {"$where": where, "$limit": limit, "$offset": offset, "$order": "created_date ASC"}
            r = requests.get(URL, headers=headers, params=params, timeout=120)
            r.raise_for_status()
            data = r.json()
            if not data:
                break

            df = pd.DataFrame(data)
            jsonl = df.to_json(orient="records", lines=True)

            # update watermark candidate
            if "created_date" in df:
                try:
                    cmax = pd.to_datetime(df["created_date"], utc=True, errors="coerce").max()
                    if pd.notna(cmax) and cmax.to_pydatetime() > latest_created:
                        latest_created = cmax.to_pydatetime()
                except Exception:
                    pass

            now = datetime.utcnow()
            blob_path = (
                f"{DOMAIN}/source={SOURCE}/ingest_date={now:%Y-%m-%d}/"
                f"{window_label}_page={offset//limit:05d}.jsonl"
            )
            svc.get_blob_client(CONTAINER, blob_path).upload_blob(jsonl.encode(), overwrite=True)
            log.info("Uploaded %d records to %s", len(df), blob_path)

            offset += limit
            time.sleep(0.2)  # small pause to respect API

        # Save watermark if incremental
        if Variable.get("NYC311_MODE") == "incremental":
            Variable.set("NYC311_WATERMARK", latest_created.replace(microsecond=0).isoformat())
            log.info("Updated watermark → %s", latest_created)

        log.info("Completed %s run", Variable.get("NYC311_MODE"))

    extract_and_load()

nyc_311_to_blob()
