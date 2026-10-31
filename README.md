# Run Qwen3.8-27B on Intel Arc Pro B70

Docker image that serves **Qwen3.8-27B** with [llama.cpp](https://github.com/ggml-org/llama.cpp)'s `llama-server` on the **SYCL backend**, fully on an **Intel Arc Pro B70**. SYCL is the backend that gets the most out of Xe2 cards, and this repo pins the right build, environment and flags behind two commands.

`llama.cpp` (**b11953**, SYCL + FP16) is compiled from source while the image is built; the model files are never baked in — they are mounted from the repository root at `/models`. Needs an Arc/Xe2 GPU with at least 24 GB of VRAM (the B70 has 32 GB), a recent Intel driver with Level Zero, Docker with GPU passthrough (Docker Desktop on Windows, the Intel GPU driver on Linux), and about 16 GB of disk space for the model files.

## Quick start

1. Put both GGUFs into the repository root (see [Models](#models)).
2. Start the server:

   ```powershell
   .\run.ps1        # Windows     (Linux: ./run.sh)
   ```

That is the only command. On the first run it builds the image (~30–60 min: `llama.cpp` is compiled from source), then starts the container; later runs go straight to the server. Before launching it checks that Docker is running, that the model files are in place, and that nothing else holds the port — if an older `llama-server` does, the script offers to stop it (one GPU, one model).

| Endpoint | URL |
| --- | --- |
| Web UI | http://127.0.0.1:8010 |
| OpenAI API | http://127.0.0.1:8010/v1 (model `qwen3.8-27b`) |
| Health / Metrics | http://127.0.0.1:8010/health · http://127.0.0.1:8010/metrics |

The container runs in the foreground: Ctrl+C stops and removes it, the log is its stdout. The container is published on `127.0.0.1` only — no API key is set, so it is not exposed to the network.

## Scripts

| Script | What it does |
| --- | --- |
| `run.ps1` / `run.sh` | the one command: builds the image if it is missing, checks models, port and Docker, then starts the container with models mounted at `/models` (read-only) and the SYCL cache volume at `/cache` |
| `build.ps1` / `build.sh` | rebuild the image explicitly, e.g. after `--build-arg LLAMA_REF=b12000` (extra arguments are passed to `docker build`) |

`run.*` detects the platform on its own:

- **Windows / Docker Desktop (WSL2 backend)** — passes `/dev/dxg` plus the WSL driver mounts (`/usr/lib/wsl/lib`, `/usr/lib/wsl/drivers`). No privileged mode needed; verified with an Arc Pro B70 in [microsoft/WSL#41376](https://github.com/microsoft/WSL/issues/41376).
- **Bare-metal Linux** — passes `/dev/dri/renderD128` + `/dev/dri/card0` and the `render` group (if your render node is not `renderD128`, check `ls -la /dev/dri`).

## Models

`run.*` mounts the repository root at `/models` and expects the files from [`unsloth/Qwen3.8-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF):

| File | Size | Role |
| --- | --- | --- |
| `Qwen3.8-27B-UD-Q4_K_M.gguf` | ~15 GB | the model |
| `mmproj-Qwen3.8-27B-BF16.gguf` | ~0.9 GB | vision projector (the HF file is `mmproj-BF16.gguf`) |

Paths are set with environment variables, all of them optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODELS_DIR` | repository root | host folder mounted at `/models` |
| `MODEL_PATH` | `/models/Qwen3.8-27B-UD-Q4_K_M.gguf` | model path **inside the container** |
| `MMPROJ_PATH` | `/models/mmproj-Qwen3.8-27B-BF16.gguf` | projector path **inside the container** |
| `MODEL_ALIAS` | `qwen3.8-27b` | model name in the API |

Keeping the files in the repository root is enough — nothing else to configure. To use another folder or another GGUF:

```powershell
$env:MODELS_DIR = 'D:\models'
$env:MODEL_PATH = '/models/Qwen3.8-27B-UD-Q4_K_M.gguf'
.\run.ps1
```

```bash
MODELS_DIR=/data/models MODEL_PATH=/models/my-model.gguf ./run.sh
```

If `MMPROJ_PATH` does not exist the server starts text-only and the API rejects images.

## Launch settings

Every launch flag is an environment variable read by `entrypoint.sh`; the defaults live in the `Dockerfile`. `run.*` forwards these from the host as-is:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONTEXT` | `131072` | context size (128K) |
| `NGL` | `99` | layers offloaded to the GPU |
| `CT_K` / `CT_V` | `q8_0` | KV cache quantization |
| `FA` | `on` | Flash Attention |
| `BATCH` / `UBATCH` | `8192` / `4096` | prompt batch sizes |
| `THREADS` / `PARALLEL` | `8` / `1` | CPU threads / parallel slots |
| `LLAMA_EXTRA_ARGS` | — | extra `llama-server` arguments, e.g. `--log-disable` |
| `PORT` | `8010` | host port to publish |
| `IMAGE` / `NAME` | `qwen3.8-27b-arc:local` / `qwen3.8-27b` | image and container names |
| `CACHE_VOLUME` | `qwen3.8-27b-arc-sycl-cache` | named volume for the SYCL cache |

Example — a smaller context to free VRAM:

```powershell
$env:CONTEXT = '32768'
.\run.ps1
```

## Checking GPU passthrough

The entrypoint prints `sycl-ls` output on every start; the device list must contain `[level_zero:gpu]`. To check without starting the server:

```powershell
# Windows (Docker Desktop, WSL2 backend)
docker run --rm --entrypoint /app/sycl-ls `
  --device /dev/dxg `
  -v /usr/lib/wsl/lib:/usr/lib/wsl/lib:ro `
  -v /usr/lib/wsl/drivers:/usr/lib/wsl/drivers:ro `
  qwen3.8-27b-arc:local
```

```bash
# Linux (bare metal)
docker run --rm --entrypoint /app/sycl-ls \
  --device /dev/dri/renderD128 --device /dev/dri/card0 \
  --group-add "$(stat -c '%g' /dev/dri/renderD128)" \
  qwen3.8-27b-arc:local
```

No `level_zero` device = passthrough is not set up yet (on WSL2: the Intel graphics driver and WSL2 must be current, reboot Windows if needed; on Linux: check the `render` group and the `/dev/dri` nodes).

## Notes

- **One instance at a time.** Weights plus the 131k-token KV cache occupy most of the GPU's VRAM, so a second copy — another container, or a native `llama-server` — does not fit on a 32 GB Arc. Two instances fight over VRAM and the GPU OOM-kills them in a crash loop (processes die silently at the big allocations, no error in the logs).
- **First prompt is slow**: SYCL compiles its kernels on first use. The cache lives in the `sycl-cache` volume, so later starts are fast. `--no-warmup` skips the warmup pass.
- **Version pinning**: `LLAMA_REF` (Dockerfile) is the only place the `llama.cpp` release appears — bump it with `.\build.ps1 --build-arg LLAMA_REF=b12000` and rebuild.
- **Reasoning**: `--reasoning-format none` keeps the model's thinking inline in `content` (in `think` tags) instead of a separate `reasoning_content` field, which some API clients fragment token by token.
- **Slots**: saved slot state is written to `/cache/llama-slots` inside the cache volume.
- **Performance (B70)**: decoding ~37 t/s at short context, degrading to 17–20 t/s around 111k tokens of context.
