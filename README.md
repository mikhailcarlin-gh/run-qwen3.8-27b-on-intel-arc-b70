# Run Qwen3.8-27B on Intel Arc Pro B70

Launcher for [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on the **SYCL backend** with **Qwen3.8-27B** fully on an **Intel Arc Pro B70** GPU. SYCL is the backend that gets the most out of Xe2 cards, and this repo pins the right build, environment and flags behind one command. It needs an Arc/Xe2 GPU with at least 24 GB of VRAM (the B70 has 32 GB), a recent Intel driver with Level Zero, and about 16 GB of free disk space; on Linux the oneAPI runtime and membership in the `render`/`video` groups are also required.

```bash
# Windows
powershell -ExecutionPolicy Bypass -File .\setup.ps1
powershell -ExecutionPolicy Bypass -File .\start.ps1

# Linux
./setup.sh
./start.sh
```

`setup` downloads the pinned llama.cpp SYCL build (`b11953`) and both GGUF files into the repository root — about 16 GB, resumed if interrupted and skipped if already present (`-Force` / `--force` re-downloads). `start` launches the server on `127.0.0.1:8010` (local only) with 128K context, Flash Attention, a quantized KV cache, MTP speculative decoding and vision enabled through the `mmproj` projector; it also kills a stale `llama-server` holding the port. The build version is pinned in `setup.*`, `start.*` and `.gitignore`, so bump all of them together.

| Endpoint | URL |
| --- | --- |
| Web UI | http://127.0.0.1:8010 |
| OpenAI API | http://127.0.0.1:8010/v1 (model `qwen3.8-27b`) |
| Health / Metrics | http://127.0.0.1:8010/health · http://127.0.0.1:8010/metrics |

Notes:

- **Stop:** the server runs in the foreground — stop it with Ctrl+C; the next `start` also kills a stale `llama-server` holding the port.
- **First run:** the first prompt after a fresh setup is slow while SYCL compiles its kernels (`--no-warmup` skips the warmup pass); the kernel cache lives in `cache/sycl` and survives restarts, so later starts are fast.
- **Reasoning:** `--reasoning-format none` keeps the model's thinking inline in `content` (in `think` tags) instead of a separate `reasoning_content` field, which some API clients fragment token by token.
- **Slots:** `--slot-save-path` points at `cache/llama-slots`, where the server writes saved slot state.
- **Performance (B70):** decoding ~37 t/s at short context, degrading to 17–20 t/s around 111k tokens of context.

## Docker

Same launch, different packaging: `llama.cpp` is built from source (SYCL + FP16, the same flags as the pinned release build) at image build time, while the model files stay on the host — mounted read-only at `/models`, never baked in.

```bash
# Windows (Docker Desktop, WSL2 backend)
docker compose --profile wsl2 up --build

# Linux (bare metal, Intel GPU driver installed)
docker compose --profile linux up --build
```

> **One instance at a time.** Weights plus the 131k-token KV cache occupy most of the GPU's VRAM, so a second copy — Docker next to `start.sh`, or vice versa — does not fit on a 32 GB Arc. Stop the other launcher before `up`ing, or the two fight over VRAM and the GPU OOM-kills them in a crash loop (processes die silently at the big allocations, no error in the logs).

- First `up` pulls the oneAPI base images and compiles llama.cpp — plan for ~30–60 min. Later `up` reuses the image; rebuild only after bumping `LLAMA_REF` in the `Dockerfile` (keep it in sync with `LLAMA_BUILD` in `setup.*` / `start.*`).
- `MODELS_DIR` (env var, defaults to this repo's root) is mounted at `/models`; `MODEL_PATH` / `MMPROJ_PATH` pick the files inside (defaults match the names `setup.*` downloads). To run a different GGUF, drop it into `MODELS_DIR` and point `MODEL_PATH` at it.
- The SYCL kernel cache lives in the named volume `sycl-cache`: the first prompt compiles the kernels, later starts are fast — same behavior as `cache/sycl` above.
- GPU passthrough: the `wsl2` profile uses `/dev/dxg` + the WSL driver mounts (no privileged mode; verified with an Arc Pro B70 in [microsoft/WSL#41376](https://github.com/microsoft/WSL/issues/41376)); the `linux` profile uses `/dev/dri/renderD128` + `card0` and the `render` group.
- Check the GPU is visible before the first run (the entrypoint also prints `sycl-ls` output on every start):

  ```bash
  docker compose --profile wsl2 run --rm --entrypoint /app/sycl-ls wsl2
  ```

  No `level_zero` device in the output = passthrough is not set up yet (on WSL2: Intel graphics driver and WSL2 must be current, reboot Windows if needed; on Linux: check the `render` group and the `/dev/dri` nodes).

Everything downloaded stays out of git (see `.gitignore`), and `cache/` holds saved slots and compiled SYCL kernels so restarts are fast. If the GPU isn't detected, run `sycl-ls` from the build folder; on Linux a missing `libsycl.so.9` or `libze_loader.so.1` means the oneAPI or Level Zero runtime isn't installed. For the full list of launch flags, read `start.ps1` / `start.sh`.
