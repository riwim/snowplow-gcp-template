#!/bin/bash 

# Init whole project. Creates colector instances, BQ, pubsubs, cloud storage etc.
# You have to finish the process manualy by configuring load balancer

source "./gcloud-config.sh"
echo "[start] Preparing $GCP_NAME"

UUID=$(uuidgen)

gcloud config set project $GCP_NAME

#prepare config files from template

mkdir -p ./configs
cd ./templates/
TEMP_BUCKET_ESC=$(echo $TEMP_BUCKET |  sed -e 's/[\/&]/\\&/g')

echo "[info] Preparing scripts from templates"
for file in `ls ./*.*`
do
    echo "Procesing template ${file}"
    cat $file | sed -e "s/%REGION%/${REGION}/g"  -e "s/%TEMPBUCKET%/${TEMP_BUCKET_ESC}/g"  -e "s/%PROJECTID%/${GCP_NAME}/g" | \
    sed -e "s/%UUID%/${UUID}/g" -e "s/%SERVICEACCOUNT%/${SERVICEACCOUNT}/g"\
    > ../configs/$file
done
cd ..

echo "[info] Creating PUB/SUB topics and subscriptions"
#collector pubsub
gcloud pubsub topics create "collected-good" --message-storage-policy-allowed-regions="$REGION"
gcloud pubsub topics create "collected-bad" --message-storage-policy-allowed-regions="$REGION"
gcloud pubsub subscriptions create "collected-good-sub" --topic="collected-good" --expiration-period=365d
gcloud pubsub subscriptions create "collected-bad-sub" --topic="collected-bad" --expiration-period=365d

#enriched pubsub
gcloud pubsub topics create enriched-bad --message-storage-policy-allowed-regions="$REGION"
gcloud pubsub topics create enriched-good --message-storage-policy-allowed-regions="$REGION"
gcloud pubsub topics create enriched-pii --message-storage-policy-allowed-regions="$REGION"

gcloud pubsub subscriptions create "enriched-good-sub" --topic="enriched-good" --expiration-period=365d
gcloud pubsub subscriptions create "enriched-bad-sub" --topic="enriched-bad" --expiration-period=365d
gcloud pubsub subscriptions create "enriched-pii-sub" --topic="enriched-pii" --expiration-period=365d

#bigquery
gcloud pubsub topics create bq-bad-rows --message-storage-policy-allowed-regions="$REGION"
gcloud pubsub topics create bq-failed-inserts --message-storage-policy-allowed-regions="$REGION"
gcloud pubsub topics create bq-types --message-storage-policy-allowed-regions="$REGION"

gcloud pubsub subscriptions create "bq-types-sub" --topic="bq-types" --expiration-period=365d
gcloud pubsub subscriptions create "bq-bad-rows-sub" --topic="bq-bad-rows" --expiration-period=365d
gcloud pubsub subscriptions create "bq-failed-inserts" --topic="bq-failed-inserts" --expiration-period=365d

#test subscriptions
gcloud pubsub subscriptions create "collected-good-sub-test" --topic="collected-good" --expiration-period=365d
gcloud pubsub subscriptions create "enriched-good-sub-test" --topic="enriched-good" --expiration-period=365d

echo "[info] Creating temp bucket $TEMP_BUCKET for configurations"
#prepare temp buckets for configurations
gsutil mb -l EU "$TEMP_BUCKET"
touch zero.txt
gsutil cp ./zero.txt  $TEMP_BUCKET/temp-files/
gsutil cp ./zero.txt  $TEMP_BUCKET/config/
rm ./zero.txt

gsutil cp ./configs/iglu_config.json $TEMP_BUCKET/config/
gsutil cp ./configs/collector.config $TEMP_BUCKET/config/
#gsutil cp ./configs/enrich.config $TEMP_BUCKET/config/
gsutil cp ./configs/bigqueryloader_config.json $TEMP_BUCKET/config/

echo "[info] Preparing bigquery dataset $GCP_NAME:snowplow"
#prepare BigQuery
bq --location=EU mk "$GCP_NAME:snowplow"


###################################### Collector group + loadbalancer ###################################################
# collector instances template
echo "[info] Preparing compute instance group machine template"
gcloud compute instance-templates create snowplow-collector-template \
    --machine-type=${COLLECTOR_MACHINE_TYPE} \
    --network=projects/${GCP_NAME}/global/networks/default \
    --network-tier=PREMIUM \
    --metadata-from-file=startup-script=./configs/collector_startup.sh \
    --maintenance-policy=MIGRATE --service-account=$SERVICEACCOUNT \
    --scopes=https://www.googleapis.com/auth/pubsub,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/trace.append,https://www.googleapis.com/auth/devstorage.read_only \
    --tags=collector,http-server,https-server \
    --image=${IMAGE} \
    --image-project=${IMAGE_PROJECT} \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-standard \
    --boot-disk-device-name=snowplow-collector-template

echo "[info] Preparing firewall rule for port 8080"
gcloud compute firewall-rules create snowplow-collector-rule --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:8080 --source-ranges=0.0.0.0/0 --target-tags=collector

echo "[info] Preparing health check"
gcloud compute health-checks create http "snowplow-collector-health-check" --timeout "5" --check-interval "10" --unhealthy-threshold "3" --healthy-threshold "2" --port "8080" --request-path "/health"

echo "[info] Preparing compute instance group"
gcloud compute instance-groups managed create snowplow-collector-group --base-instance-name=snowplow-collector-group --template=snowplow-collector-template --size=1  --health-check=snowplow-collector-health-check --initial-delay=300 --zone="${ZONE}"

echo "[info] Seting autoscaling for group"
gcloud compute instance-groups managed set-autoscaling "snowplow-collector-group" --cool-down-period "60" --max-num-replicas "2" --min-num-replicas "1" --target-cpu-utilization "0.6" --zone="${ZONE}"

gcloud compute instances list
collector_ip=$(gcloud compute instances list --filter="name ~ collector"\
      --format="get(networkInterfaces[0].accessConfigs[0].natIP)")
echo "[info] All done. Collector runs at $collector_ip. Wait until scala-stream-collector starts (cca. 2-5mins)"
echo "[test] curl http://$collector_ip:8080/health"
echo "[test] curl http://$collector_ip:8080/i"
echo "[test] and then:"
echo "[test] gcloud pubsub subscriptions pull --auto-ack collected-good-sub-test"

####################################################################################################
# MANUAL ACTIONS
# now configure firewall. Backend service id this group and health
####################################################################################################

echo
echo "Now setup firewall with snowplow-collector-group as a backend service and snowplow-collector-health-check"
echo "https://www.simoahava.com/analytics/install-snowplow-on-the-google-cloud-platform/#step-3-create-a-load-balancer"
echo
echo "Then run ./start_etl.sh and don't forget to stop it soon ;-)"
