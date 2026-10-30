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

Everything downloaded stays out of git (see `.gitignore`), and `cache/` holds saved slots and compiled SYCL kernels so restarts are fast. If the GPU isn't detected, run `sycl-ls` from the build folder; on Linux a missing `libsycl.so.9` or `libze_loader.so.1` means the oneAPI or Level Zero runtime isn't installed. For the full list of launch flags, read `start.ps1` / `start.sh`.
