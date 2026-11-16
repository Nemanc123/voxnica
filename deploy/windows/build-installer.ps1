<#
.SYNOPSIS
    Собирает release-сборку Voxnica для Windows и установщик Inno Setup.

.DESCRIPTION
    Шаги:
      1. читает версию из app/pubspec.yaml;
      2. собирает Flutter release с адресом API;
      3. компилирует deploy/windows/voxnica.iss в dist\VoxnicaSetup-<версия>.exe.

    Debug-сборка в установщик не попадает: только Release.

.PARAMETER ApiUrl
    Адрес API, вшиваемый в клиент. По умолчанию прод.

.PARAMETER SkipBuild
    Не пересобирать Flutter, взять уже готовый build\windows\x64\runner\Release.

.PARAMETER IsccPath
    Путь к ISCC.exe. По умолчанию ищется в стандартных каталогах и в PATH.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
#>

[CmdletBinding()]
param(
    [string]$ApiUrl = 'https://chat.voxnica.su/api/v1',
    [switch]$SkipBuild,
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'

# Корень репозитория: скрипт лежит в deploy\windows.
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$appDir = Join-Path $root 'app'
$pubspec = Join-Path $appDir 'pubspec.yaml'
$releaseDir = Join-Path $appDir 'build\windows\x64\runner\Release'
$issFile = Join-Path $PSScriptRoot 'voxnica.iss'
$distDir = Join-Path $root 'dist'

function Get-AppVersion {
    param([string]$Path)

    $line = Select-String -Path $Path -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $line) { throw "в $Path нет строки version:" }

    # "1.0.0+1" -> "1.0.0": номер сборки (+1) в установщик не идёт.
    $version = $line.Matches[0].Groups[1].Value.Split('+')[0]
    return $version
}

function Find-Iscc {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "ISCC.exe не найден: $Explicit" }
        return $Explicit
    }

    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw 'ISCC.exe не найден. Установите Inno Setup 6: winget install -e --id JRSoftware.InnoSetup'
}

$version = Get-AppVersion -Path $pubspec
Write-Host "Voxnica $version"

if (-not $SkipBuild) {
    Write-Host "сборка Flutter release, API_URL=$ApiUrl"
    Push-Location $appDir
    try {
        flutter build windows --release "--dart-define=API_URL=$ApiUrl"
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows завершился с кодом $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path (Join-Path $releaseDir 'voxnica.exe'))) {
    throw "нет $releaseDir\voxnica.exe — сначала соберите release"
}

$iscc = Find-Iscc -Explicit $IsccPath
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Write-Host "Inno Setup: $iscc"
& $iscc "/DAppVersion=$version" $issFile
if ($LASTEXITCODE -ne 0) { throw "ISCC завершился с кодом $LASTEXITCODE" }

$setup = Join-Path $distDir "VoxnicaSetup-$version.exe"
if (-not (Test-Path $setup)) { throw "установщик не появился: $setup" }

$sizeMb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host "готово: $setup ($sizeMb МБ)"
