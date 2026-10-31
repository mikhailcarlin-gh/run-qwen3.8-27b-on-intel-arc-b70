# Qwen3.8-27B on Intel Arc Pro B70

Serves **Qwen3.8-27B** with `llama-server` (llama.cpp, **SYCL** backend) fully on an Intel Arc GPU, in Docker.

One command does everything: downloads the model, builds the image (`llama.cpp` is compiled inside), starts the server.

## Requirements

- Intel Arc / Xe2 GPU with at least 24 GB of VRAM (Arc Pro B70: 32 GB) and a recent driver with Level Zero
- Docker — Docker Desktop with the WSL2 backend on Windows, Docker Engine + Intel GPU driver on Linux
- ~31 GB of free disk: 16 GB for the models, 15 GB for the image

## Start

```powershell
.\run.ps1        # Windows
```

```bash
./run.sh         # Linux
```

The first run takes a while, in three steps:

1. downloads the two GGUFs into the repository root (~16 GB, resumes if interrupted),
2. builds the image (~30–60 min — `llama.cpp` is compiled from source),
3. starts the server.

Later runs go straight to step 3: everything already present is reused.

## Use

| Endpoint | URL |
| --- | --- |
| Web UI | http://127.0.0.1:8010 |
| OpenAI API | http://127.0.0.1:8010/v1 — model name `qwen3.8-27b` |
| Health / metrics | http://127.0.0.1:8010/health · http://127.0.0.1:8010/metrics |

```bash
curl http://127.0.0.1:8010/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Hello"}]}'
```

Ctrl+C stops the container and removes it. The port is published on `127.0.0.1` only: no API key is set, so the server is not exposed to the network.

## Settings

Everything is optional — the defaults work as is. On PowerShell set `$env:NAME = 'value'` before `.\run.ps1`, on Linux prefix the command (`NAME=value ./run.sh`).

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODELS_DIR` | repository root | host folder mounted at `/models` |
| `MODEL_PATH` | `/models/Qwen3.8-27B-UD-Q4_K_M.gguf` | model path inside the container |
| `MMPROJ_PATH` | `/models/mmproj-Qwen3.8-27B-BF16.gguf` | vision projector (`mmproj`) inside the container |
| `MODEL_ALIAS` | `qwen3.8-27b` | model name in the API |
| `CONTEXT` | `131072` | context size (128K) |
| `PORT` | `8010` | host port |
| `LLAMA_EXTRA_ARGS` | — | extra `llama-server` flags, e.g. `--log-disable` |
| `MODEL_URL` / `MMPROJ_URL` | `unsloth/Qwen3.8-27B-GGUF` | where the files are downloaded from |

The remaining launch flags (`NGL`, `CT_K`/`CT_V`, `FA`, `BATCH`, `UBATCH`, `THREADS`, `PARALLEL`) are documented with their defaults at the top of `entrypoint.sh`.

To run a different model, put the GGUF anywhere and point the script at it:

```powershell
$env:MODELS_DIR = 'D:\models'
$env:MODEL_PATH = '/models/my-model.gguf'
$env:MODEL_ALIAS = 'my-model'
.\run.ps1
```

## Rebuild

The image is built once. Rebuild it with `build.ps1` / `build.sh` — for example after moving to another `llama.cpp` release:

```powershell
.\build.ps1 --build-arg LLAMA_REF=b12000
```

## Troubleshooting

- **The GPU is not detected.** The container prints `sycl-ls` on every start; the list must contain `[level_zero:gpu]`. Check it separately:

  ```powershell
  docker run --rm --entrypoint /app/sycl-ls --device /dev/dxg `
    -v /usr/lib/wsl/lib:/usr/lib/wsl/lib:ro -v /usr/lib/wsl/drivers:/usr/lib/wsl/drivers:ro `
    qwen3.8-27b-arc:local
  ```

  On Linux use `--device /dev/dri/renderD128 --device /dev/dri/card0 --group-add <render-gid>` instead. No device = the driver/WSL2 is outdated (reboot Windows) or the `render` group is missing.

- **One model at a time.** Weights plus the 128K KV cache take most of the 32 GB, so a second copy does not fit. If another `llama-server` is running, the script offers to stop it; if the container dies with exit code 139/137, the GPU is out of memory — free it or lower `CONTEXT`.

- **The first answer is slow.** SYCL compiles its kernels on first use; they are cached in a Docker volume, so later starts are fast.

- **Disk usage.** `docker system df` shows the image; the model files stay in `MODELS_DIR` and are not copied into the image.
