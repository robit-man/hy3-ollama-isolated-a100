#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${HY3_ENDPOINT_URL:-http://127.0.0.1:11453}"
MODEL="${HY3_MODEL:-/srv/hy3/hy3-1M-Q2_K.gguf}"
EXPECTED_CTX="${HY3_EXPECTED_CTX:-262000}"
MAX_TOKENS="${HY3_MAX_TOKENS:-48}"
LOAD_TIMEOUT_SEC="${HY3_LOAD_TIMEOUT_SEC:-600}"
TMP_RESPONSE="$(mktemp)"
trap 'rm -f "$TMP_RESPONSE"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for endpoint verification"
  exit 1
fi

echo "Loading on demand and checking ${ENDPOINT}/v1/models"
models="$(curl -fsS --max-time "$LOAD_TIMEOUT_SEC" "${ENDPOINT}/v1/models")"
echo "Model metadata:"
echo "$models" | jq -c '.data[0] // .'

echo "Checking ${ENDPOINT}/health"
health="$(curl -fsS --max-time 10 "${ENDPOINT}/health")"
echo "$health"

reported_ctx="$(echo "$models" | jq -r '.data[0].meta.n_ctx // .data[0].meta.n_ctx_train // .data[0].context_length // empty')"
if [[ -z "$reported_ctx" || "$reported_ctx" == "null" ]]; then
  echo "ERROR: /v1/models did not report meta.n_ctx, meta.n_ctx_train, or context_length"
  exit 1
fi
if [[ "$reported_ctx" =~ ^[0-9]+$ ]] && (( reported_ctx < EXPECTED_CTX )); then
  echo "ERROR: reported context ${reported_ctx} is below expected ${EXPECTED_CTX}"
  exit 1
fi
echo "Context window reported: ${reported_ctx} tokens"

payload="$(jq -nc \
  --arg model "$MODEL" \
  --arg prompt "Return exactly this JSON and nothing else: {\"hy3\":\"ok\",\"answer\":42}" \
  --argjson max_tokens "$MAX_TOKENS" \
  '{model:$model,prompt:$prompt,max_tokens:$max_tokens,temperature:0,seed:7,stream:false}')"

echo "Running OpenAI-compatible completion"
start_ns="$(date +%s%N)"
curl -fsS --max-time 900 -o "$TMP_RESPONSE" \
  -X POST "${ENDPOINT}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "$payload"
end_ns="$(date +%s%N)"

completion="$(jq -r '.choices[0].text // .choices[0].message.content // empty' "$TMP_RESPONSE")"
if [[ -z "$completion" ]]; then
  echo "ERROR: completion response did not contain text"
  cat "$TMP_RESPONSE"
  exit 1
fi

completion_tokens="$(jq -r '.usage.completion_tokens // empty' "$TMP_RESPONSE")"
elapsed="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN {printf "%.3f", (e-s)/1000000000}')"
if [[ "$completion_tokens" =~ ^[0-9]+$ ]] && (( completion_tokens > 0 )); then
  tps="$(awk -v t="$completion_tokens" -v s="$elapsed" 'BEGIN {printf "%.2f", t/s}')"
else
  tps="n/a"
fi

echo "Completion:"
echo "$completion"
echo "Usage: $(jq -c '.usage // {}' "$TMP_RESPONSE")"
echo "Wall time: ${elapsed}s; completion tok/s: ${tps}"

echo "GPU process snapshot:"
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader 2>/dev/null || true
echo "Endpoint smoke test passed."
