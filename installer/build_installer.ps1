# Genera installer\Output\ComicShelf-Setup-<versión>.exe
#   1. Compila la app de Windows (release).
#   2. Copia las librerías de Visual C++ x64 a installer\redist.
#   3. Compila el instalador con Inno Setup.
# Uso: powershell -ExecutionPolicy Bypass -File installer\build_installer.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flutter = Join-Path $env:USERPROFILE 'dev\flutter\bin\flutter.bat'
& $flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Falló la compilación de Flutter.' }

# Versión de pubspec.yaml ("version: 1.0.0+1" -> "1.0.0").
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value

# Este PowerShell es de 64 bits: System32 tiene las DLL x64. (El compilador
# de Inno Setup es de 32 bits y vería las de SysWOW64, por eso se copian.)
$redist = Join-Path $PSScriptRoot 'redist'
New-Item -ItemType Directory -Force $redist | Out-Null
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    $src = Join-Path $env:WINDIR "System32\$dll"
    $bytes = [IO.File]::ReadAllBytes($src)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
    if ($machine -ne 0x8664) { throw "$dll no es x64 (machine=0x{0:X})." -f $machine }
    Copy-Item $src $redist -Force
}

$iscc = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
if (-not (Test-Path $iscc)) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
& $iscc "/DAppVersion=$version" (Join-Path $PSScriptRoot 'comicshelf.iss')
if ($LASTEXITCODE -ne 0) { throw 'Falló Inno Setup.' }

Write-Host "Instalador: $(Join-Path $PSScriptRoot "Output\ComicShelf-Setup-$version.exe")"
