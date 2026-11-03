# Builds the Windows installer from the already prepared portable folder.
# Run tools\package-windows.ps1 first.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'
$source = Join-Path $dist 'NovaSSH'
$iss = Join-Path $PSScriptRoot 'installer\NovaSSH.iss'
$pubspec = Get-Content (Join-Path $repo 'app\pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'Could not read version from app\pubspec.yaml'
}
$version = $Matches[1]
$output = Join-Path $dist "NovaSSH-$version-windows-x64-installer.exe"

if (-not (Test-Path (Join-Path $source 'NovaSSH.exe'))) {
    throw "Portable build not found. Run tools\package-windows.ps1 first."
}

$candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
)
$iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw 'Inno Setup 6 (ISCC.exe) not found. Install it with: winget install JRSoftware.InnoSetup'
}

if (Test-Path $output) { Remove-Item $output -Force }
& $iscc "/DMyAppVersion=$version" "/DRepoRoot=$repo" "/DSourceDir=$source" "/DOutputDir=$dist" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with code $LASTEXITCODE" }
if (-not (Test-Path $output)) { throw "Installer not found: $output" }

$size = [math]::Round((Get-Item $output).Length / 1MB, 1)
Write-Output ("  {0}  {1} MB" -f $output, $size)
