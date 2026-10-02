#!/usr/bin/env bash
# item-1 repro: A (backend sampling + post_sampling_probs) -> B (grammar that throws at init)
# -> C (same params, post_sampling_probs false). On the buggy PR, C returns 32x token 0.
set -u
BIN=${BIN:-$HOME/strix/build-pr-274/bin/llama-server}
MODEL=${MODEL:-$HOME/strix/models/Qwen_Qwen3-0.6B-Q8_0.gguf}
PORT=${PORT:-30274}
LOG=${LOG:-$HOME/strix/measure/repro274.log}
P=~/strix/measure
mkdir -p "$P"

A='{"backend_sampling":true,"n_probs":5,"post_sampling_probs":true,"samplers":["top_k","temperature"],"temperature":0.8,"seed":1,"n_predict":32,"prompt":"The history of the city of Rome begins","cache_prompt":false,"return_tokens":true,"id_slot":0}'
B=$(python3 -c "import json;d=json.load(open('$P/a.json'));d['grammar']='root ::= (';print(json.dumps(d))" 2>/dev/null || true)
C='{"backend_sampling":true,"n_probs":5,"post_sampling_probs":false,"samplers":["top_k","temperature"],"temperature":0.8,"seed":1,"n_predict":32,"prompt":"The history of the city of Rome begins","cache_prompt":false,"return_tokens":true,"id_slot":0}'

echo "$A" > "$P/a.json"
python3 - "$P" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p + "/a.json"))
d["grammar"] = "root ::= ("
json.dump(d, open(p + "/b.json", "w"))
PY
B=$(cat "$P/b.json")

"$BIN" -m "$MODEL" -ngl 99 -fa on -c 4096 -np 1 -sps 0 --no-cache-prompt --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
    sleep 1
done

run() { curl -s -m 120 -H "Content-Type: application/json" -d "$1" "http://127.0.0.1:$PORT/completion"; }

echo "== A (expect normal text)"
run "$A" | python3 -c "import json,sys;d=json.load(sys.stdin);print('tokens:', d.get('tokens', [])[:8]);print('content:', d.get('content','')[:60])"
echo "== B (expect 400 grammar parse error)"
run "$B" | head -c 200; echo
echo "== C (the buggy path: expect normal text after the fix)"
run "$C" | python3 -c "
import json,sys
d=json.load(sys.stdin)
toks=d.get('tokens', [])
print('tokens:', toks[:8])
uniq=len(set(toks))
print('unique_tokens:', uniq, 'of', len(toks))
print('VERDICT:', 'FIXED' if uniq > 2 else 'STILL BROKEN (repeated token)')"

# fresh C for reference
echo "== C on fresh server (reference)"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
"$BIN" -m "$MODEL" -ngl 99 -fa on -c 4096 -np 1 -sps 0 --no-cache-prompt --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
SRV=$!
for _ in $(seq 1 120); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
run "$C" | python3 -c "import json,sys;d=json.load(sys.stdin);print('tokens:', d.get('tokens', [])[:8])"
kill $SRV 2>/dev/null
