#!/usr/bin/env bash
set -euo pipefail

# --- Paths ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Pinned llama.cpp SYCL build - run ./setup.sh to download it.
LLAMA_BUILD="b11953"
LLAMA_DIR="$SCRIPT_DIR/llama-${LLAMA_BUILD}-bin-ubuntu-sycl-fp16-x64"
SERVER_BIN="$LLAMA_DIR/llama-server"
MODEL_PATH="$SCRIPT_DIR/Qwen3.8-27B-UD-Q4_K_M.gguf"
MMPROJ_PATH="$SCRIPT_DIR/mmproj-Qwen3.8-27B-BF16.gguf"
SLOTS_DIR="$SCRIPT_DIR/cache/llama-slots"
SYCL_CACHE="$SCRIPT_DIR/cache/sycl"

# --- Port and address ---
HOST_ADDR="127.0.0.1"
PORT=8010
CONTEXT=131072

# --- Checks ---
if [[ ! -x "$SERVER_BIN" ]]; then
    echo "error: $SERVER_BIN is missing or not executable - run ./setup.sh to download the pinned Linux SYCL build" >&2
    exit 1
fi
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "error: model not found at $MODEL_PATH - run ./setup.sh to download the GGUF" >&2
    exit 1
fi

# --- Port ---
# A leftover process from a previous run of this script holds the port: stop it.
# Servers listening on other ports are left alone.
port_used() {
    ss -ltnH 2>/dev/null | awk -v p=":${PORT}" '$4 ~ (p "$")' | grep -q .
}

listener_pids() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnpH 2>/dev/null | awk -v p=":${PORT}" '$4 ~ (p "$")' \
            | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
    elif command -v lsof >/dev/null 2>&1; then
        lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null
    fi
}

existing="$(listener_pids || true)"
if [[ -n "$existing" ]]; then
    for pid in $existing; do
        exe="$(basename "$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo unknown)" 2>/dev/null || true)"
        if [[ "$exe" == "llama-server" ]]; then
            echo "Port $PORT held by stale llama-server pid $pid - stopping it"
            kill "$pid" 2>/dev/null || true
        else
            echo "Port $PORT held by pid $pid ($exe) - leaving it alone"
        fi
    done

    # Give the stopped process time to release the port (the model takes ~25 s to load).
    for ((i = 0; i < 30; i++)); do
        port_used || break
        sleep 1
    done
    if port_used; then
        echo "warning: port $PORT is still in use" >&2
        exit 1
    fi
fi

# The server may not have bound the port yet - also check by name and port argument.
for pid in $(pgrep -x llama-server 2>/dev/null || true); do
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" =~ --port[=[:space:]]+$PORT([[:space:]]|$) ]]; then
        echo "Stopping leftover llama-server pid $pid"
        kill "$pid" 2>/dev/null || true
    else
        echo "Keeping llama-server pid $pid - it serves another port"
    fi
done

# --- SYCL environment ---
mkdir -p "$SLOTS_DIR" "$SYCL_CACHE"

# Level Zero only: skip the OpenCL adapter of the same GPU.
export ONEAPI_DEVICE_SELECTOR="level_zero:gpu"
export ZES_ENABLE_SYSMAN="1"
# Keep compiled SYCL kernels between runs, otherwise the first tokens are slow.
export SYCL_CACHE_PERSISTENT="1"
export SYCL_CACHE_DIR="$SYCL_CACHE"

# --- Start ---
echo "Starting llama-server on $HOST_ADDR:$PORT"
echo "  Model:                  $MODEL_PATH"
echo "  Alias:                  qwen3.8-27b"
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
    echo "  Vision:                 disabled (mmproj not found, see README)"
fi

exec "$SERVER_BIN" \
    -m "$MODEL_PATH" \
    -a qwen3.8-27b \
    --host "$HOST_ADDR" --port "$PORT" \
    -ngl 99 -c "$CONTEXT" \
    -ctk q8_0 -ctv q8_0 -fa on \
    -b 8192 -ub 4096 \
    -t 8 --parallel 1 \
    --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.1 \
    --jinja --no-warmup --reasoning-format none \
    --slot-save-path "$SLOTS_DIR" \
    ${VISION_ARGS[@]+"${VISION_ARGS[@]}"} \
    --metrics
