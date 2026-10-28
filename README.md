# llama.cpp + SYCL + Qwen3.6-35B-A3B on Intel Arc Pro B70

One-line launcher for running [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on the **SYCL backend** with **Qwen3.6-35B-A3B** entirely on an **Intel Arc Pro B70** GPU. Drop the files, run the script, get an OpenAI-compatible endpoint on `http://127.0.0.1:8010`.

## Why this exists

llama.cpp's default builds use the **Vulkan** backend. SYCL is the backend that actually gets the most out of Xe2 GPUs, but requires a dedicated build, environment variables, and launch flags that are easy to get wrong. There's also a known Vulkan regression ([#28721](https://github.com/ggml-org/llama.cpp/issues/28721)) that causes a noticeable performance drop.

This repo packages the correct SYCL build, environment setup, and launch flags for this specific model and GPU.

## Requirements

**Common:**
- Intel Arc Pro B70 (32 GB) or another Arc/Xe2 GPU with ≥24 GB VRAM (model ≈ 21 GB in UD-Q4_K_M)
- Recent Intel GPU driver providing Level Zero runtime

**Windows:**
- Windows 11 x64, PowerShell 5.1+ (built-in is fine)
- No oneAPI installation needed — the Windows SYCL archive bundles everything

**Linux:**
- Bash + `ss` (from `iproute2`) or `lsof`
- **Intel oneAPI runtime required:** `libsycl.so.9`, `libmkl_*.so`, `libtbb.so.12`, `libze_loader.so.1`
- User must be in `render` and `video` groups

## Quick start

### 1. Download llama.cpp SYCL build

```
mkdir -p llama
```

| OS | File | Link |
| --- | --- | --- |
| Windows | `llama-b11576-bin-win-sycl-x64.zip` | [releases/b11576](https://github.com/ggml-org/llama.cpp/releases/tag/b11576) (page 9) |
| Linux (fp16, recommended) | `llama-b11576-bin-ubuntu-sycl-fp16-x64.tar.gz` | [same page](https://github.com/ggml-org/llama.cpp/releases/tag/b11576) |
| Linux (fp32) | `llama-b11576-bin-ubuntu-sycl-fp32-x64.tar.gz` | [same page](https://github.com/ggml-org/llama.cpp/releases/tag/b11576) |

Extract contents **directly into `llama/`** (no extra subdirectory):

```bash
# Linux example
tar -xzf llama-b11576-bin-ubuntu-sycl-fp16-x64.tar.gz --strip-components=1 -C llama
```

The result must be `llama/llama-server` (Linux) or `llama\llama-server.exe` (Windows). Newer SYCL builds work too — just ensure `sycl` is in the filename.

### 2. Download the model

Get [Qwen3.6-35B-A3B-UD-Q4_K_M.gguf](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/blob/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf) (~21 GB) and save it as `model/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf`.

**For image input**, also download the multimodal projector
[mmproj-BF16.gguf](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/blob/main/mmproj-BF16.gguf)
(~860 MB) as `model/mmproj-BF16.gguf`. The main GGUF is text-only on its own;
the projector is what adds vision. The launchers add `-mm` automatically when
this file is present.

### 3. Run

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\start.ps1

# Linux
./start.sh
```

| Endpoint | URL |
| --- | --- |
| Web UI | http://127.0.0.1:8010 |
| OpenAI API | http://127.0.0.1:8010/v1 (model: `qwen3.6-35b-a3b`) |
| Health | http://127.0.0.1:8010/health |
| Metrics | http://127.0.0.1:8010/metrics |

Model loads in ~25 seconds. The script also kills any stale `llama-server` holding port 8010 before starting.

## Configuration

### Environment variables

| Variable | Value | Purpose |
| --- | --- | --- |
| `ONEAPI_DEVICE_SELECTOR` | `level_zero:gpu` | Use Level Zero driver (not OpenCL) |
| `ZES_ENABLE_SYSMAN` | `1` | Enable GPU memory/frequency monitoring |
| `SYCL_CACHE_PERSISTENT` | `1` | Cache compiled kernels across runs |
| `SYCL_CACHE_DIR` | `./cache/sycl` | Kernel cache directory |

### Launch flags

| Flag | Value | Purpose |
| --- | --- | --- |
| `-ngl` | `99` | All layers on GPU |
| `-c` | `131072` | 128K context |
| `-ctk` / `-ctv` | `q8_0` | Quantized KV cache (fits 128K in 32 GB) |
| `-fa` | `on` | Flash attention (required for quantized KV cache) |
| `-b` / `-ub` | `8192` / `4096` | Batch and micro-batch for prompt processing |
| `-t` | `8` | CPU threads (tuned for 6P+4E; adjust to your CPU) |
| `--parallel` | `1` | One request at a time |
| `-mm` | `model/mmproj-BF16.gguf` | Multimodal projector — enables image input (auto-added when the file exists) |
| `--jinja` | — | Chat template from GGUF metadata |
| `--no-warmup` | — | Skip warm-up pass (SYCL cache handles it) |
| `--no-reasoning-preserve` | — | Do not feed previous reasoning back into the prompt |
| `--slot-save-path` | `./cache/llama-slots` | Saved slots (prompt/KV snapshots) |
| `--metrics` | — | Expose `/metrics` |

See the `.ps1` / `.sh` file for the full command line.

## Troubleshooting

- **`Model not found`** — check that `llama-server` is directly under `llama/`, not in a subdirectory.
- **GPU not visible to SYCL** — Windows: run `llama\sycl-ls.exe`. Linux: `llama/llama-server --list-devices`. Your Arc card should appear under Level Zero.
- **`libsycl.so.9` missing (Linux)** — install Intel oneAPI Base Toolkit or `intel-oneapi-runtime-*` packages. Run `ldd llama/llama-server | grep 'not found'` to see what's missing.
- **`libze_loader.so.1` missing (Linux)** — install `intel-level-zero-gpu` / `libze1`.
- **Out of memory** — lower `-c` or use a smaller quantization. At 128K context with `q8_0` KV cache, the model + cache use most of 32 GB.
- **Slow (Vulkan build)** — make sure you downloaded the SYCL build, not Vulkan. See [#28721](https://github.com/ggml-org/llama.cpp/issues/28721).

## Repository layout

```
├─ start.ps1                Windows launcher
├─ start.sh                 Linux launcher
├─ llama/                   (gitignored) SYCL build
├─ model/                   (gitignored) GGUF model
└─ cache/                   (gitignored) runtime cache
```

## References

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)
- [Qwen3.6-35B-A3B GGUF (unsloth)](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF)
- [Vulkan performance regression #28721](https://github.com/ggml-org/llama.cpp/issues/28721)
