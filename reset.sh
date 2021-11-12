#!/bin/bash
PROJECT_ID=<project_id>
DATASET_NAME=vm_observer
REGION=us-central1

gcloud iam service-accounts remove-iam-policy-binding vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --member='serviceAccount:vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com' \
  --role='roles/viewer'
gcloud iam service-accounts remove-iam-policy-binding vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --member='serviceAccount:vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com' \
  --role='roles/bigquery.admin'
gcloud iam service-accounts remove-iam-policy-binding vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --member='serviceAccount:vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com' \
  --role='roles/run.invoker'  
gcloud iam service-accounts delete --quiet vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com
echo "service account deleted: vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com"

bq rm -q -f ${DATASET_NAME}.vm_table_delta
bq rm -q -f ${DATASET_NAME}.vm_table_latest
bq rm -q -f ${DATASET_NAME}.vm_table_ts
bq rm -q -f ${DATASET_NAME}.disk_table_delta
bq rm -q -f ${DATASET_NAME}.disk_table_latest
bq rm -q -f ${DATASET_NAME}.disk_table_ts
bq rm -q -f ${DATASET_NAME}.vm_info
bq rm -d -q -f ${DATASET_NAME}
echo "bigquery dataset deleted: ${DATASET_NAME}"

gcloud scheduler jobs delete daily-vm-collect --quiet
echo "cloud scheduler deleted"

gcloud run services delete vmobserver --region=${REGION} --quiet
echo "cloud run deleted"

gcloud container images delete gcr.io/${PROJECT_ID}/vmobserver --quiet
echo "container registry deleted"