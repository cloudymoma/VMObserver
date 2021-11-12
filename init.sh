#!/bin/bash
PROJECT_ID=<project_id>
REGION=us-central1
DATASET_NAME=vm_observer
gcloud services enable "appengine.googleapis.com"
gcloud services enable "bigquery.googleapis.com"
gcloud services enable "run.googleapis.com"
gcloud services enable "containerregistry.googleapis.com"
gcloud services enable "cloudscheduler.googleapis.com"
gcloud app create --region=us-central || echo "App already created, skip"
gcloud iam service-accounts create vm-observer-sa \
	--display-name="Service Account for VM Observer"
echo "service account created: vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	--member=serviceAccount:vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
	--role=roles/viewer
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	--member=serviceAccount:vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
	--role=roles/bigquery.admin
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	--member=serviceAccount:vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
	--role=roles/run.invoker
echo "service account role granted"
bq --location=US mk -d \
	--description "VM Observer dataset."  ${DATASET_NAME}
echo "dataset created: ${DATASET_NAME}"
bq mk \
  --table \
  --description "VM infomation" \
  --time_partitioning_field=run_date \
  --time_partitioning_type=DAY \
  ${DATASET_NAME}.vm_info \
  bigquery_schema.txt
echo "table created: ${DATASET_NAME}.vm_info"
bq mk \
	--use_legacy_sql=false \
	--description "vm_table_ts" \
	--view \
	"SELECT run_date AS time,
	    project_id AS projectID,
	    region,
	    zone,
	    machineType,
	    vmFamily,
	    name AS vmName,
      status AS vmStatus,
	    vmCpus AS cpu,
	    vmRamInGb AS mem,
	    gpuType,
	    gpuCount
	  FROM
	    \`${PROJECT_ID}.${DATASET_NAME}.vm_info\`
	${DATASET_NAME}.vm_table_ts

bq mk \
  --use_legacy_sql=false \
  --description "disk_table_ts" \
  --view \
  "SELECT
    run_date AS time,
    project_id AS projectID,
    region,
    zone,
    machineType,
    vmFamily,
    status AS vmStatus,
    d.deviceName as diskName,
    d.type as diskType,
    d.diskSizeGb as diskSizeGb
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.vm_info\`,
    UNNEST(disks) AS d
  ${DATASET_NAME}.disk_table_ts

bq mk \
  --use_legacy_sql=false \
  --description "vm_table_latest" \
  --view \
  "SELECT
    *
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
  WHERE
    time = (
    SELECT
      MAX(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`)" \
  ${DATASET_NAME}.vm_table_latest

bq mk \
  --use_legacy_sql=false \
  --description "disk_table_latest" \
  --view \
  "SELECT
    *
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
  WHERE
    time = (
    SELECT
      MAX(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`)" \
  ${DATASET_NAME}.disk_table_latest

bq mk \
  --use_legacy_sql=false \
  --description "vm_table_delta" \
  --view \
  "WITH
  A AS (
  SELECT
    time,
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    count(vmName) as instance_count,
    SUM(cpu) AS cpu,
    SUM(mem) AS mem,
    SUM(gpuCount) AS gpuCount
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1)
  GROUP BY
    time,
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus),
  B AS (
  SELECT
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    count(vmName) as instance_count,
    SUM(cpu) AS cpu,
    SUM(mem) AS mem,
    SUM(gpuCount) AS gpuCount
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1) - INTERVAL 1 DAY
  GROUP BY
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus),
  C AS (
  SELECT
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    count(vmName) as instance_count,
    SUM(cpu) AS cpu,
    SUM(mem) AS mem,
    SUM(gpuCount) AS gpuCount
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1) - INTERVAL 7 DAY
  GROUP BY
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus),
  D AS (
  SELECT
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    count(vmName) as instance_count,
    SUM(cpu) AS cpu,
    SUM(mem) AS mem,
    SUM(gpuCount) AS gpuCount
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.vm_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1) - INTERVAL 30 DAY
  GROUP BY
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus)
SELECT
  A.time,
  A.projectID,
  A.region,
  A.zone,
  A.vmFamily,
  A.vmStatus,
  (A.instance_count - B.instance_count  ) AS instance_count_change_1day,
  (A.cpu - B.cpu) AS cpu_change_1day,
  (A.mem - B.mem) AS mem_change_1day,
  (A.gpuCount - B.gpuCount) AS gpu_change_1day,
  (A.instance_count - C.instance_count  ) AS instance_count_change_7days,
  (A.cpu - C.cpu) AS cpu_change_7days,
  (A.mem - C.mem) AS mem_change_7days, 
  (A.gpuCount - C.gpuCount) AS gpu_change_7days,
  (A.instance_count - D.instance_count  ) AS instance_count_change_30days,
  (A.cpu - D.cpu) AS cpu_change_30days,
  (A.mem - D.mem) AS mem_change_30days,
  (A.gpuCount - D.gpuCount) AS gpu_change_30day
FROM
  A
LEFT JOIN
  B
ON
  A.projectID=B.projectID
  AND A.region=B.region
  AND A.zone=B.zone
  AND A.vmFamily=B.vmFamily
  AND A.vmStatus=B.vmStatus
LEFT JOIN
  C
ON 
  A.projectID=C.projectID
  AND A.region=C.region
  AND A.zone=C.zone
  AND A.vmFamily=C.vmFamily
  AND A.vmStatus=C.vmStatus
LEFT JOIN
  D
ON
  A.projectID=D.projectID
  AND A.region=D.region
  AND A.zone=D.zone
  AND A.vmFamily=D.vmFamily
  AND A.vmStatus=D.vmStatus" \
  ${DATASET_NAME}.vm_table_delta

bq mk \
  --use_legacy_sql=false \
  --description "disk_table_delta" \
  --view \
  "WITH
  A AS (
  SELECT
    time,
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    SUM(diskSizeGb) as diskSizeGb
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1)
  GROUP BY
    time,
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus),
  B AS (
  SELECT
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    SUM(diskSizeGb) as diskSizeGb
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1) - INTERVAL 1 DAY
  GROUP BY
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus),
  C AS (
  SELECT
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    SUM(diskSizeGb) as diskSizeGb
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1) - INTERVAL 7 DAY
  GROUP BY
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus),
  D AS (
  SELECT
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus,
    SUM(diskSizeGb) as diskSizeGb
  FROM
    \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
  WHERE
    time = (
    SELECT
      DISTINCT(time)
    FROM
      \`${PROJECT_ID}.${DATASET_NAME}.disk_table_ts\`
    ORDER BY
      time DESC
    LIMIT
      1) - INTERVAL 30 DAY
  GROUP BY
    projectID,
    region,
    zone,
    vmFamily,
    vmStatus)
SELECT
  A.time,
  A.projectID,
  A.region,
  A.zone,
  A.vmFamily,
  A.vmStatus,
  (A.diskSizeGb - B.diskSizeGb  ) AS diskSizeGb_change_1day,
  (A.diskSizeGb - C.diskSizeGb  ) AS diskSizeGb_change_7days,
  (A.diskSizeGb - D.diskSizeGb  ) AS diskSizeGb_change_30days
FROM
  A
LEFT JOIN
  B
ON
  A.projectID=B.projectID
  AND A.region=B.region
  AND A.zone=B.zone
  AND A.vmFamily=B.vmFamily
  AND A.vmStatus=B.vmStatus
LEFT JOIN
  C
ON 
  A.projectID=C.projectID
  AND A.region=C.region
  AND A.zone=C.zone
  AND A.vmFamily=C.vmFamily
  AND A.vmStatus=C.vmStatus
LEFT JOIN
  D
ON
  A.projectID=D.projectID
  AND A.region=D.region
  AND A.zone=D.zone
  AND A.vmFamily=D.vmFamily
  AND A.vmStatus=D.vmStatus" \
  ${DATASET_NAME}.disk_table_delta

gcloud auth configure-docker
docker build -t gcr.io/${PROJECT_ID}/vmobserver .
docker push gcr.io/${PROJECT_ID}/vmobserver
gcloud run deploy vmobserver --concurrency=1 --cpu=1 --max-instances=1 \
	--memory=2Gi --min-instances=0 \
	--service-account=vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
	--timeout=600 \
	--image=gcr.io/${PROJECT_ID}/vmobserver \
	--no-allow-unauthenticated --region=${REGION}
CLOUD_RUN_URL=`gcloud run services describe vmobserver --region=us-central1 | grep URL | cut -d ' ' -f 6`
echo "cloud run url: ${CLOUD_RUN_URL}"
gcloud scheduler jobs create http daily-vm-collect --location=${REGION} --schedule="0 1 * * *" \
	--headers="Content-Type=application/json" \
	--time-zone="Asia/Shanghai" --uri ${CLOUD_RUN_URL} \
	--oidc-service-account-email=vm-observer-sa@${PROJECT_ID}.iam.gserviceaccount.com \
	--http-method POST --message-body-from-file=post.json
echo "scheduler created"