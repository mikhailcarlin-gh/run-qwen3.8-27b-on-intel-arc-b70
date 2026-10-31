#!/usr/bin/env bash
# Run llama-server from the image with the repository root (or MODELS_DIR)
# mounted at /models. The platform is detected automatically:
#   /dev/dxg (Windows: Docker Desktop / WSL2 backend) or /dev/dri (bare metal).
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

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "error: image $IMAGE not found - run ./build.sh first" >&2
    exit 1
fi

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
    echo "error: no GPU found: neither /dev/dxg (WSL2) nor /dev/dri (Linux)" >&2
    exit 1
fi

exec docker "${args[@]}" "$IMAGE"
