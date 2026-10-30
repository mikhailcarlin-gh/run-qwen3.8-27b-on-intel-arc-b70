#!/usr/bin/env bash
set -euo pipefail

# Download the pinned llama.cpp SYCL build and the Qwen3.8-27B GGUFs.
# Run once after cloning:  ./setup.sh     (add --force to re-download everything)

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

# --- Pinned versions ---
# The launchers expect exactly this build directory, so bump both files together.
LLAMA_BUILD="b11953"
LLAMA_ASSET="llama-${LLAMA_BUILD}-bin-ubuntu-sycl-fp16-x64"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_DIR="$SCRIPT_DIR/$LLAMA_ASSET"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/${LLAMA_ASSET}.tar.gz"

HF_REPO="https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main"
# Remote name on Hugging Face -> local file name (the mmproj file is renamed).
MODEL_FILES=(
    "Qwen3.8-27B-UD-Q4_K_M.gguf Qwen3.8-27B-UD-Q4_K_M.gguf"  # ~15 GB, text model
    "mmproj-BF16.gguf mmproj-Qwen3.8-27B-BF16.gguf"          # ~0.9 GB, vision projector
)

fetch() {
    local url="$1" dest="$2"

    if [[ -f "$dest" && "$FORCE" -eq 0 ]]; then
        echo "  exists, skipping: $dest"
        return
    fi

    local part="$dest.part"
    if [[ "$FORCE" -eq 1 ]]; then
        rm -f "$dest" "$part"
    fi

    echo "  downloading: $url"
    # Resume an interrupted download instead of starting over.
    if [[ -s "$part" ]]; then
        curl -L --fail --retry 3 --retry-delay 5 -C - -o "$part" "$url"
    else
        curl -L --fail --retry 3 --retry-delay 5 -o "$part" "$url"
    fi
    mv "$part" "$dest"
}

install_llama() {
    if [[ -x "$LLAMA_DIR/llama-server" && "$FORCE" -eq 0 ]]; then
        echo "  exists, skipping: $LLAMA_DIR"
        return
    fi

    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" EXIT

    local tgz="$tmp/$LLAMA_ASSET.tar.gz"
    fetch "$LLAMA_URL" "$tgz"
    tar -xzf "$tgz" -C "$tmp"

    local src
    # `|| true` keeps pipefail from aborting when head closes the pipe early.
    src="$(find "$tmp" -type f -name llama-server -exec dirname {} \; | head -n1 || true)"
    if [[ -z "$src" ]]; then
        echo "error: llama-server not found inside the archive" >&2
        exit 1
    fi

    rm -rf "$LLAMA_DIR"
    mv "$src" "$LLAMA_DIR"
    chmod +x "$LLAMA_DIR"/llama-* 2>/dev/null || true
    echo "  installed: $LLAMA_DIR"
}

echo "llama.cpp $LLAMA_BUILD ($LLAMA_ASSET)"
install_llama

echo "Qwen3.8-27B GGUFs"
for pair in "${MODEL_FILES[@]}"; do
    read -r remote local_name <<< "$pair"
    fetch "$HF_REPO/$remote" "$SCRIPT_DIR/$local_name"
done

echo
echo "Setup complete. Start the server with: ./start.sh"
