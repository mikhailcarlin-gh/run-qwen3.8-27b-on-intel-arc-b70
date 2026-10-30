# Download the pinned llama.cpp SYCL build and the Qwen3.8-27B GGUFs.
# Run once after cloning:  .\setup.ps1     (add -Force to re-download everything)

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- Pinned versions ---
# The launchers expect exactly this build directory, so bump both files together.
$LlamaBuild = "b11953"
$LlamaAsset = "llama-$LlamaBuild-bin-win-sycl-x64"
$LlamaDir   = Join-Path $PSScriptRoot $LlamaAsset
$LlamaUrl   = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaBuild/$LlamaAsset.zip"

$HfRepo = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main"
# Remote name on Hugging Face -> local file name (the mmproj file is renamed).
$ModelFiles = @(
    @{ Remote = "Qwen3.8-27B-UD-Q4_K_M.gguf"; Local = "Qwen3.8-27B-UD-Q4_K_M.gguf" },  # ~15 GB, text model
    @{ Remote = "mmproj-BF16.gguf"; Local = "mmproj-Qwen3.8-27B-BF16.gguf" }            # ~0.9 GB, vision projector
)

function Get-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    if ((Test-Path $Destination) -and -not $Force) {
        $mb = [math]::Round((Get-Item $Destination).Length / 1MB)
        Write-Host "  exists, skipping: $Destination ($mb MB)" -ForegroundColor DarkGray
        return
    }

    $part = "$Destination.part"
    if ($Force) {
        Remove-Item $Destination, $part -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  downloading: $Url" -ForegroundColor DarkGray
    $curlArgs = @("-L", "--fail", "--retry", "3", "--retry-delay", "5", "-o", $part)
    # Resume an interrupted download instead of starting over.
    if ((Test-Path $part) -and (Get-Item $part).Length -gt 0) {
        $curlArgs += @("-C", "-")
    }
    $curlArgs += $Url

    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) {
        throw "download failed (curl exit $LASTEXITCODE). Partial data kept in $part - rerun .\setup.ps1 to resume."
    }
    Move-Item $part $Destination -Force
}

function Install-Llama {
    $serverExe = Join-Path $LlamaDir "llama-server.exe"
    if ((Test-Path $serverExe) -and -not $Force) {
        Write-Host "  exists, skipping: $LlamaDir" -ForegroundColor DarkGray
        return
    }

    $zip = Join-Path $env:TEMP "$LlamaAsset.zip"
    Get-File -Url $LlamaUrl -Destination $zip

    $tmp = Join-Path $env:TEMP "$LlamaAsset-extract"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    $exe = Get-ChildItem $tmp -Recurse -Filter "llama-server.exe" | Select-Object -First 1
    if (-not $exe) {
        throw "llama-server.exe not found inside $zip"
    }

    if (Test-Path $LlamaDir) {
        Remove-Item $LlamaDir -Recurse -Force
    }
    Move-Item $exe.Directory.FullName $LlamaDir

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Host "  installed: $LlamaDir" -ForegroundColor Green
}

Write-Host "llama.cpp $LlamaBuild ($LlamaAsset)" -ForegroundColor Cyan
Install-Llama

Write-Host "Qwen3.8-27B GGUFs" -ForegroundColor Cyan
foreach ($f in $ModelFiles) {
    Get-File -Url "$HfRepo/$($f.Remote)" -Destination (Join-Path $PSScriptRoot $f.Local)
}

Write-Host ""
Write-Host "Setup complete. Start the server with: .\start.ps1" -ForegroundColor Green
