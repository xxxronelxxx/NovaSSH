# Builds the release APK for phones (arm64 only, which is what keeps both the
# build time and the download small) and copies it into dist\android.
#
# The Rust core is cross-compiled by Gradle (cargo-ndk). That task is forced to
# run on every build: a stale libnova_core.so makes the app hang on the splash
# screen with a bridge init error.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$apkDir = Join-Path $repo 'app\build\app\outputs\flutter-apk'
$out = Join-Path $repo 'dist\android'

Push-Location (Join-Path $repo 'app')
try {
  flutter build apk --release --split-per-abi --target-platform=android-arm64
} finally { Pop-Location }

$src = Join-Path $apkDir 'app-arm64-v8a-release.apk'
if (-not (Test-Path $src)) {
  throw "APK not found: $src"
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
$dest = Join-Path $out 'NovaSSH-android-arm64.apk'
Copy-Item $src $dest -Force

$size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
Write-Output ("  {0}  {1} MB" -f $dest, $size)
Write-Output 'install: adb install -r "' + $dest + '"'
