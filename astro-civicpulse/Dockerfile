FROM astrocrpublic.azurecr.io/runtime:3.1-2

# Install system dependencies
# Install Python deps for DAGs
COPY requirements.txt /usr/local/airflow/requirements.txt
RUN pip install --no-cache-dir -r /usr/local/airflow/requirements.txt

