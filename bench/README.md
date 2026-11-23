# llm-d Router benchmark: two scenarios

A minimal demonstration that request serving benefits from two llm-d Router
plugins on the kind testbed:

- **Precise prefix caching** (`precise-prefix-cache-producer`): reusing a cached
  prefix raises the prefix-cache hit rate and lowers time-to-first-token.
- **P/D disaggregation** (`prefix-based-pd-decider`): requests are split into a
  prefill stage and a decode stage.

## Run

```sh
./bench/setup.sh                 # kind cluster (P/D + KV cache), Prometheus, Grafana
./bench/illustrative-benchmark.sh
```

The benchmark sends two phases, `cold` (a prefix never seen) and `warm` (a
prefix reused), and prints a table plus writes `bench/results/results.{csv,png}`.

Example:

```
=== llm-d scenarios: cold vs warm prefix ===
  phase  engine cache hit  EPP cached (prefill)  mean TTFT  prefill-decode
  -----  ----------------  --------------------  ---------  --------------
  cold   <lower>           <lower>               <higher>   15
  warm   <higher>          <higher>              <lower>    15
```

The `warm` row having a higher hit rate and lower TTFT than `cold` is the
payoff. Every request is `prefill-decode`, the disaggregation signal.

## Verify in Grafana

Open http://localhost:3000 (anonymous admin). Metrics are per-request, so run
the benchmark first, then set the time range to **Last 15 minutes**.

### Purpose-built dashboard

**Dashboards -> "llm-d Scenarios: P/D Disaggregation and Precise Prefix
Caching"** panels exactly the signals this benchmark uses:

- *Engine prefix-cache hit rate* and *EPP cached-token ratio (prefill)* rise
  during the warm phase. These are Scenario A.
- *Disaggregation decisions* shows `prefill-decode`. This is Scenario B.
- *Mean time-to-first-token* drops as the cache warms.

### Built-in llm-d dashboards that also populate

- **"llm-d Performance Dashboard"**: the prefix-cache hit panels
  (`vllm:prefix_cache_hits_total`), KV-cache usage, and TTFT histograms. This is
  the llm-d-recommended view of caching and latency.
- **"llm-d Router"**: EPP request totals, queue sizes, and KV utilization
  (`llm_d_epp_*`).
- **"llm-d vLLM Overview"**: prompt/generation token counters and TTFT from the
  simulator.

### Dashboards that stay empty, and why

- **"llm-d P/D Coordinator Metrics"** queries `vllm:nixl_*`. The simulator models
  the P/D KV transfer as latency only and moves no real KV bytes, so it emits no
  NIXL metrics. Disaggregation itself is still real; see the Scenarios dashboard.

## Scope and limitations

- **Decode-only decisions are not shown.** With the chat template even a short
  prompt tokenizes above the decider threshold (~16 tokens), so every request
  disaggregates. The benchmark reports the `prefill-decode` count rather than
  fabricating a decode-only case.
- **The EPP cached-token ratio is read on the prefill pod.** In the decode pod a
  routing sidecar owns the pool port (8000) while the simulator serves behind it
  (8200), so the EPP (addressing decode at 8000) does not match the decode
  simulator's KV events (published on 8200). The prefill pod has no sidecar and
  matches; since the prefix is processed on the prefill pod in a P/D split, that
  is the correct place to read the EPP's cache view. The simulator's own
  `vllm:prefix_cache_*` metrics are unaffected and populate on both roles.

## Files

- `setup.sh` - brings up the testbed (edit env vars here to change the model,
  replica counts, etc.).
- `illustrative-benchmark.sh` - runs the two phases and calls the analyzer.
- `analyze.py` - diffs the Prometheus snapshots, writes the table and plot.
- `grafana-provisioning/` - datasource and dashboards (auto-loaded by setup.sh).
- `dataset-transformation-pipeline.sh` - builds the shared ShareGPT dataset.
