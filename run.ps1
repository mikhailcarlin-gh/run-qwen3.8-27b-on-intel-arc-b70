# Run llama-server from the image with the repository root (or MODELS_DIR)
# mounted at /models. Windows: Docker Desktop with the WSL2 backend - the GPU
# is reached through the paravirtual /dev/dxg device.
#
# Overrides via environment, e.g.:
#   $env:MODELS_DIR = 'D:\models'; .\run.ps1
$ErrorActionPreference = 'Stop'

$Image = if ($env:IMAGE) { $env:IMAGE } else { 'qwen3.8-27b-arc:local' }
$Name = if ($env:NAME) { $env:NAME } else { 'qwen3.8-27b' }
$Port = if ($env:PORT) { $env:PORT } else { '8010' }
$ModelsDir = if ($env:MODELS_DIR) { $env:MODELS_DIR } else { $PSScriptRoot }
$ModelPath = if ($env:MODEL_PATH) { $env:MODEL_PATH } else { '/models/Qwen3.8-27B-UD-Q4_K_M.gguf' }
$MmprojPath = if ($env:MMPROJ_PATH) { $env:MMPROJ_PATH } else { '/models/mmproj-Qwen3.8-27B-BF16.gguf' }
$CacheVolume = if ($env:CACHE_VOLUME) { $env:CACHE_VOLUME } else { 'qwen3.8-27b-arc-sycl-cache' }

& docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "image $Image not found - run .\build.ps1 first"
    exit 1
}

$dockerArgs = @(
    'run', '--rm', '-i', '--name', $Name,
    '--publish', "127.0.0.1:${Port}:8010",
    '--env', 'PORT=8010',
    '--env', "MODEL_PATH=$ModelPath",
    '--env', "MMPROJ_PATH=$MmprojPath",
    '--volume', "${ModelsDir}:/models:ro",
    '--volume', "${CacheVolume}:/cache"
)

# Anything set on the host is forwarded as-is (defaults live in the Dockerfile).
foreach ($var in 'CONTEXT', 'NGL', 'CT_K', 'CT_V', 'FA', 'BATCH', 'UBATCH',
                 'THREADS', 'PARALLEL', 'MODEL_ALIAS', 'LLAMA_EXTRA_ARGS') {
    $value = [Environment]::GetEnvironmentVariable($var)
    if ($value) {
        $dockerArgs += @('--env', "$var=$value")
    }
}

$dockerArgs += @(
    '--device', '/dev/dxg',
    '--volume', '/usr/lib/wsl/lib:/usr/lib/wsl/lib:ro',
    '--volume', '/usr/lib/wsl/drivers:/usr/lib/wsl/drivers:ro',
    $Image
)

# The server logs to stderr; keep it as plain output, not PowerShell errors.
$ErrorActionPreference = 'Continue'
& docker @dockerArgs
exit $LASTEXITCODE
