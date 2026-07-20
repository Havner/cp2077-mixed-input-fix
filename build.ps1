# Build MixedInputFix.dll with MSVC against the RED4ext.SDK submodule
# (run `git submodule update --init` once after cloning).
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdkInclude = Join-Path $root '.\RED4ext.SDK\include'
$out = Join-Path $root 'build'
New-Item -ItemType Directory -Force $out | Out-Null

# Edit to match your Visual Studio installation (any edition with x64 MSVC).
$vcvars = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat'

cmd /c "`"$vcvars`" >nul 2>&1 && cl /nologo /std:c++20 /O2 /W3 /EHsc /MD /DNOMINMAX /DWIN32_LEAN_AND_MEAN /I `"$sdkInclude`" /Fo`"$out\\`" `"$root\src\main.cpp`" /LD /link user32.lib version.lib /OUT:`"$out\MixedInputFix.dll`" /IMPLIB:`"$out\MixedInputFix.lib`""

if ($LASTEXITCODE -ne 0) { throw "build failed" }
Write-Host "Built $out\MixedInputFix.dll"
