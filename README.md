# llama.cpp + SYCL + Qwen3.6-35B-A3B on Intel Arc Pro B70

One-line launcher for running [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on the **SYCL backend** with **Qwen3.6-35B-A3B** entirely on an **Intel Arc Pro B70** GPU. Clone the repo, run `setup`, run `start`, get an OpenAI-compatible endpoint on `http://127.0.0.1:8010`.

## Why this exists

llama.cpp's default builds use the **Vulkan** backend. SYCL is the backend that actually gets the most out of Xe2 GPUs, but requires a dedicated build, environment variables, and launch flags that are easy to get wrong. There's also a known Vulkan regression ([#28721](https://github.com/ggml-org/llama.cpp/issues/28721)) that causes a noticeable performance drop.

This repo packages the correct SYCL build, environment setup, and launch flags for this specific model and GPU.

## Requirements

**Common:**
- Intel Arc Pro B70 (32 GB) or another Arc/Xe2 GPU with ≥24 GB VRAM (model ≈ 21 GB in UD-Q4_K_M)
- Recent Intel GPU driver providing Level Zero runtime
- ~23 GB free disk space for the build and both GGUF files

**Windows:**
- Windows 11 x64, PowerShell 5.1+ (built-in is fine)
- No oneAPI installation needed — the Windows SYCL archive bundles everything

**Linux:**
- Bash + `ss` (from `iproute2`) or `lsof`
- **Intel oneAPI runtime required:** `libsycl.so.9`, `libmkl_*.so`, `libtbb.so.12`, `libze_loader.so.1`
- User must be in `render` and `video` groups

## Quick start

### 1. Clone

```bash
git clone https://github.com/mikhailcarlin-gh/run-qwen3.6-35b-a3b-on-intel-arc-b70.git
cd run-qwen3.6-35b-a3b-on-intel-arc-b70
```

### 2. Download the build and the models

```powershell
# Windows
.\setup.ps1
```

```bash
# Linux
./setup.sh
```

`setup` downloads the pinned llama.cpp SYCL build (**b11953**) and both GGUF
files into the repository root — about 22 GB in total:

| File | Size | Purpose |
| --- | --- | --- |
| `llama-b11953-bin-win-sycl-x64/` | 148 MB | Windows SYCL build |
| `llama-b11953-bin-ubuntu-sycl-fp16-x64/` | 62 MB | Linux SYCL build |
| `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf` | 21 GB | the model |
| `mmproj-BF16.gguf` | 861 MB | vision projector (image input) |

Files that already exist are skipped, so re-running `setup` is safe, and an
interrupted download resumes where it stopped. Pass `-Force` (Windows) or
`--force` (Linux) to download everything again.

The build version is pinned in `setup.*`, `start.*`, and `.gitignore`; bump all
of them together when upgrading llama.cpp.

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
| `-mm` | `mmproj-BF16.gguf` | Multimodal projector — enables image input (auto-added when the file exists) |
| `--jinja` | — | Chat template from GGUF metadata |
| `--no-warmup` | — | Skip warm-up pass (SYCL cache handles it) |
| `--no-reasoning-preserve` | — | Do not feed previous reasoning back into the prompt |
| `--slot-save-path` | `./cache/llama-slots` | Saved slots (prompt/KV snapshots) |
| `--metrics` | — | Expose `/metrics` |

See the `.ps1` / `.sh` file for the full command line.

## Troubleshooting

- **`llama-server not found`** — run `setup` (or `setup.ps1`) first; the launcher expects `llama-b11953-bin-win-sycl-x64\llama-server.exe` on Windows and `llama-b11953-bin-ubuntu-sycl-fp16-x64/llama-server` on Linux.
- **GPU not visible to SYCL** — Windows: run `llama-b11953-bin-win-sycl-x64\sycl-ls.exe`. Linux: `llama-b11953-bin-ubuntu-sycl-fp16-x64/llama-server --list-devices`. Your Arc card should appear under Level Zero.
- **`libsycl.so.9` missing (Linux)** — install Intel oneAPI Base Toolkit or `intel-oneapi-runtime-*` packages. Run `ldd llama-b11953-bin-ubuntu-sycl-fp16-x64/llama-server | grep 'not found'` to see what's missing.
- **`libze_loader.so.1` missing (Linux)** — install `intel-level-zero-gpu` / `libze1`.
- **Out of memory** — lower `-c` or use a smaller quantization. At 128K context with `q8_0` KV cache, the model + cache use most of 32 GB.
- **Slow (Vulkan build)** — make sure you downloaded the SYCL build, not Vulkan. See [#28721](https://github.com/ggml-org/llama.cpp/issues/28721).

## Repository layout

```
├─ setup.ps1                          Windows: download SYCL build + GGUFs
├─ setup.sh                           Linux:   download SYCL build + GGUFs
├─ start.ps1                          Windows launcher
├─ start.sh                           Linux launcher
├─ llama-b11953-bin-win-sycl-x64/     (gitignored) Windows SYCL build
├─ llama-b11953-bin-ubuntu-sycl-fp16-x64/  (gitignored) Linux SYCL build
├─ Qwen3.6-35B-A3B-UD-Q4_K_M.gguf     (gitignored) the model
├─ mmproj-BF16.gguf                   (gitignored) vision projector
└─ cache/                             (gitignored) runtime cache
```

`setup` writes all downloads into the repository root, and `.gitignore` lists
each one explicitly so the binaries never end up in a commit.

## References

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)
- [Qwen3.6-35B-A3B GGUF (unsloth)](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF)
- [Vulkan performance regression #28721](https://github.com/ggml-org/llama.cpp/issues/28721)
