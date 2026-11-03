# Runs the UI against a throw-away demo profile with a built-in SFTP server,
# so the dual-pane browser can be checked without a real host.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$demo = Join-Path $env:TEMP 'nova-demo'

if (-not (Test-Path (Join-Path $repo 'app\build\windows\x64\runner\Debug\nova.exe'))) {
    throw 'Сначала соберите приложение: cd app; flutter build windows --debug'
}

$env:NOVA_DATA_DIR = $demo
cargo run -q --example seed_demo -p nova_core --manifest-path (Join-Path $repo 'Cargo.toml') | Out-Null

Start-Process -FilePath (Join-Path $repo 'target\debug\examples\serve_demo.exe') -WindowStyle Hidden
Start-Sleep -Seconds 1

$env:NOVA_AUTOCONNECT = 's_demo_local'
& (Join-Path $repo 'app\build\windows\x64\runner\Debug\nova.exe')

Get-Process serve_demo -ErrorAction SilentlyContinue | Stop-Process -Force
