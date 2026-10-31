#!/usr/bin/env bash
# Start Qwen3.8-27B in Docker - the only command you need.
#
# Builds the image on the first run, checks that Docker is up, that the models
# are in place and that no other llama-server is holding the GPU, then starts
# the container. The platform is detected automatically: /dev/dxg (WSL2 /
# Docker Desktop) or /dev/dri (bare metal).
#
# Overrides via environment, e.g.:
#   MODELS_DIR=/data/models PORT=8080 ./run.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-qwen3.8-27b-arc:local}"
NAME="${NAME:-qwen3.8-27b}"
PORT="${PORT:-8010}"
MODELS_DIR="${MODELS_DIR:-$SCRIPT_DIR}"
MODEL_PATH="${MODEL_PATH:-/models/Qwen3.8-27B-UD-Q4_K_M.gguf}"
MMPROJ_PATH="${MMPROJ_PATH:-/models/mmproj-Qwen3.8-27B-BF16.gguf}"
CACHE_VOLUME="${CACHE_VOLUME:-qwen3.8-27b-arc-sycl-cache}"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Host path behind a /models/... container path.
host_path() {
    case "$1" in
        /models/*) echo "$MODELS_DIR/${1#/models/}" ;;
        *) echo "" ;;
    esac
}

# --- Docker is up? ---
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    || fail "Docker is not running - start the Docker daemon and try again"

# --- Models present? ---
model_file="$(host_path "$MODEL_PATH")"
if [[ -n "$model_file" && ! -f "$model_file" ]]; then
    fail "model not found: $model_file
       put the GGUF files into $MODELS_DIR (see README, Models)"
fi
mmproj_file="$(host_path "$MMPROJ_PATH")"
if [[ -n "$mmproj_file" && ! -f "$mmproj_file" ]]; then
    echo "warning: vision projector not found: $mmproj_file - running text-only" >&2
fi

# --- Image present? Build it on the first run. ---
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image $IMAGE not found - building it first (30-60 min: llama.cpp is compiled from source)"
    bash "$SCRIPT_DIR/build.sh" || fail "docker build failed"
fi

# --- Port free, no other llama-server: one GPU, one model ---
listener_pid=""
if command -v ss >/dev/null 2>&1; then
    listener_pid="$(ss -ltnpH 2>/dev/null | awk -v p=":${PORT}" '$4 ~ (p "$")' \
        | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -n1 || true)"
elif command -v lsof >/dev/null 2>&1; then
    listener_pid="$(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n1 || true)"
fi

stale=()
if [[ -n "$listener_pid" ]]; then
    holder="$(ps -p "$listener_pid" -o comm= 2>/dev/null || echo 'unknown process')"
    if [[ "$holder" != *llama-server* ]]; then
        fail "port $PORT is already in use by $holder (pid $listener_pid) - set PORT to another port"
    fi
    stale+=("$listener_pid")
fi
while read -r pid; do
    [[ -n "$pid" ]] && stale+=("$pid")
done < <(pgrep -x llama-server 2>/dev/null || true)

if (( ${#stale[@]} > 0 )); then
    stale=($(printf '%s\n' "${stale[@]}" | sort -u))
    echo "another llama-server is running (pid ${stale[*]})." >&2
    echo "Only one copy of the model fits into the GPU - it has to stop before the container starts." >&2
    if [[ ! -t 0 ]]; then
        fail "stop it and run ./run.sh again"
    fi
    read -r -p "Stop it now? [y/N] " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || fail "cancelled - nothing was started"
    for pid in "${stale[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    sleep 3
fi

# --- Launch ---
args=(run --rm -i --name "$NAME"
      --publish "127.0.0.1:${PORT}:8010"
      --env "PORT=8010"
      --env "MODEL_PATH=$MODEL_PATH"
      --env "MMPROJ_PATH=$MMPROJ_PATH"
      --volume "$MODELS_DIR:/models:ro"
      --volume "$CACHE_VOLUME:/cache")

# Interactive terminal: keep the progress output readable.
if [[ -t 0 && -t 1 ]]; then
    args+=(-t)
fi

# Anything set on the host is forwarded as-is (defaults live in the Dockerfile).
for var in CONTEXT NGL CT_K CT_V FA BATCH UBATCH THREADS PARALLEL \
           MODEL_ALIAS LLAMA_EXTRA_ARGS; do
    if [[ -n "${!var:-}" ]]; then
        args+=(--env "$var=${!var}")
    fi
done

if [[ -e /dev/dxg ]]; then
    # Windows: Docker Desktop (WSL2 backend). The Arc card is reached through
    # the paravirtual dxg device, the Level Zero userspace comes from the WSL
    # driver mounts. No privileged mode needed (microsoft/WSL#41376).
    args+=(--device /dev/dxg
           --volume /usr/lib/wsl/lib:/usr/lib/wsl/lib:ro
           --volume /usr/lib/wsl/drivers:/usr/lib/wsl/drivers:ro)
elif [[ -d /dev/dri ]]; then
    # Bare metal: i915 driver + render group (check the node names with ls -la /dev/dri).
    args+=(--device /dev/dri/renderD128 --device /dev/dri/card0)
    args+=(--group-add "$(stat -c '%g' /dev/dri/renderD128)")
else
    fail "no GPU found: neither /dev/dxg (WSL2) nor /dev/dri (Linux)"
fi

echo "Starting qwen3.8-27b on http://127.0.0.1:$PORT (Ctrl+C to stop)"
echo "The first prompt after a rebuild is slow: SYCL compiles its kernels."
echo

set +e
docker "${args[@]}" "$IMAGE"
code=$?
set -e

if [[ $code -eq 139 || $code -eq 137 ]]; then
    echo >&2
    echo "llama-server died at the GPU allocation (exit $code)." >&2
    echo "That is the out-of-VRAM signature: another model still holds the GPU - stop it," >&2
    echo "or lower CONTEXT (e.g. 32768) to fit into the free memory." >&2
fi

exit $code
