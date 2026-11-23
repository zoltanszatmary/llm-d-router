#!/usr/bin/env bash

# Minimal benchmark for the two llm-d Router scenarios on the kind testbed.
#
# It sends two phases of chat requests and measures, from Prometheus, how
# request serving benefits from the llm-d plugins:
#
#   cold  - a prefix never seen before this run.
#   warm  - a prefix reused across requests.
#
# Expected: warm shows a higher prefix-cache hit rate and lower time-to-first-
# token than cold (the precise-prefix-cache plugin paying off), while every
# request is split into prefill + decode by the P/D decider plugin.
#
# Run bench/setup.sh first. Watch it live in Grafana (see bench/README.md).
# Results: bench/results/results.csv and results.png.

set -euo pipefail

TARGET="${TARGET:-http://localhost:30080}"
MODEL="${MODEL:-meta-llama/Llama-3.1-70B-Instruct}"
PROM="${PROM:-http://localhost:30090}"
OUTPUT_DIR="${OUTPUT_DIR:-./bench/results}"
REQUESTS_PER_PHASE="${REQUESTS_PER_PHASE:-15}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${OUTPUT_DIR}"

snap_prom() {
  local out="$1"
  python3 - "$PROM" "$out" <<'PY'
import json, sys, urllib.parse, urllib.request
prom, out = sys.argv[1], sys.argv[2]
metrics = [
    "llm_d_epp_disagg_decision_total",
    "llm_d_epp_prefix_predicted_cached_tokens_sum",
    "llm_d_epp_prefix_prompt_tokens_sum",
    "vllm:prefix_cache_hits_total",
    "vllm:prefix_cache_queries_total",
    "vllm:time_to_first_token_seconds_sum",
    "vllm:time_to_first_token_seconds_count",
]
snap = {}
for m in metrics:
    q = urllib.parse.urlencode({"query": m})
    with urllib.request.urlopen(f"{prom}/api/v1/query?{q}", timeout=15) as r:
        res = json.load(r)["data"]["result"]
    d = {}
    for s in res:
        lbls = ",".join(f'{k}="{v}"' for k, v in sorted(s["metric"].items()) if k != "__name__")
        d[lbls] = float(s["value"][1])
    snap[m] = d
json.dump(snap, open(out, "w"))
PY
}

SHARED_PREFIX="$(python3 -c 'print("In an llm-d disaggregated deployment the endpoint picker routes by prefix cache locality. " * 14, end="")')"

send_one() {
  local content="$1" body
  body="$(python3 - "$MODEL" "$content" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "messages": [{"role": "user", "content": sys.argv[2]}],
                  "max_tokens": 4, "temperature": 0, "stream": False}))
PY
)"
  curl -sS -m 90 -o /dev/null -w "%{http_code}" "${TARGET}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "${body}" || echo 000
}

run_phase() {
  local name="$1" mode="$2" n="${REQUESTS_PER_PHASE}" ok=0 fail=0 content
  echo "==> phase '${name}' (${n} requests)"
  snap_prom "${OUTPUT_DIR}/.snap_${name}_before.json"
  for ((i = 1; i <= n; i++)); do
    case "${mode}" in
      cold) content="Cold $(python3 -c "import time;print(time.time())")-${i}: $(python3 -c "print('unique uncached token '*30)")#${i}" ;;
      warm) content="${SHARED_PREFIX} summarize routing in one sentence." ;;
    esac
    [ "$(send_one "${content}")" = "200" ] && ok=$((ok + 1)) || fail=$((fail + 1))
    sleep 1
  done
  sleep 20  # exceed Prometheus scrape interval (15s) so the after-snapshot
            # captures every increment from this phase's requests
  snap_prom "${OUTPUT_DIR}/.snap_${name}_after.json"
  echo "    ${ok} ok, ${fail} failed"
}

run_phase cold cold
run_phase warm warm
python3 "${SCRIPT_DIR}/analyze.py" report "${OUTPUT_DIR}" cold warm
rm -f "${OUTPUT_DIR}"/.snap_*.json
