#!/bin/sh

# Start Kind development cluster
PROM_ENABLED=true \
DISAGG_P=true \
DATA_DIR=/home/zoltan/data \
MODEL_NAME=Qwen/Qwen2.5-0.5B-Instruct \
VLLM_EXTRA_ARGS_P="--config=/data/70b-h100-tp8-throughput-per-token.yaml --dataset-path /data/ShareGPT_V3_unfiltered_cleaned_split-converted.sqlite3" \
VLLM_EXTRA_ARGS_D="--config=/data/70b-h100-tp8-throughput-per-token.yaml --dataset-path /data/ShareGPT_V3_unfiltered_cleaned_split-converted.sqlite3" \
make env-dev-kind

# Start Grafana
docker run \
  --rm \
  --detach \
  --network host \
  --volume bench/grafana-provisioning:/etc/grafana/provisioning:ro \
  --env "GF_AUTH_ANONYMOUS_ENABLED=true" \
  --env "GF_AUTH_ANONYMOUS_ORG_ROLE=Admin" \
  --env "GF_AUTH_DISABLE_LOGIN_FORM=true" \
  --name grafana \
  grafana/grafana-oss

# For speeding up startup times, it can be handy to mount its db and auxilary files like:
#   --volume ../data/grafana:/var/lib/grafana \
