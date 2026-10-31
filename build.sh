#!/usr/bin/env bash
# Build the Qwen3.8-27B image: llama.cpp (SYCL + FP16) is compiled inside.
# The first build takes ~30-60 min, later builds reuse the cached layers.
#
# Extra arguments go to `docker build`, e.g.:
#   ./build.sh --build-arg LLAMA_REF=b12000
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

IMAGE="${IMAGE:-qwen3.8-27b-arc:local}"

echo "Building $IMAGE"
exec docker build -t "$IMAGE" "$@" .
