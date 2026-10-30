$ScriptDir  = $PSScriptRoot
$LlamaBuild = "b11953"
$LlamaDir   = Join-Path $ScriptDir "llama-$LlamaBuild-bin-win-sycl-x64"
$ServerExe  = Join-Path $LlamaDir "llama-server.exe"
$ModelPath  = Join-Path $ScriptDir "Qwen3.8-27B-UD-Q4_K_M.gguf"
$MmprojPath = Join-Path $ScriptDir "mmproj-Qwen3.8-27B-BF16.gguf"
$SlotsDir   = Join-Path $ScriptDir "cache\llama-slots"
$SyclCache  = Join-Path $ScriptDir "cache\sycl"

$HostAddr = "127.0.0.1"
$Port     = 8010
$Context  = 131072

if (-not (Test-Path $ServerExe)) {
    Write-Error "llama-server.exe not found at $ServerExe - run .\setup.ps1 to download the pinned SYCL build"; exit 1
}
if (-not (Test-Path $ModelPath)) {
    Write-Error "Model not found at $ModelPath - run .\setup.ps1 to download the GGUF"; exit 1
}

$portPattern = "--port\s+$Port" + '(\s|$)'

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    foreach ($ownerPid in @($existing | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'llama-server') {
            Write-Host "Port $Port held by stale llama-server pid $ownerPid - stopping it"
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
        }
    }
}

foreach ($proc in @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -and $cmd -notmatch $portPattern) {
        Write-Host "Keeping llama-server pid $($proc.Id) - it serves another port"
        continue
    }
    Write-Host "Stopping leftover llama-server pid $($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

if ($existing) {
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 1
    }
    $still = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($still) {
        Write-Warning "Port $Port is still in use (PID $($still[0].OwningProcess))"; exit 1
    }
}

New-Item -ItemType Directory -Force -Path $SlotsDir  | Out-Null
New-Item -ItemType Directory -Force -Path $SyclCache | Out-Null

$env:ONEAPI_DEVICE_SELECTOR = "level_zero:gpu"
$env:ZES_ENABLE_SYSMAN      = "1"
$env:SYCL_CACHE_PERSISTENT  = "1"
$env:SYCL_CACHE_DIR         = $SyclCache

Write-Host "Starting llama-server on $HostAddr`:$Port" -ForegroundColor Cyan
Write-Host "  Model:                  $ModelPath" -ForegroundColor DarkGray
Write-Host "  Alias:                  qwen3.8-27b" -ForegroundColor DarkGray
Write-Host "  Context:                $Context" -ForegroundColor DarkGray
Write-Host "  MTP (speculative):      enabled (draft-mtp, n-max=2)" -ForegroundColor DarkGray
Write-Host "  Reasoning format:       none (inline think tags)" -ForegroundColor DarkGray
Write-Host "  SYCL_CACHE_PERSISTENT:  $env:SYCL_CACHE_PERSISTENT" -ForegroundColor DarkGray

$serverArgs = @(
    "-m", $ModelPath,
    "-a", "qwen3.8-27b",
    "--host", $HostAddr, "--port", $Port,
    "-ngl", "99", "-c", "$Context",
    "-ctk", "q8_0", "-ctv", "q8_0", "-fa", "on",
    "-b", "8192", "-ub", "4096",
    "-t", "8", "--parallel", "1",
    "--spec-type", "draft-mtp",
    "--spec-draft-n-max", "2",
    "--spec-draft-p-min", "0.1",
    "--jinja", "--no-warmup", "--reasoning-format", "none",
    "--slot-save-path", $SlotsDir,
    "--metrics"
)

if (Test-Path $MmprojPath) {
    Write-Host "  Vision:                 enabled ($MmprojPath)" -ForegroundColor DarkGray
    $serverArgs += @("-mm", $MmprojPath)
} else {
    Write-Host "  Vision:                 disabled (mmproj not found)" -ForegroundColor Yellow
}

& $ServerExe @serverArgs
