#!/bin/bash
# Linux counterpart of package.ps1 for the optional companion redscript mods
# only - the plugin zip needs the Windows-built DLL, so it stays in package.ps1.
#   <Mod>-<version>.zip               r6/scripts/<Mod>/<Mod>.reds, one per mods/*.reds,
#                                     plus r6/input/<Mod>.xml if input/<Mod>.xml exists
#                                     (custom bindings, merged by input_loader),
#                                     plus r6/input-<Variant>/<Mod>.xml for each
#                                     input/<Variant>/<Mod>.xml (alternative bindings
#                                     the user copies into r6/input/ by hand -
#                                     input_loader reads r6/input/ recursively, so
#                                     they can't ship inside it)
# All extract directly into the main game folder. The version is read from the
# "// <Mod> X.Y" banner comment at the top of the .reds.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$root/build"

for modSource in "$root"/mods/*.reds; do
    modName=$(basename "$modSource" .reds)
    modVersion=$(grep -m1 -oP "$modName \K[0-9.]+" "$modSource") ||
        { echo "could not read version from $modSource" >&2; exit 1; }
    modStaging="$root/build/package-$modName"
    zip="$root/build/$modName-$modVersion.zip"
    rm -rf "$modStaging" "$zip"
    mkdir -p "$modStaging/r6/scripts/$modName"
    cp "$modSource" "$modStaging/r6/scripts/$modName/"
    if [[ -f "$root/input/$modName.xml" ]]; then
        mkdir -p "$modStaging/r6/input"
        cp "$root/input/$modName.xml" "$modStaging/r6/input/"
    fi
    for variantInput in "$root"/input/*/"$modName.xml"; do
        [[ -f "$variantInput" ]] || continue
        variant=$(basename "$(dirname "$variantInput")")
        mkdir -p "$modStaging/r6/input-$variant"
        cp "$variantInput" "$modStaging/r6/input-$variant/"
    done
    (cd "$modStaging" && zip -q -r -9 "$zip" r6)
    rm -rf "$modStaging"
    echo "Packaged $zip"
done
