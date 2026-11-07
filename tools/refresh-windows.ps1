# Refreshes the portable folder dist\NovaSSH from the current sources.
#
# Unlike package-windows.ps1 this does NOT create a ZIP or an installer: it is
# meant to be run after every code change so dist\NovaSSH always holds the
# latest build. The portable `profile` folder (servers, vault, settings) is
# never copied, deleted or touched.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$release = Join-Path $repo 'app\build\windows\x64\runner\Release'
$out = Join-Path $repo 'dist\NovaSSH'
$pubspec = Get-Content (Join-Path $repo 'app\pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'Could not read version from app\pubspec.yaml'
}
$version = $Matches[1]

# Flutter's CMake target can be cached and would ship a stale nova_core.dll.
$env:CARGO_TARGET_DIR = Join-Path $repo 'rust/core/target'
Push-Location $repo
try { cargo build --release -p nova_core } finally { Pop-Location }

Push-Location (Join-Path $repo 'app')
try { flutter build windows --release } finally { Pop-Location }

Copy-Item (Join-Path $repo 'rust/core/target/release/nova_core.dll') (Join-Path $release 'nova_core.dll') -Force

# Close instances running from the target folder: Windows keeps the exe and
# the dll locked otherwise.
Get-Process | ForEach-Object {
    $path = $null
    try { $path = $_.Path } catch { return }
    if ($path -and $path.StartsWith($out, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Closing $($_.ProcessName) (pid $($_.Id)) so the folder can be refreshed"
        try { $_.Kill(); $_.WaitForExit(4000) | Out-Null } catch { }
    }
}
Start-Sleep -Milliseconds 500

New-Item -ItemType Directory -Force -Path $out | Out-Null

$mirrored = $false
for ($attempt = 1; $attempt -le 5; $attempt++) {
    # /XD profile keeps the portable profile (servers and the vault) intact.
    robocopy $release $out /MIR /XD profile /XF *.pdb /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -lt 8) { $mirrored = $true; break }
    Write-Host "robocopy attempt $attempt failed (code $LASTEXITCODE), retrying..."
    Start-Sleep -Milliseconds 400
}
if (-not $mirrored) { throw "Could not refresh $out" }

if (Test-Path (Join-Path $out 'nova.exe')) { Remove-Item (Join-Path $out 'nova.exe') -Force }

$readme = (Get-Content (Join-Path $PSScriptRoot 'README-windows.txt') -Raw).Replace('{VERSION}', $version)
[System.IO.File]::WriteAllText((Join-Path $out 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $out 'VERSION.txt'), "NovaSSH $version`r`n", (New-Object System.Text.ASCIIEncoding))

$exe = Get-Item (Join-Path $out 'NovaSSH.exe')
Write-Host "Refreshed $out ($version, $([math]::Round($exe.Length / 1MB, 1)) MB exe)" -ForegroundColor Green
