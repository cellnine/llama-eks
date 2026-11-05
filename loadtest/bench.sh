#!/usr/bin/env bash
# Benchmark sweep: fixed prompt and output length from 1 to 16 concurrent
# virtual users. Writes a TSV per level plus a summary table.
#
# Env:
#   GW_BASE       gateway base URL (default http://localhost:8080)
#   API_KEY       raw API key
#   PER_TEST_SEC  60
#   MAX_TOKENS    64
#   LEVELS        optional override, e.g. "1 2 4 8 16"
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p results

GW_BASE="${GW_BASE:-http://localhost:8080}"
API_KEY="${API_KEY:?API_KEY required}"
PER_TEST_SEC="${PER_TEST_SEC:-60}"
MAX_TOKENS="${MAX_TOKENS:-64}"
LEVELS="${LEVELS:-1 2 4 8 16}"
MODEL_PRICES="${MODEL_PRICES:-}"

TSV="results/bench.tsv"
echo -e "concurrency\trequests\tp50_ms\tp95_ms\trps\ttok_per_sec\t429\t200\tother" > "$TSV"

for c in $LEVELS; do
  echo "== concurrency $c =="
  OUT="results/run_c${c}.txt"
  CONCURRENCY=$c GW_BASE="$GW_BASE" API_KEY="$API_KEY" \
    PER_TEST_SEC="$PER_TEST_SEC" MAX_TOKENS="$MAX_TOKENS" \
    k6 run --quiet load.js | tee "$OUT"

  # parse from k6 output; latencies in ms are printed by k6 as e.g. 1.2s / 345 ms
  p50=$(grep -oE 'http_req_duration[^;]*"p\(50\)"=[0-9.]+(ms|s)' "$OUT" | grep -oE '[0-9.]+' | tr '\n' ' ' | awk '{print $NF}')
  p95=$(grep -oE 'http_req_duration[^;]*"p\(95\)"=[0-9.]+(ms|s)' "$OUT" | grep -oE '[0-9.]+' | tr '\n' ' ' | awk '{print $NF}')
  req=$(grep -oE 'http_reqs[[:blank:]]*[0-9]+' "$OUT" | grep -oE '[0-9]+' | tail -1 || echo 0)
  rps=$(grep -oE 'http_reqs[^0-9]*[0-9.]+/s' "$OUT" | grep -oE '[0-9.]+/s' | tr -d '/s' || echo 0)
  c200=$(grep -oE 'responses_200[^0-9]*[0-9]+' "$OUT" | grep -oE '[0-9]+' | tail -1 || echo 0)
  c429=$(grep -oE 'responses_429[^0-9]*[0-9]+' "$OUT" | grep -oE '[0-9]+' | tail -1 || echo 0)
  coth=$(grep -oE 'responses_other[^0-9]*[0-9]+' "$OUT" | grep -oE '[0-9]+' | tail -1 || echo 0)

  to_ms() { case "$1" in *s) echo "${1%s}";; *) echo "$1";; esac; }
  p50ms=$(to_ms "$p50"); p95ms=$(to_ms "$p95")

  total_req=$((c200 + c429 + coth))
  tps=$(awk -v c="$c" -v tok="$MAX_TOKENS" -v dur="$PER_TEST_SEC" 'BEGIN {print c * tok / dur}')
  printf "%s\t%s\t%s\t%s\t%s\t%.1f\t%s\t%s\t%s\n" "$c" "$total_req" "$p50ms" "$p95ms" "$rps" "$tps" "$c429" "$c200" "$coth" >> "$TSV"
done

echo
echo "== summary (loadtest/$TSV) =="
column -t -s$'\t' "$TSV"
echo "tokens/sec are aggregate throughput: concurrency x MAX_TOKENS / duration."
