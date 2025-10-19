# Terraform-ELT-pipeline-for-Transparent-City-Metrics (NYC 311 API)  by CivicPulse 311

A Cloud-native ELT pipeline for NYC 311 data, built with Terraform, Airflow, and Azure. Enables real-time ingestion, transformation, and reporting via Power BI. Designed for resilience, transparency, and operational insight into the city service metrics.

## Business Challenge and Objectives

CivicPulse 311 addresses the evolving demands of NYC’s non-emergency service ecosystem by transforming raw 311 data into actionable, real-time intelligence. Key challenges include:
        - **Customer Demand**: Need for live, explainable insights and equity views across neighborhoods.
        - **System Reliability**: Ensuring robust orchestration and anomaly detection in data pipelines.
        - **Data Latency & Scalability**: Managing peak volumes without lag, and supporting schema evolution.

### Project Objectives

The project aims to deliver a resilient, cloud-native ELT pipeline with:
        - **Scalable Near Real-Time Ingestion**: Fault-tolerant extraction from the NYC 311 API.
        - **Real-Time Reporting Tools**: Power BI dashboards for volumes, SLA compliance, and complaint mix.
        - **Enhanced Data Accuracy**: Validated movement from raw source to curated database layers.
        - **Improved System Monitoring**: Instrumentation and alerts for pipeline health and data quality.

## Architecture & Setup

### Architecture

![Data Pipeline Architecture](Data_pipeline_Archit.png)

API  →  Airflow (Extract)  →  Azure Blob Storage  →  Azure Data Factory[ADF (Load + Orchestrate)]  →  Azure PostgreSQL (Transform in SQL) →  Power BI

| Layer                | Tool                     | Purpose                                                         |
| -------------------- | ------------------------ | --------------------------------------------------------------- |
| **E (Extract)**      | Apache Airflow           | Fetch data from an API and save it to Azure Blob (`raw/`)       |
| **L (Load)**         | Azure Data Factory (ADF) | Copy data from Blob → PostgreSQL staging table                  |
| **T (Transform)**    | PostgreSQL (SQL scripts) | Clean & reshape data inside the DB for Power BI                 |
| **Visualization**    | Power BI                 | Build dashboards from the warehouse tables                      |
| **Infra management** | Terraform                | Create Azure resources (Blob Storage, Postgres, ADF, Key Vault) |

### Repo structure

```bash
 Terraform-elt-pipeline/
 ├─ terraform/                  # Infrastructure-as-Code (provisions Azure)
 │  ├─ backend.tf               # Stores Terraform state in Azure storage
 │  ├─ providers.tf             # Pins provider versions and enables Azure
 │  ├─ variables.tf             # All knobs to tweak: region, env name, Postgres admin,IP etc.
 │  ├─ main.tf                  # The orchestration brain. Creates the resource group, then calls module
 │  ├─ outputs.tf               # surfaces useful info after apply (e.g., pg_fqdn to connect psql).
 │  └─ terraform.tfvars
 |
 ├─ airflow_dags/nyc_311_to_blob.py # hits the open NYC 311 endpoint (example) and writes the JSON to Blob in azure
 └─ sql/
    ├─ stg/api_311_raw.sql      # SQL scripts for transformations - creates a staging table to hold jsonb payloads
    |   ├─ sample_insert.sql               
    │   └─ data/sample_311.json
    └─ dwh/run_311_transform.sql    # reads recent staging rows, flattens JSON into columns,upserts by request_id.
```

### Infrastructure with Terraform

- ***install Terraform and Azure CLI first.***

### Infrastructure Resources/ Modules

- **Resources:** [Terraform Registry](https://registry.terraform.io)
- Create and activate a virtual env: python -m venv .venv

1. Terraform builds the Azure pieces:
        - Resource Group
        - Storage Account (Blob)
        - Azure PostgreSQL Flexible Server
        - Azure Data Factory

### Install tools

```bash
# Install Azure CLI
winget install --exact --id Microsoft.AzureCLI
az upgrade

# Install Terraform
choco install terraform       # Windows

# Login to Azure
az login # or az login --tenant <tenant-id>
az account set --subscription "<your-subscription-id>"

# check active subscription
az account show

```

### Terraform configuration files

Create a terraform/ folder like above

## Usage - How to run (ground up)

### Install: Terraform ≥ 1.6, Azure CLI ≥ 2.58 at project root

- Login + select subscription:

```bash
az login --tenant <YOUR_TENANT_ID>   # e.g. the Default Directory tenant GUID
az account set --subscription <YOUR_SUBSCRIPTION_ID>

# verify
az account show --query "{name:name, sub:id, tenant:tenantId}" -o tsv

# List all subs/resources you can see (refresh tokens)
az account list --refresh -o table
az resource list --output table
terraform destroy #to delete all resources in current state (for a re-run)
```

Make sure the Storage resource provider is registered (1-time per subscription)

```bash
az provider register --namespace Microsoft.Storage
az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv
# Wait until it prints Registered
az provider show -n Microsoft.Storage
```

### Create Terraform remote state (optional but recommended)

```bash
# vars you choose
LOCATION="uksouth"
RESOURCE_GROUP="rg-civicpulse-311"
STACCOUNT="stcivicpulse$RANDOM"   # must be globally unique, lowercase only
CONTAINER="tfstate"

az group create -n $RESOURCE_GROUP -l $LOCATION
az storage account create -n $STACCOUNT -g $RESOURCE_GROUP -l $LOCATION --sku Standard_LRS --kind StorageV2
az storage container create --account-name $STACCOUNT --name $CONTAINER --auth-mode login

echo "RG=$RESOURCE_GROUP  ST=$STACCOUNT  LOC=$LOCATION  CT=$CONTAINER"

```

### Deploy Azure and services with Terraform: Initialize + apply at project_root/terraform

```bash
        - Validate config
terraform fmt        # (optional, formats cleanly)
```

```bash
cd Terraform-ETL-pipeline/terraform
# rm -rf .terraform .terraform.lock.hcl (for a re-run)

# point backend at your backend.hcl created earlier
terraform init -backend-config=backend.hcl

#For  403 error: Run the init.sh script with below
chmod +x init.sh
./init.sh


terraform validate
terraform plan -out=tfplans/$(date +%Y-%m-%d_%H%M)-rerun.tfplan
terraform apply "*.tfplan" -auto-approve
```

- ERROR when applying:
 Error: `zone` can only be changed when exchanged with the zone specified in `high_availability.0.standby_availability_zone`with azurerm_postgresql_flexible_server.pg,
   Find the current zone with below and pin to     azurerm_postgresql_flexible_server

```bash
az postgres flexible-server show \
  -g rg-civicpulse-dev \
  -n pg-civicpulse-dev \
  --query "availabilityZone" -o tsv
```

### Post-apply quick tests & Validation Steps

```bash
# Outputs
terraform output
az resource list --output table

# Storage Access
az storage container list --account-name $(terraform output -raw storage_account_name) --auth-mode login -o table

# Postgres Connectivity (local Power BI / psql)
PGPASSWORD="${TF_VAR_pg_admin_pwd}" \
psql "host=$(terraform output -raw postgres_fqdn) dbname=$(terraform output -raw database) user=${TF_VAR_pg_admin_user:-pgadmin} sslmode=require" -c "\l"
```

OR UI
        - pgAdmin 4: Download
        - Azure Data Studio: connect with:
                - Server: <postgres_fqdn from Terraform output>
                - Port: 5432
                - Username: pgadmin
                - Password: ${TF_VAR_pg_admin_pwd}
                - SSL mode: Require
![pgAdmin](pgadmin.png)

### Columns & SQL Initialisation (run once)

#### Required Columns for CivicPulse 311 Objectives

- To align with the **business challenge and project objectives**, the following columns from the NYC 311 dataset are essential for building explainable, real-time operational intelligence:
1.) Temporal Analysis
        - `created_date` – For tracking request volumes and latency
        - `due_date` – For SLA compliance and backlog aging
        - `resolution_action_updated_date` – For resolution timing and status updates

2.)  Agency & Complaint Insights
        - `agency` / `agency_name` – To segment by responsible department
        - `complaint_type` – For categorizing service demand
        - `descriptor` – For more granular issue classification
        - `status` – To monitor open vs. closed cases

3.) Location Intelligence
        - `borough` – For borough-level equity and volume analysis
        - `incident_zip` – For zip-level mapping
        - `incident_address` / `street_name` – For geospatial joins and clustering
        - `community_board` – For local governance insights
        - `latitude` / `longitude` – For mapping and spatial analytics

4.) Operational Metrics
        - `resolution_description` – For qualitative resolution tracking
        - `location_type` / `facility_type` – For service context
        - `open_data_channel_type` – To analyze request origin (e.g., phone, app)

5.) Optional but Useful for Enrichment
        - `bbl` – For property-level joins with NYC datasets
        - `address_type` – For filtering valid addresses
        - `park_facility_name` / `park_borough` – If analyzing parks-related complaints
        - `cross_street_1`, `cross_street_2`, `intersection_street_1`, `intersection_street_2` – For traffic or intersection-related issues

#### Initialise DB in project root

```bash
# make executable
chmod +x db_init.sh

# run without executing transform 
./db_init.sh

# or run and immediately execute transform for last 1 day
RUN_TRANSFORM=true SINCE_INTERVAL='1 day' ./db_init.sh
```

- test with sample file

```bash
psql -h "$PGHOST" -d "$PGDB" -U "$PGUSER" \
  -v json_path="sql/stg/data/sample_311.json" \
  -f sql/stg/sample_insert.sql
  
RUN_TRANSFORM=true SINCE_INTERVAL='1 day' ./db_init.sh
```

#### Airflow (local @ http://localhost:9090/home):

- Install Airflow (pip ).
- In Airflow UI → Admin → Connections → +
        - Conn ID: azure_storage_conn
        - Conn Type: Azure Blob Storage
        - Paste Storage connection string from Azure Portal (Storage Account → Access keys).
- *Put airflow_dags/nyc_311_to_blob.py in the Airflow DAGs folder.* ***optional:(create a sysmlink for dags folder:ln -s /mnt/d/Terraform-ETL-pipeline/airflow_dags/nyc_311_to_blob.py /home/linuxtut/airflow/dags)***
- *Start scheduler + webserver and enable the DAG.*

#### ADF (Load + Transform)

- In ADF Studio, create:
        - Linked Services: Blob (your storage) and PostgreSQL (to civicpulsedb, SSL on).
        - Datasets: Blob JSON input, Postgres stg.api_311_raw output.
        - Pipeline: Copy (Blob→Postgres) → Script (SELECT dwh.run_311_transform();).
        - Trigger: hourly schedule or Blob event trigger for raw/api/311/**.

6. Power BI:

- Connect to Azure PostgreSQL → DB civicpulsedb → view dwh.v_311_requests.
- Build visuals (Import mode for speed, DirectQuery for freshness).