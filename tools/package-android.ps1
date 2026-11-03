# Builds the release APK(s) for phones and copies them into dist\android.
#
# Default: arm64-only split APK (small download).
# -Universal: one APK with arm64-v8a, armeabi-v7a and x86_64 native libraries.
#
# The Rust core is cross-compiled by Gradle (cargo-ndk). That task is forced to
# run on every build: a stale libnova_core.so makes the app hang on the splash
# screen with a bridge init error.
param([switch]$Universal)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$apkDir = Join-Path $repo 'app\build\app\outputs\flutter-apk'
$out = Join-Path $repo 'dist\android'
$pubspec = Get-Content (Join-Path $repo 'app\pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'Could not read version from app\pubspec.yaml'
}
$version = $Matches[1]

Push-Location (Join-Path $repo 'app')
try {
    if ($Universal) {
        flutter build apk --release "-PnovaAbis=arm64-v8a,armeabi-v7a,x86_64"
    } else {
        flutter build apk --release --split-per-abi --target-platform=android-arm64 -PnovaAbis=arm64-v8a
    }
} finally { Pop-Location }

New-Item -ItemType Directory -Force -Path $out | Out-Null
if ($Universal) {
    $src = Join-Path $apkDir 'app-release.apk'
    $dest = Join-Path $out "NovaSSH-$version-universal.apk"
} else {
    $src = Join-Path $apkDir 'app-arm64-v8a-release.apk'
    $dest = Join-Path $out "NovaSSH-$version-android-arm64.apk"
}
if (-not (Test-Path $src)) {
    throw "APK not found: $src"
}
Copy-Item $src $dest -Force

$size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
Write-Output ("  {0}  {1} MB" -f $dest, $size)
Write-Output 'install: adb install -r "' + $dest + '"'
