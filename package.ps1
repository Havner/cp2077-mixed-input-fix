# Package the Nexus release zip: build/MixedInputFix-<version>.zip containing
#   red4ext/plugins/MixedInputFix/{MixedInputFix.dll, MixedInputFix.ini}
# so the archive extracts directly into the main game folder. Run build.ps1 first.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dll = Join-Path $root 'build\MixedInputFix.dll'
if (-not (Test-Path $dll)) { throw "build\MixedInputFix.dll not found - run build.ps1 first" }

$match = Select-String -Path (Join-Path $root 'src\main.cpp') -Pattern 'VersionStr = "([^"]+)"'
if (-not $match) { throw "could not read VersionStr from src\main.cpp" }
$version = $match.Matches[0].Groups[1].Value

$staging = Join-Path $root 'build\package'
$plugin = Join-Path $staging 'red4ext\plugins\MixedInputFix'
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $plugin | Out-Null
Copy-Item $dll $plugin
Copy-Item (Join-Path $root 'MixedInputFix.ini') $plugin

$zip = Join-Path $root "build\MixedInputFix-$version.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue

# 7-Zip, not Compress-Archive: Windows PowerShell 5.1 stores entry paths with
# backslashes, which the zip format does not allow (APPNOTE 4.4.17.1 - forward
# slashes only). Windows Explorer tolerates it, but spec-following extractors -
# Linux/Steam Deck unzip, some mod managers - see one file literally named
# "red4ext\plugins\..." and drop it in the game root instead of unpacking it.
Push-Location $staging
try {
    7z a -tzip -mx=9 $zip red4ext | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}
Remove-Item $staging -Recurse -Force

Write-Host "Packaged $zip"
