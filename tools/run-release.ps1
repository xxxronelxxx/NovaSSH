# Builds the release and runs it from the single portable folder.
# Debug builds are much slower for UI, so performance is judged here.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'package-windows.ps1')

$exe = Join-Path $repo 'dist\NovaSSH\NovaSSH.exe'
Write-Host "Starting: $exe" -ForegroundColor Cyan
& $exe
