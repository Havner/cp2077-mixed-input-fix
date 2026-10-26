# Package the Nexus release zips into build/:
#   MixedInputFix-<version>.zip       red4ext/plugins/MixedInputFix/{dll,ini,scripts/*.reds}
#   <Mod>-<version>.zip               r6/scripts/<Mod>/<Mod>.reds, one per mods/*.reds
# All extract directly into the main game folder. Each optional redscript mod
# ships as a separate file on Nexus, so it gets its own archive and its own
# version, read from the "// <Mod> X.Y" banner comment at the top of the .reds.
# Run build.ps1 first.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dll = Join-Path $root 'build\MixedInputFix.dll'
if (-not (Test-Path $dll)) { throw "build\MixedInputFix.dll not found - run build.ps1 first" }

function Get-SourceVersion($path, $pattern) {
    $match = Select-String -Path $path -Pattern $pattern
    if (-not $match) { throw "could not read version from $path" }
    return $match.Matches[0].Groups[1].Value
}

# 7-Zip, not Compress-Archive: Windows PowerShell 5.1 stores entry paths with
# backslashes, which the zip format does not allow (APPNOTE 4.4.17.1 - forward
# slashes only). Windows Explorer tolerates it, but spec-following extractors -
# Linux/Steam Deck unzip, some mod managers - see one file literally named
# "red4ext\plugins\..." and drop it in the game root instead of unpacking it.
function New-ReleaseZip($staging, $topLevel, $zip) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Push-Location $staging
    try {
        7z a -tzip -mx=9 $zip $topLevel | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
    Remove-Item $staging -Recurse -Force
    Write-Host "Packaged $zip"
}

# --- the plugin -----------------------------------------------------------
$version = Get-SourceVersion (Join-Path $root 'src\main.cpp') 'VersionStr = "([^"]+)"'
$staging = Join-Path $root 'build\package'
$plugin = Join-Path $staging 'red4ext\plugins\MixedInputFix'
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $plugin | Out-Null
Copy-Item $dll $plugin
Copy-Item (Join-Path $root 'MixedInputFix.ini') $plugin
Copy-Item (Join-Path $root 'scripts') $plugin -Recurse
New-ReleaseZip $staging 'red4ext' (Join-Path $root "build\MixedInputFix-$version.zip")

# --- the optional companion redscript mods --------------------------------
foreach ($modSource in Get-ChildItem (Join-Path $root 'mods') -Filter '*.reds') {
    $modName = $modSource.BaseName
    $modVersion = Get-SourceVersion $modSource.FullName "$modName ([0-9.]+)"
    $modStaging = Join-Path $root "build\package-$modName"
    $modDir = Join-Path $modStaging "r6\scripts\$modName"
    Remove-Item $modStaging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $modDir | Out-Null
    Copy-Item $modSource.FullName $modDir
    New-ReleaseZip $modStaging 'r6' (Join-Path $root "build\$modName-$modVersion.zip")
}
