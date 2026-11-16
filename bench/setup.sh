#!/bin/sh

# Start Kind development cluster
PROM_ENABLED=true \
DISAGG_P=true \
VLLM_REPLICA_COUNT_P=1 \
VLLM_REPLICA_COUNT_D=2 \
KV_CACHE_ENABLED=true \
DATA_DIR="${HOME}/llm-d-router/data" \
VLLM_SIM_MODE=random \
MODEL_NAME="meta-llama/Llama-3.1-70B-Instruct" \
VLLM_EXTRA_ARGS_P="--config=/data/70b-h100-tp8-throughput-per-token.yaml --dataset-path=/data/ShareGPT_V3_unfiltered_cleaned_split-converted.sqlite3" \
VLLM_EXTRA_ARGS_D="--config=/data/70b-h100-tp8-throughput-per-token.yaml --dataset-path=/data/ShareGPT_V3_unfiltered_cleaned_split-converted.sqlite3" \
make env-dev-kind

# Start Grafana
docker run \
  --rm \
  --detach \
  --network host \
  --volume ${HOME}/llm-d-router/bench/grafana-provisioning:/etc/grafana/provisioning:ro \
  --env "GF_AUTH_ANONYMOUS_ENABLED=true" \
  --env "GF_AUTH_ANONYMOUS_ORG_ROLE=Admin" \
  --env "GF_AUTH_DISABLE_LOGIN_FORM=true" \
  --name grafana \
  grafana/grafana-oss

# For speeding up startup times, it can be handy to mount its db and auxilary files like:
#   --volume ${HOME}/llm-d-router/data/grafana:/var/lib/grafana \
