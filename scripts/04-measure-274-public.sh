#!/usr/bin/env bash
# PR #274 A/B on the public model (Qwen3-0.6B Q8_0), ROCm, bs off/on.
# 50 sequential short requests x 3 runs per cell + sched_reserve counts (-lv 4 run).
set -u
MODEL=${MODEL:-$HOME/strix/models/Qwen_Qwen3-0.6B-Q8_0.gguf}
OUT=${OUT:-$HOME/strix/measure/274-public}
mkdir -p "$OUT"
REQ='{"prompt":"Tell me a fact about cats.","n_predict":8,"temperature":0.8,"seed":42,"id_slot":0,"cache_prompt":false,"return_tokens":true}'
PORT=30274

run_cell() { # label bin bs
    local label=$1 bin=$2 bs=$3 extra=""
    [ "$bs" = on ] && extra="-bs"
    "$bin" -m "$MODEL" -ngl 99 -fa on -c 4096 -np 1 -sps 0 --no-cache-prompt $extra \
        --host 127.0.0.1 --port "$PORT" > "$OUT/$label.log" 2>&1 &
    local srv=$!
    for _ in $(seq 1 120); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
    for _ in 1 2 3; do curl -s -m 60 -H "Content-Type: application/json" -d "$REQ" "http://127.0.0.1:$PORT/completion" >/dev/null; done
    for r in 1 2 3; do
        : > "$OUT/$label.r$r.txt"
        for _ in $(seq 1 50); do
            curl -s -m 60 -H "Content-Type: application/json" -d "$REQ" \
                "http://127.0.0.1:$PORT/completion" |
                python3 -c "import json,sys; t=json.load(sys.stdin).get('timings', {}); print(t.get('prompt_ms', 0.0) + t.get('predicted_ms', 0.0))" >> "$OUT/$label.r$r.txt"
        done
    done
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
    echo "cell $label done"
}

count_reserves() { # label bin bs
    local label=$1 bin=$2 bs=$3 extra=""
    [ "$bs" = on ] && extra="-bs"
    "$bin" -m "$MODEL" -ngl 99 -fa on -c 4096 -np 1 -sps 0 --no-cache-prompt $extra -v -lv 4 \
        --host 127.0.0.1 --port "$PORT" > "$OUT/$label.lv.log" 2>&1 &
    local srv=$!
    for _ in $(seq 1 120); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
    for _ in $(seq 1 50); do curl -s -m 60 -H "Content-Type: application/json" -d "$REQ" "http://127.0.0.1:$PORT/completion" >/dev/null; done
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
    grep -c "sched_reserve: reserving" "$OUT/$label.lv.log"
}

for bs in off on; do
    for side in mb pr; do
        run_cell "$side-bs$bs" "$HOME/strix/build-$side/bin/llama-server" "$bs"
    done
done

echo "== reserve counts (50 requests, includes startup lines)"
if [ "${SKIP_CNT:-0}" != 1 ]; then
    for bs in off on; do
        for side in mb pr; do
            printf "%s bs=%s reserves: " "$side" "$bs"
            count_reserves "cnt-$side-$bs" "$HOME/strix/build-$side/bin/llama-server" "$bs"
        done
    done
fi

echo "== median ms per request (r1/r2/r3)"
for bs in off on; do
    for side in mb pr; do
        printf "%s bs=%s: " "$side" "$bs"
        for r in 1 2 3; do
            python3 -c "
import statistics
v=[float(x) for x in open('$OUT/$side-bs$bs.r$r.txt') if x.strip()]
print('%.2f' % statistics.median(v), end=' ')"
        done
        echo
    done
done
echo "DONE-274-PUBLIC"
