# Self-elevates and installs the missing Visual Studio components that Flutter
# needs to build the Windows desktop target (CMake + C++ toolset + Windows SDK).
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools\install-prereqs.ps1

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host 'Требуются права администратора — запрашиваю UAC...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vs_installer.exe'

if (-not (Test-Path $vswhere)) {
    throw 'vswhere.exe не найден: Visual Studio не установлена?'
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    $vsPath = & $vswhere -latest -products * -property installationPath
}
if (-not $vsPath) {
    throw 'Не найдена установка Visual Studio 2022.'
}
Write-Host "Visual Studio: $vsPath"

$components = @(
    'Microsoft.VisualStudio.Component.VC.CMake.Project',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)

# NOTE: Start-Process joins the argument array without re-quoting, so the
# install path must carry its own quotes (spaces in "Program Files").
$arguments = 'modify --installPath "' + $vsPath + '" --quiet --norestart --nocache'
foreach ($c in $components) { $arguments += ' --add ' + $c }

Write-Host 'Устанавливаю компоненты C++ / CMake / Windows SDK (это может занять несколько минут)...'
$proc = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
Write-Host "Код выхода установщика: $($proc.ExitCode)"

$cmake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (Test-Path $cmake) {
    Write-Host "OK: CMake найден — $cmake" -ForegroundColor Green
    & $cmake --version | Select-Object -First 1
} else {
    Write-Host 'CMake всё ещё отсутствует. Откройте Visual Studio Installer и добавьте' -ForegroundColor Red
    Write-Host 'компонент "C++ CMake tools for Windows" вручную.' -ForegroundColor Red
}

Write-Host ''
Write-Host 'Дальше:' -ForegroundColor Cyan
Write-Host '  flutter doctor'
Write-Host '  cd app; flutter run -d windows'
