# Builds a release and refreshes the portable folder dist\NovaSSH and the
# versioned portable ZIP. No profile is ever copied into the release: it holds
# servers, snippets and the encrypted vault.
#
# Output: dist\NovaSSH-<version>-windows-x64-portable.zip
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$release = Join-Path $repo 'app\build\windows\x64\runner\Release'
$out = Join-Path $repo 'dist\NovaSSH'
$pubspec = Get-Content (Join-Path $repo 'app\pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'Could not read version from app\pubspec.yaml'
}
$version = $Matches[1]
$zip = Join-Path $repo "dist\NovaSSH-$version-windows-x64-portable.zip"

# Build the Rust core explicitly: Flutter's CMake target can be cached and would
# otherwise ship a stale nova_core.dll.
$env:CARGO_TARGET_DIR = Join-Path $repo 'rust/core/target'
Push-Location $repo
try { cargo build --release -p nova_core } finally { Pop-Location }

Push-Location (Join-Path $repo 'app')
try { flutter build windows --release } finally { Pop-Location }

# Make sure the fresh dll is the one that gets packaged.
Copy-Item (Join-Path $repo 'rust/core/target/release/nova_core.dll') (Join-Path $release 'nova_core.dll') -Force

# Close instances running from the target folder, otherwise Windows keeps the
# exe locked and the folder cannot be refreshed.
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
    # /XD profile: the portable profile holds the servers and the vault. A
    # mirror would delete it on every build.
    robocopy $release $out /MIR /XD profile /XF *.pdb /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -lt 8) { $mirrored = $true; break }
    Write-Host "robocopy attempt $attempt failed (code $LASTEXITCODE), retrying..."
    Start-Sleep -Milliseconds 400
}
if (-not $mirrored) { throw "Could not refresh $out" }

# The runner is built as NovaSSH.exe directly (BINARY_NAME), so no rename.
if (Test-Path (Join-Path $out 'nova.exe')) { Remove-Item (Join-Path $out 'nova.exe') -Force }

# Release notes belong to the archive, not to the live profile.
$readme = (Get-Content (Join-Path $PSScriptRoot 'README-windows.txt') -Raw).Replace('{VERSION}', $version)
[System.IO.File]::WriteAllText((Join-Path $out 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $out 'VERSION.txt'), "NovaSSH $version`r`n", (New-Object System.Text.ASCIIEncoding))

if (Test-Path $zip) { Remove-Item $zip -Force }
# The archive must not ship the profile (it contains the encrypted vault).
$items = Get-ChildItem -Path $out -Exclude 'profile' | Select-Object -ExpandProperty FullName
Compress-Archive -Path $items -DestinationPath $zip -CompressionLevel Optimal

Write-Host "Done:" -ForegroundColor Green
Write-Host "  folder: $out"
Write-Host "  zip:    $zip"
