#!/usr/bin/env bash
set -euo pipefail

# Container entrypoint - the llama-server launch, driven by environment
# variables (defaults in the Dockerfile).

# --- Config (env overrides) ---
: "${MODEL_PATH:=/models/Qwen3.8-27B-UD-Q4_K_M.gguf}"
: "${MMPROJ_PATH:=/models/mmproj-Qwen3.8-27B-BF16.gguf}"
: "${MODEL_ALIAS:=qwen3.8-27b}"
: "${HOST_ADDR:=0.0.0.0}"
: "${PORT:=8010}"
: "${CONTEXT:=131072}"
: "${NGL:=99}"
: "${CT_K:=q8_0}"
: "${CT_V:=q8_0}"
: "${FA:=on}"
: "${BATCH:=8192}"
: "${UBATCH:=4096}"
: "${THREADS:=8}"
: "${PARALLEL:=1}"
: "${SLOTS_DIR:=/cache/llama-slots}"
: "${SYCL_CACHE:=/cache/sycl}"
# Extra llama-server arguments, e.g. LLAMA_EXTRA_ARGS="--log-disable"
: "${LLAMA_EXTRA_ARGS:=}"

SERVER_BIN=/app/llama-server

# --- Checks ---
if [[ ! -x "$SERVER_BIN" ]]; then
    echo "error: $SERVER_BIN is missing - rebuild the image" >&2
    exit 1
fi
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "error: model not found at $MODEL_PATH" >&2
    echo "       mount the GGUFs at /models (see run.ps1 / run.sh)" >&2
    exit 1
fi

# Missing shared libraries surface as cryptic errors once the server is
# running - fail fast instead, with the exact list.
missing="$(ldd "$SERVER_BIN" 2>/dev/null | awk '/not found/ {print $1}' || true)"
if [[ -n "$missing" ]]; then
    echo "error: llama-server has unresolved libraries:" >&2
    echo "$missing" >&2
    exit 1
fi

# --- SYCL environment ---
# Level Zero only: skip the OpenCL adapter of the same GPU.
export ONEAPI_DEVICE_SELECTOR="level_zero:gpu"
export ZES_ENABLE_SYSMAN="1"
# Keep compiled SYCL kernels between runs, otherwise the first tokens are slow.
export SYCL_CACHE_PERSISTENT="1"
export SYCL_CACHE_DIR="$SYCL_CACHE"
mkdir -p "$SLOTS_DIR" "$SYCL_CACHE"

# Diagnostics: which devices the SYCL runtime sees. On WSL2/Docker Desktop
# the Arc card appears through /dev/dxg (WSL2 paravirtual driver), on
# bare metal through /dev/dri.
echo "--- sycl-ls ---"
/app/sycl-ls || echo "warning: sycl-ls reports no devices - check GPU passthrough (compose profile)"
echo

echo "Starting llama-server on $HOST_ADDR:$PORT"
echo "  Model:                  $MODEL_PATH"
echo "  Alias:                  $MODEL_ALIAS"
echo "  Context:                $CONTEXT"
echo "  MTP (speculative):      enabled (draft-mtp, n-max=2)"
echo "  Reasoning format:       none (inline think tags)"
echo "  SYCL_CACHE_PERSISTENT:  $SYCL_CACHE_PERSISTENT"

# Vision: the multimodal projector (mmproj) enables image input.
# Without it llama-server runs text-only and the API rejects images.
VISION_ARGS=()
if [[ -f "$MMPROJ_PATH" ]]; then
    echo "  Vision:                 enabled ($MMPROJ_PATH)"
    VISION_ARGS=(-mm "$MMPROJ_PATH")
else
    echo "  Vision:                 disabled (mmproj not found at $MMPROJ_PATH)"
fi

# shellcheck disable=SC2086  # word splitting of LLAMA_EXTRA_ARGS is intended
exec "$SERVER_BIN" \
    -m "$MODEL_PATH" \
    -a "$MODEL_ALIAS" \
    --host "$HOST_ADDR" --port "$PORT" \
    -ngl "$NGL" -c "$CONTEXT" \
    -ctk "$CT_K" -ctv "$CT_V" -fa "$FA" \
    -b "$BATCH" -ub "$UBATCH" \
    -t "$THREADS" --parallel "$PARALLEL" \
    --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.1 \
    --jinja --no-warmup --reasoning-format none \
    --slot-save-path "$SLOTS_DIR" \
    ${VISION_ARGS[@]+"${VISION_ARGS[@]}"} \
    --metrics \
    $LLAMA_EXTRA_ARGS
