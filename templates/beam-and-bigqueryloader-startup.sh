#!/bin/bash
enrich_version="1.1.0"
bq_version="0.4.0"
TEMP_BUCKET="%TEMPBUCKET%"
project_id="%PROJECTID%"
region="%REGION%"

sudo apt-get update
sudo apt-get -y install default-jre unzip less wget

wget -q https://github.com/snowplow/enrich/releases/download/beam_enrich%2F1.1.1/snowplow_beam_enrich_1.1.0.zip
# wget -q https://github.com/snowplow/enrich/releases/download/beam_enrich%2F$enrich_version/snowplow_beam_enrich_$enrich_version.zip
unzip snowplow_beam_enrich_$enrich_version.zip

wget -q https://github.com/snowplow-incubator/snowplow-bigquery-loader/releases/download/$bq_version/snowplow_bigquery_loader_$bq_version.zip
unzip snowplow_bigquery_loader_$bq_version.zip

wget -q https://github.com/snowplow-incubator/snowplow-bigquery-loader/releases/download/$bq_version/snowplow_bigquery_mutator_$bq_version.zip
unzip snowplow_bigquery_mutator_$bq_version.zip

gsutil cp ${TEMP_BUCKET}/config/iglu_config.json .
gsutil cp ${TEMP_BUCKET}/config/bigqueryloader_config.json .

#start beam enrich in data flow
./beam-enrich-$enrich_version/bin/beam-enrich \
    --runner=DataFlowRunner \
    --project=$project_id \
    --streaming=true \
    --job-name="beam-enrich" \
    --region=$region \
    --gcpTempLocation=$TEMP_BUCKET/temp-files \
    --raw=projects/$project_id/subscriptions/collected-good-sub \
    --enriched=projects/$project_id/topics/enriched-good \
    --bad=projects/$project_id/topics/enriched-bad \
    --pii=projects/$project_id/topics/enriched-pii \
    --resolver=iglu_config.json

#create tables
./snowplow-bigquery-mutator-$bq_version/bin/snowplow-bigquery-mutator create \
  --config $(cat bigqueryloader_config.json | base64 -w 0) \
  --resolver $(cat iglu_config.json | base64 -w 0)

#listen to new bq types
./snowplow-bigquery-mutator-$bq_version/bin/snowplow-bigquery-mutator listen \
  --config $(cat bigqueryloader_config.json | base64 -w 0) \
  --resolver $(cat iglu_config.json | base64 -w 0) &

./snowplow-bigquery-loader-$bq_version/bin/snowplow-bigquery-loader \
  --config=$(cat bigqueryloader_config.json | base64 -w 0) \
  --resolver=$(cat iglu_config.json | base64 -w 0) \
  --runner=DataFlowRunner \
  --project=$project_id \
  --region=$region \
  --gcpTempLocation=${TEMP_BUCKET}/temp-files
