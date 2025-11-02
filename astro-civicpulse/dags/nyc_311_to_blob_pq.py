from __future__ import annotations
import time, logging
from datetime import datetime, timedelta
from io import BytesIO

import pandas as pd
import requests
from airflow.decorators import dag, task
from airflow.models import Variable
from airflow.exceptions import AirflowFailException

log = logging.getLogger("airflow.task")

# -----------------------------
# Config (from Airflow Variables)
# -----------------------------
URL        = Variable.get("NYC_DATASOURCE_URL")
APP_TOKEN  = Variable.get("NYC_APP_TOKEN", "")
BATCH_SIZE = int(Variable.get("BATCH_SIZE", "10000"))
ACCOUNT    = Variable.get("AZURE_STORAGE_ACCOUNT")
CONTAINER  = Variable.get("AZURE_STORAGE_CONTAINER", "raw")
CONN_STR   = Variable.get("AZURE_STORAGE_CONNECTION_STRING", "")
DOMAIN     = Variable.get("DOMAIN", "api/311")
SOURCE     = Variable.get("SOURCE", "nyc")

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
    dag_id="nyc_311_incremental_to_blobpq",
    description="Incremental loader for NYC 311 → Azure Blob (Parquet)",
    schedule=Variable.get("SCHEDULE_CRON", "0 * * * *"),
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["nyc311", "blob", "parquet", "incremental"],
)
def nyc_311_to_blob():
    @task()
    def extract_and_load():
        # Always fetch last 90 days
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
            params = {
                "$where": where,
                "$limit": limit,
                "$offset": offset,
                "$order": "created_date ASC"
            }
            r = requests.get(URL, headers=headers, params=params, timeout=120)
            r.raise_for_status()
            data = r.json()
            if not data:
                break

            df = pd.DataFrame(data)
            
            # Flatten all dict-like columns
            nested_cols = [col for col in df.columns if df[col].apply(lambda x: isinstance(x, dict)).any()]
            for col in nested_cols:
                try:
                    flat = pd.json_normalize(df[col])
                    flat.columns = [f"{col}_{sub}" for sub in flat.columns]
                    df = pd.concat([df.drop(columns=[col]), flat], axis=1)
                except Exception as e:
                    log.warning("Failed to flatten column %s: %s", col, e)

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
                f"{window_label}_page={offset//limit:05d}.parquet"
            )

            buffer = BytesIO()
            df.to_parquet(buffer, engine="pyarrow", index=False)
            buffer.seek(0)

            svc.get_blob_client(CONTAINER, blob_path).upload_blob(buffer, overwrite=True)
            log.info("Uploaded %d records to %s", len(df), blob_path)

            offset += limit
            time.sleep(0.2)

        Variable.set("NYC311_WATERMARK", latest_created.replace(microsecond=0).isoformat())
        log.info("Updated watermark → %s", latest_created)
        log.info("Completed incremental run")

    extract_and_load()

nyc_311_to_blob()