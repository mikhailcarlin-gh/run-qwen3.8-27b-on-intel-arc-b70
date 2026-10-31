# Build the Qwen3.8-27B image: llama.cpp (SYCL + FP16) is compiled inside.
# The first build takes ~30-60 min, later builds reuse the cached layers.
#
# Extra arguments go to `docker build`, e.g.:
#   .\build.ps1 --build-arg LLAMA_REF=b12000
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Image = if ($env:IMAGE) { $env:IMAGE } else { 'qwen3.8-27b-arc:local' }

Write-Host "Building $Image" -ForegroundColor Cyan
# docker writes its progress to stderr: do not let Windows PowerShell turn
# that into a terminating error - rely on the exit code instead.
$ErrorActionPreference = 'Continue'
& docker build -t $Image @args .
exit $LASTEXITCODE
