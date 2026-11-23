#!/usr/bin/env python3
"""Scrape Prometheus and render the benchmark table and plot.

  report OUTDIR NAME1 NAME2    diff each phase's before/after snapshots
                               (OUTDIR/.snap_<name>_{before,after}.json, written
                               by illustrative-benchmark.sh), then write
                               results.csv and results.png.

Signals (all emitted by the EPP or the simulator, verified live):
  llm_d_epp_disagg_decision_total{decision_type}      P/D routing decisions
  llm_d_epp_prefix_predicted_cached_tokens_sum        EPP predicted cache (prefill)
  llm_d_epp_prefix_prompt_tokens_sum                  EPP prompt tokens (prefill)
  vllm:prefix_cache_hits_total / _queries_total       engine cache hit rate
  vllm:time_to_first_token_seconds_{sum,count}        TTFT (latency payoff)
"""

import json
import sys
from collections import defaultdict


def label(labelset, key):
    for part in labelset.split(","):
        if part.startswith(key + "="):
            return part.split("=", 1)[1].strip('"')
    return None


def total(metric_map, role=None):
    s = 0.0
    for ls, v in metric_map.items():
        if role is None or label(ls, "endpoint_role") == role or label(ls, "llm_d_ai_role") == role:
            s += v
    return s


def diff(before, after):
    out = defaultdict(dict)
    for name, amap in after.items():
        for ls, v in amap.items():
            out[name][ls] = v - before.get(name, {}).get(ls, 0.0)
    return out


def summarize(d):
    """One phase delta -> the numbers the table and plot use."""
    # Scenario A, EPP view: predicted-cached share of prompt tokens on prefill.
    epp_cached = total(d["llm_d_epp_prefix_predicted_cached_tokens_sum"])
    epp_prompt = total(d["llm_d_epp_prefix_prompt_tokens_sum"])
    epp_ratio = epp_cached / epp_prompt if epp_prompt else 0.0

    # Scenario A, engine view: simulator's own prefix-cache hit rate.
    eng_hits = total(d["vllm:prefix_cache_hits_total"])
    eng_q = total(d["vllm:prefix_cache_queries_total"])
    eng_ratio = eng_hits / eng_q if eng_q else 0.0

    # Latency payoff: mean TTFT over the phase (histogram sum/count delta).
    ttft_sum = total(d["vllm:time_to_first_token_seconds_sum"])
    ttft_cnt = total(d["vllm:time_to_first_token_seconds_count"])
    ttft_ms = (ttft_sum / ttft_cnt * 1000.0) if ttft_cnt else 0.0

    # Scenario B: disaggregation decisions.
    dec = defaultdict(float)
    for ls, v in d["llm_d_epp_disagg_decision_total"].items():
        dec[label(ls, "decision_type") or "?"] += v

    return {
        "epp_cached_ratio": epp_ratio,
        "engine_hit_ratio": eng_ratio,
        "ttft_ms": ttft_ms,
        "prefill_decode": dec.get("prefill-decode", 0.0),
        "decode_only": dec.get("decode-only", 0.0),
    }


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "report":
        outdir, names = sys.argv[2], sys.argv[3:]
        phases = {}
        for n in names:
            b = json.load(open(f"{outdir}/.snap_{n}_before.json"))
            a = json.load(open(f"{outdir}/.snap_{n}_after.json"))
            phases[n] = summarize(diff(b, a))

        hdr = ["phase", "engine cache hit", "EPP cached (prefill)", "mean TTFT", "prefill-decode"]
        rows = [
            [n,
             f"{phases[n]['engine_hit_ratio']:.1%}",
             f"{phases[n]['epp_cached_ratio']:.1%}",
             f"{phases[n]['ttft_ms']:.0f} ms",
             f"{phases[n]['prefill_decode']:.0f}"]
            for n in names
        ]
        w = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(hdr)]
        print("\n=== llm-d scenarios: cold vs warm prefix ===")
        print("  " + "  ".join(h.ljust(w[i]) for i, h in enumerate(hdr)))
        print("  " + "  ".join("-" * w[i] for i in range(len(hdr))))
        for r in rows:
            print("  " + "  ".join(r[i].ljust(w[i]) for i in range(len(hdr))))
        print("\n  Benefit: reusing a cached prefix raises the hit rate and lowers TTFT,")
        print("  while every request is disaggregated (prefill-decode) by the P/D decider.")

        with open(f"{outdir}/results.csv", "w") as f:
            f.write(",".join(hdr) + "\n")
            for r in rows:
                f.write(",".join(x.replace(" ms", "") if i == 3 else x for i, x in enumerate(r)) + "\n")

        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        x = range(len(names))
        colors = ["#e76f51", "#2a9d8f", "#264653", "#e9c46a"]
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4.6))

        # Left: cache hit rate (engine) and cached ratio (EPP), both cold->warm.
        bw = 0.38
        eng = [phases[n]["engine_hit_ratio"] for n in names]
        epp = [phases[n]["epp_cached_ratio"] for n in names]
        ax1.bar([i - bw / 2 for i in x], eng, bw, label="engine hit rate", color="#2a9d8f")
        ax1.bar([i + bw / 2 for i in x], epp, bw, label="EPP cached ratio (prefill)", color="#8ecae6")
        ax1.set_xticks(list(x)); ax1.set_xticklabels(names)
        ax1.set_ylim(0, 1); ax1.set_ylabel("ratio")
        ax1.set_title("Prefix cache effectiveness (higher = better)")
        ax1.legend()
        for i in x:
            ax1.text(i - bw / 2, eng[i] + 0.02, f"{eng[i]:.0%}", ha="center", fontsize=9)
            ax1.text(i + bw / 2, epp[i] + 0.02, f"{epp[i]:.0%}", ha="center", fontsize=9)

        # Right: mean TTFT per phase (the latency payoff; lower = better).
        ttft = [phases[n]["ttft_ms"] for n in names]
        bars = ax2.bar(list(x), ttft, color=colors[: len(names)])
        ax2.set_xticks(list(x)); ax2.set_xticklabels(names)
        ax2.set_ylabel("mean time-to-first-token (ms)")
        ax2.set_title("Latency payoff (lower = better)")
        for b, t in zip(bars, ttft):
            ax2.text(b.get_x() + b.get_width() / 2, t, f"{t:.0f}", ha="center", va="bottom", fontsize=9)

        fig.tight_layout()
        fig.savefig(f"{outdir}/results.png", dpi=130)
        print(f"\nWrote {outdir}/results.csv and {outdir}/results.png")
        return

    print(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
