#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$(mktemp -d .build/distribution.XXXXXXXX)"
app="$stage/Narrator Studio.app"
res="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$res/Models" "$res/Notices" dist
swiftc -O -target arm64-apple-macos26.0 -parse-as-library Sources/*.swift -o "$app/Contents/MacOS/NarratorStudio"
cp Assets/Info.plist "$app/Contents/Info.plist"
cp Assets/Icon.icns Sources/{studio.py,speech_cleanup.py,worker.sh} "$res/"
cp Assets/{Apache-2.0.txt,CC-BY-4.0.txt,Whisper-LICENSE.txt,Notices.txt,WeSpeaker.md} "$res/Notices/"
if [[ -n "${NARRATOR_ASSET_SOURCE:-}" ]]; then
    # Rebuild the interface and worker against the verified offline release assets.
    python3 Scripts/check_models.py "$NARRATOR_ASSET_SOURCE/Models"
    /usr/bin/rsync -a "$NARRATOR_ASSET_SOURCE/Models/" "$res/Models/"
    cp -c "$NARRATOR_ASSET_SOURCE/runtime.tar.gz" "$res/runtime.tar.gz"
    [[ "$(shasum -a 256 "$res/runtime.tar.gz" | cut -c1-16)" == "$(cat "$NARRATOR_ASSET_SOURCE/runtime-version")" ]]
    cp "$NARRATOR_ASSET_SOURCE/runtime-version" "$res/runtime-version"
else
    if [[ ! -f "$res/runtime.tar.gz" || .build/requirements.lock -nt "$res/runtime.tar.gz" ]]; then
        COPYFILE_DISABLE=1 /usr/bin/tar --exclude='__pycache__' --exclude='*.pyc' -czf "$res/runtime.tar.gz" -C .build python
    fi
    shasum -a 256 "$res/runtime.tar.gz" | cut -c1-16 > "$res/runtime-version"
    /usr/bin/rsync -a --exclude='*.part' .build/Models/ "$res/Models/"
fi
python3 Scripts/check_models.py "$res/Models"
# Build a clean bundle without user profiles.
codesign --force --sign - --identifier local.narratorstudio.mac "$app"
codesign --verify --strict "$app"
[[ -e "$stage/Applications" ]] || ln -s /Applications "$stage/Applications"
scratch="$(mktemp -d .build/package.XXXXXXXX)"
trap 'rm -rf "$scratch"' EXIT
hdiutil create -quiet -volname "Narrator Studio" -fs HFS+ -format ULFO -srcfolder "$stage" "$scratch/Narrator Studio.dmg"
hdiutil verify "$scratch/Narrator Studio.dmg"
mv -f "$scratch/Narrator Studio.dmg" "dist/Narrator Studio.dmg"
