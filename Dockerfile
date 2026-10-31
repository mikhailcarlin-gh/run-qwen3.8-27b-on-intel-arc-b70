# Qwen3.8-27B on an Intel Arc GPU (SYCL/Level Zero).
#
# llama.cpp is built from source in this image - the model files are NOT
# baked in, they are mounted at /models (see docker-compose.yml).
#
#   Windows (Docker Desktop, WSL2 backend):  docker compose --profile wsl2  up --build
#   Linux (bare metal):                      docker compose --profile linux up --build
#
# Pinned to the same llama.cpp release as setup.* / start.* (LLAMA_BUILD).
# Bump all of them together.

ARG LLAMA_REF=b11953
ARG ONEAPI_VERSION=2026.1.1-devel-ubuntu24.04
# Matches the pinned "sycl-fp16" release build - FP16 accumulators for SYCL.
ARG GGML_SYCL_F16=ON

# ---------- Build stage: llama.cpp with the SYCL backend ----------
FROM docker.io/intel/deep-learning-essentials:${ONEAPI_VERSION} AS build

ARG LLAMA_REF
ARG GGML_SYCL_F16
ARG LEVEL_ZERO_VERSION=1.28.2
ARG LEVEL_ZERO_UBUNTU_VERSION=u24.04

# oneDNN (GPU build) - required by the SYCL backend for flash attention.
# Same offline installer as llama.cpp's own .devops/intel.Dockerfile.
RUN echo "Download oneDNN installation package" && \
    wget https://registrationcenter-download.intel.com/akdlm/IRC_NAS/94c3dbac-0852-45be-a57d-21c204cada3e/intel-onednn-2026.0.2.46_offline.sh -O intel-onednn_offline.sh && \
    echo "Install oneDNN components" && \
    bash intel-onednn_offline.sh -s -a --silent --eula accept

# Level Zero loader + headers (the SYCL backend links against ze_loader).
RUN apt-get update && \
    apt-get install -y git libssl-dev wget ca-certificates && \
    cd /tmp && \
    wget -q "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/level-zero_${LEVEL_ZERO_VERSION}%2B${LEVEL_ZERO_UBUNTU_VERSION}_amd64.deb" -O level-zero.deb && \
    wget -q "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/level-zero-devel_${LEVEL_ZERO_VERSION}%2B${LEVEL_ZERO_UBUNTU_VERSION}_amd64.deb" -O level-zero-devel.deb && \
    apt-get -o Dpkg::Options::="--force-overwrite" install -y ./level-zero.deb ./level-zero-devel.deb && \
    rm -f /tmp/level-zero.deb /tmp/level-zero-devel.deb

WORKDIR /app
RUN git clone --depth 1 --branch "${LLAMA_REF}" https://github.com/ggml-org/llama.cpp .

RUN if [ "${GGML_SYCL_F16}" = "ON" ]; then \
        echo "GGML_SYCL_F16 is set" \
        && export OPT_SYCL_F16="-DGGML_SYCL_F16=ON" \
        && export SYCL_PROGRAM_COMPILE_OPTIONS="-cl-fp32-correctly-rounded-divide-sqrt"; \
    fi && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_SYCL=ON \
          -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
          -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DLLAMA_BUILD_TESTS=OFF ${OPT_SYCL_F16} && \
    cmake --build build --config Release -j$((($(nproc)+1)/2))

# llama-server, sycl-ls (diagnostics, from the oneAPI compiler package) and
# every shared library the build produced (ggml backends, SYCL/MKL/TBB/UR
# runtime). Backends are dlopen'ed from the executable's directory at
# runtime, so they must travel next to llama-server.
RUN cp -L "$(command -v sycl-ls)" /app/sycl-ls && \
    mkdir -p /app/lib && find build -name "*.so*" -exec cp -P {} /app/lib \; && \
    cp build/bin/llama-server /app/

# ---------- Runtime stage: server + Intel GPU runtime ----------
FROM docker.io/intel/oneapi-toolkit:${ONEAPI_VERSION} AS runtime

# Neo runtime (Level Zero ICD, IGC, ocloc) for bare-metal Linux.
# On WSL2/Docker Desktop the GPU is reached through /dev/dxg instead -
# see the "wsl2" profile in docker-compose.yml.
# Same versions as llama.cpp's own .devops/intel.Dockerfile.
ARG IGC_VERSION=v2.34.4
ARG IGC_VERSION_FULL=2_2.34.4+21428
ARG COMPUTE_RUNTIME_VERSION=26.18.38308.1
ARG COMPUTE_RUNTIME_VERSION_FULL=26.18.38308.1-0
ARG IGDGMM_VERSION=22.10.0
RUN mkdir /tmp/neo/ && cd /tmp/neo/ \
  && wget https://github.com/intel/intel-graphics-compiler/releases/download/$IGC_VERSION/intel-igc-core-${IGC_VERSION_FULL}_amd64.deb \
  && wget https://github.com/intel/intel-graphics-compiler/releases/download/$IGC_VERSION/intel-igc-opencl-${IGC_VERSION_FULL}_amd64.deb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/intel-ocloc-dbgsym_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.ddeb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/intel-ocloc_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.deb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/intel-opencl-icd-dbgsym_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.ddeb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/intel-opencl-icd_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.deb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/libigdgmm12_${IGDGMM_VERSION}_amd64.deb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/libze-intel-gpu1-dbgsym_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.ddeb \
  && wget https://github.com/intel/compute-runtime/releases/download/$COMPUTE_RUNTIME_VERSION/libze-intel-gpu1_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.deb \
  && dpkg --install *.deb \
  && rm -rf /tmp/neo

RUN apt-get update \
    && apt-get install -y curl libgomp1 \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

WORKDIR /app
COPY --from=build /app/lib/ /app/
COPY --from=build /app/llama-server /app/sycl-ls /app/
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Defaults mirror start.sh - override per container or via the compose file.
ENV MODEL_PATH=/models/Qwen3.8-27B-UD-Q4_K_M.gguf \
    MMPROJ_PATH=/models/mmproj-Qwen3.8-27B-BF16.gguf \
    MODEL_ALIAS=qwen3.8-27b \
    HOST_ADDR=0.0.0.0 \
    PORT=8010 \
    CONTEXT=131072

EXPOSE 8010

HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=3 \
    CMD curl -fsS http://127.0.0.1:8010/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
