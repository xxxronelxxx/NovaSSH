# Common developer loops for NovaSSH.
param(
    [ValidateSet('test', 'codegen', 'check', 'apk', 'windows', 'e2e')]
    [string]$Task = 'test'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

switch ($Task) {
    'test' {
        cargo test -p nova_core
        Push-Location "$repo\app"; flutter analyze; flutter test; Pop-Location
    }
    'check' {
        cargo check -p nova_core --all-targets
        Push-Location "$repo\app"; flutter analyze; Pop-Location
    }
    'e2e' {
        cargo run -q --example sftp_e2e -p nova_core
        cargo run -q --example smoke -p nova_core
    }
    'codegen' {
        flutter_rust_bridge_codegen generate
    }
    'apk' {
        Push-Location "$repo\app"; flutter build apk --debug; Pop-Location
    }
    'windows' {
        Push-Location "$repo\app"; flutter run -d windows; Pop-Location
    }
}
