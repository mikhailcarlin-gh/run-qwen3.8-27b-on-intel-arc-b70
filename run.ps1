# Start Qwen3.8-27B in Docker - the only command you need.
#
# Builds the image on the first run, checks that Docker is up, that the models
# are in place and that no other llama-server is holding the GPU, then starts
# the container.
#
# Overrides via environment, e.g.:
#   $env:MODELS_DIR = 'D:\models'; $env:PORT = '8080'; .\run.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Image = if ($env:IMAGE) { $env:IMAGE } else { 'qwen3.8-27b-arc:local' }
$Name = if ($env:NAME) { $env:NAME } else { 'qwen3.8-27b' }
$Port = if ($env:PORT) { $env:PORT } else { '8010' }
$ModelsDir = if ($env:MODELS_DIR) { $env:MODELS_DIR } else { $PSScriptRoot }
$ModelPath = if ($env:MODEL_PATH) { $env:MODEL_PATH } else { '/models/Qwen3.8-27B-UD-Q4_K_M.gguf' }
$MmprojPath = if ($env:MMPROJ_PATH) { $env:MMPROJ_PATH } else { '/models/mmproj-Qwen3.8-27B-BF16.gguf' }
$CacheVolume = if ($env:CACHE_VOLUME) { $env:CACHE_VOLUME } else { 'qwen3.8-27b-arc-sycl-cache' }
$ModelUrl = if ($env:MODEL_URL) { $env:MODEL_URL } else { 'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_M.gguf' }
$MmprojUrl = if ($env:MMPROJ_URL) { $env:MMPROJ_URL } else { 'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-BF16.gguf' }

function Stop-WithError([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

# Host path behind a /models/... container path ('' if not under /models).
function Get-HostPath([string]$ContainerPath) {
    $prefix = '/models/'
    if (-not $ContainerPath.StartsWith($prefix)) { return '' }
    return Join-Path $ModelsDir $ContainerPath.Substring($prefix.Length)
}

# Download with curl: resumable, so an interrupted 15 GB transfer is not lost.
function Get-ModelFile {
    param([string]$Url, [string]$Destination, [switch]$Optional, [string]$Hint = 'the model is ~15 GB')

    $name = Split-Path -Leaf $Destination
    $part = "$Destination.part"
    Write-Host "downloading $name (one-time download; $Hint)" -ForegroundColor Yellow

    $curl = @('-L', '--fail', '--retry', '3', '--retry-delay', '5', '--progress-bar', '-o', $part)
    if ((Test-Path $part) -and (Get-Item $part).Length -gt 0) {
        Write-Host '  resuming an interrupted download' -ForegroundColor DarkGray
        $curl += @('-C', '-')
    }
    $curl += $Url

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # curl reports progress on stderr
    & curl.exe @curl
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous

    if ($code -ne 0) {
        Remove-Item $part -Force -ErrorAction SilentlyContinue
        if ($Optional) {
            Write-Host "warning: could not download $name - continuing without it" -ForegroundColor Yellow
            return
        }
        Stop-WithError "download failed (curl exit $code) - run .\run.ps1 again to retry"
    }
    Move-Item $part $Destination -Force
    Write-Host "  saved: $Destination" -ForegroundColor Green
}

# --- Docker is up? ---
& docker version --format '{{.Server.Version}}' *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-WithError 'Docker is not running - start Docker Desktop and try again'
}

# --- Models present? Download them on a fresh clone. ---
if (-not (Test-Path $ModelsDir)) {
    New-Item -ItemType Directory -Path $ModelsDir -Force | Out-Null
}

$hostModel = Get-HostPath $ModelPath
if ($hostModel -and -not (Test-Path $hostModel)) {
    Get-ModelFile -Url $ModelUrl -Destination $hostModel
}

$hostMmproj = Get-HostPath $MmprojPath
if ($hostMmproj -and -not (Test-Path $hostMmproj)) {
    Get-ModelFile -Url $MmprojUrl -Destination $hostMmproj -Optional -Hint 'the projector is ~0.9 GB'
}

# --- Image present? Build it on the first run. ---
& docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "image $Image not found - building it first (30-60 min: llama.cpp is compiled from source)" -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'docker build failed' }
}

# --- Port free, no other llama-server: one GPU, one model ---
$listener = Get-NetTCPConnection -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($listener) {
    $holder = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $holderName = if ($holder) { $holder.ProcessName } else { 'unknown process' }
    if ($holderName -ne 'llama-server') {
        Stop-WithError "port $Port is already in use by $holderName (pid $($listener.OwningProcess)) - set `$env:PORT to another port"
    }
}

$stale = @(
    if ($listener) { [int]$listener.OwningProcess }
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
) | Sort-Object -Unique

if ($stale.Count -gt 0) {
    $list = ($stale | ForEach-Object { "pid $_" }) -join ', '
    Write-Host "another llama-server is running ($list)." -ForegroundColor Yellow
    Write-Host 'Only one copy of the model fits into the GPU - it has to stop before the container starts.' -ForegroundColor Yellow
    if ([Console]::IsInputRedirected) {
        Stop-WithError 'stop it and run .\run.ps1 again'
    }
    $answer = Read-Host 'Stop it now? [y/N]'
    if ($answer -notmatch '^([yY]|[yY][eE][sS])$') {
        Stop-WithError 'cancelled - nothing was started'
    }
    foreach ($stalePid in $stale) {
        Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
}

# --- Launch ---
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

Write-Host "Starting qwen3.8-27b on http://127.0.0.1:$Port (Ctrl+C to stop)" -ForegroundColor Cyan
Write-Host 'The first prompt after a rebuild is slow: SYCL compiles its kernels.' -ForegroundColor DarkGray
Write-Host ''

# The server logs to stderr; keep it as plain output, not PowerShell errors.
$ErrorActionPreference = 'Continue'
& docker @dockerArgs
$code = $LASTEXITCODE

if ($code -eq 139 -or $code -eq 137) {
    Write-Host ''
    Write-Host "llama-server died at the GPU allocation (exit $code)." -ForegroundColor Yellow
    Write-Host 'That is the out-of-VRAM signature: another model still holds the GPU - stop it,' -ForegroundColor Yellow
    Write-Host 'or lower $env:CONTEXT (e.g. 32768) to fit into the free memory.' -ForegroundColor Yellow
}

exit $code
