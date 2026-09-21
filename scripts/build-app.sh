#!/bin/zsh

set -euo pipefail
umask 022
export COPYFILE_DISABLE=1

project_dir="${0:A:h:h}"
mode=""
output_dir=""
usage() {
    print 'Usage: ./scripts/build-app.sh --local|--release [--output DIRECTORY]'
    print 'Release requires CODEX_MICDUCK_SIGNING_IDENTITY and CODEX_MICDUCK_NOTARY_PROFILE.'
}
while (( $# )); do
    case "$1" in
        --local|--release)
            [[ -z "$mode" ]] || { usage >&2; exit 2; }
            mode="${1#--}"
            shift ;;
        --output)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            output_dir="$2"
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -n "$mode" ]] || { usage >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { print -u2 'Packaging requires macOS.'; exit 1; }

signing_identity="${CODEX_MICDUCK_SIGNING_IDENTITY:-}"
notary_profile="${CODEX_MICDUCK_NOTARY_PROFILE:-}"
if [[ "$mode" == release ]]; then
    [[ "$signing_identity" == 'Developer ID Application: '* && -n "$notary_profile" ]] || {
        print -u2 'Public release requires a Developer ID Application identity and a notarytool Keychain profile.'
        exit 1
    }
    security find-identity -v -p codesigning | grep -F -- "\"$signing_identity\"" >/dev/null || {
        print -u2 'The requested Developer ID Application signing identity is unavailable.'
        exit 1
    }
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
fi

output_dir="${output_dir:-${project_dir}/dist/${mode}}"
output_dir="${output_dir:A}"
app_name='Codex MicDuck'
executable_name='CodexMicDuck'
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$project_dir/Resources/Info.plist")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Version must be numeric major.minor.patch.'; exit 1; }
artifact_name="Codex-MicDuck-${version}-arm64"
[[ "$mode" == release ]] || artifact_name+="-LOCAL-UNSIGNED"
for destination in "$output_dir/$app_name.app" "$output_dir/$artifact_name.dmg" "$output_dir/$artifact_name.dmg.sha256"; do
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        print -u2 'Output already contains this build. Choose an empty --output directory.'
        exit 1
    }
done

cd "$project_dir"
./scripts/test.sh
mkdir -p "$project_dir/.build"
stage="$(mktemp -d "$project_dir/.build/package.XXXXXX")"
mount_path=""
mount_device=""
cleanup() {
    if [[ -n "$mount_device" ]]; then
        if ! hdiutil detach "$mount_device" -quiet; then
            print -u2 "Could not detach packaging disk $mount_device; preserving its staging directory."
            return
        fi
    elif [[ -n "$mount_path" ]]; then
        if ! hdiutil detach "$mount_path" -quiet; then
            print -u2 'Packaging attachment did not complete; preserving its staging directory for inspection.'
            return
        fi
    fi
    [[ -z "$stage" ]] || rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

scratch_path="$project_dir/.build/packaging-release"
build_arguments=(
    --scratch-path "$scratch_path" -c release --arch arm64
    -Xswiftc -gnone
    -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/CodexMicDuck"
    -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/CodexMicDuck"
)
swift build "${build_arguments[@]}" --product "$executable_name"
build_binary="$(swift build "${build_arguments[@]}" --show-bin-path)/$executable_name"
[[ -x "$build_binary" ]] || { print -u2 'Built executable is missing.'; exit 1; }

dmg_contents="$stage/dmg-contents"
app_path="$dmg_contents/$app_name.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp -X "$build_binary" "$app_path/Contents/MacOS/$executable_name"
chmod 755 "$app_path/Contents/MacOS/$executable_name"
xcrun strip -S -x "$app_path/Contents/MacOS/$executable_name"
cp -X "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp -X "$project_dir/Resources/CodexMicDuckMenuBar.svg" "$app_path/Contents/Resources/"
cp -X "$project_dir/Resources/CodexMicDuckAppIcon.png" "$app_path/Contents/Resources/"
cp -X "$project_dir/LICENSE" "$project_dir/NOTICE" "$app_path/Contents/Resources/"

iconset_path="$stage/CodexMicDuck.iconset"
mkdir "$iconset_path"
icon_source="$project_dir/Resources/CodexMicDuckAppIcon.png"
for specification in \
    '16 icon_16x16.png' '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' '1024 icon_512x512@2x.png'
do
    size="${specification%% *}"
    filename="${specification#* }"
    sips -s format png -z "$size" "$size" "$icon_source" --out "$iconset_path/$filename" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/CodexMicDuck.icns"
xattr -cr "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
[[ "$(lipo -archs "$app_path/Contents/MacOS/$executable_name")" == arm64 ]] || {
    print -u2 'Unexpected executable architecture.'; exit 1
}
python3 ./scripts/verify-public-files.py "$app_path"

notarize() {
    local candidate="$1"
    local result_file="$2"
    xcrun notarytool submit "$candidate" --keychain-profile "$notary_profile" \
        --wait --timeout 30m --output-format json > "$result_file"
    python3 - "$result_file" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get('status') != 'Accepted':
    raise SystemExit('Apple notarization did not return Accepted; no release was produced.')
PY
    xcrun stapler staple "$candidate"
    xcrun stapler validate "$candidate"
}

if [[ "$mode" == release ]]; then
    codesign --force --sign "$signing_identity" --identifier "$bundle_id" \
        --options runtime --entitlements "$project_dir/Resources/CodexMicDuck.entitlements" \
        --timestamp "$app_path"
    codesign --verify --strict "$app_path"
    # ZIP is only a transport for app notarization, never a public artifact.
    ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$stage/notarization.zip"
    xcrun notarytool submit "$stage/notarization.zip" --keychain-profile "$notary_profile" \
        --wait --timeout 30m --output-format json > "$stage/app-notarization.json"
    python3 - "$stage/app-notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get('status') != 'Accepted':
    raise SystemExit('App notarization did not return Accepted; no release was produced.')
PY
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    spctl --assess --type execute "$app_path"
else
    codesign --force --sign - --identifier "$bundle_id" --options runtime \
        --entitlements "$project_dir/Resources/CodexMicDuck.entitlements" --timestamp=none "$app_path"
    print 'LOCAL DEVELOPMENT BUILD: ad-hoc signed; not approved for public distribution.'
fi
codesign --verify --strict "$app_path"
python3 ./scripts/verify-public-files.py "$app_path"
# Signing and disk-image tools can add local provenance after initial staging.
# Preserve signing/notarization data; remove only these development attributes.
sanitize_metadata() {
    python3 - "$@" <<'PY'
from pathlib import Path
import subprocess, sys
arguments = sys.argv[1:]
private_attributes = {
    'com.apple.provenance', 'com.apple.diskimages.recentcksum',
}
for argument in arguments:
    root = Path(argument)
    paths = [root] + (list(root.rglob('*')) if root.is_dir() else [])
    for path in paths:
        if path.is_symlink():
            continue
        names = set(subprocess.check_output(['xattr', str(path)], text=True).splitlines())
        found = names & private_attributes
        for name in found:
            # macOS may retain or immediately regenerate its integrity bookkeeping.
            # Presence alone is not a leak; verify-public-files scans attribute values.
            subprocess.run(['xattr', '-d', name, str(path)], capture_output=True)
PY
}
sanitize_metadata "$app_path"
ln -s /Applications "$dmg_contents/Applications"
cp -X "$project_dir/LICENSE" "$project_dir/NOTICE" "$dmg_contents/"
if [[ "$mode" == local ]]; then
    print 'Local development build. This app is not Developer ID signed or notarized. Do not distribute.' > "$dmg_contents/LOCAL-UNSIGNED.txt"
fi

dmg_path="$stage/$artifact_name.dmg"
hdiutil create -quiet -srcfolder "$dmg_contents" -volname "$app_name" \
    -fs HFS+ -format UDZO -nospotlight -noanyowners -srcowners any "$dmg_path"
xattr -c "$dmg_path"
if [[ "$mode" == release ]]; then
    codesign --force --sign "$signing_identity" --timestamp "$dmg_path"
    notarize "$dmg_path" "$stage/dmg-notarization.json"
    codesign --verify --strict "$dmg_path"
    spctl --assess --type open --context context:primary-signature "$dmg_path"
fi
hdiutil verify -quiet "$dmg_path"
python3 ./scripts/verify-public-files.py "$dmg_path"
mount_path="$stage/verify-mount"
mkdir "$mount_path"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_path" -plist "$dmg_path" > "$stage/mount.plist"
mount_device="$(python3 - "$stage/mount.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    entities = plistlib.load(source)['system-entities']
print(next(entity['dev-entry'] for entity in entities if entity.get('dev-entry')))
PY
)"
codesign --verify --strict "$mount_path/$app_name.app"
python3 ./scripts/verify-public-files.py "$mount_path" --dmg-root
[[ "$(readlink "$mount_path/Applications")" == /Applications ]] || {
    print -u2 'DMG Applications link is invalid.'; exit 1
}
if [[ "$mode" == release ]]; then
    xcrun stapler validate "$mount_path/$app_name.app"
    spctl --assess --type execute "$mount_path/$app_name.app"
fi
hdiutil detach "$mount_device" -quiet
mount_path=""
mount_device=""

# Remove tool-added metadata, then revalidate before exposing any output artifact.
(cd "$stage" && shasum -a 256 "$artifact_name.dmg" > "$artifact_name.dmg.sha256")
sanitize_metadata "$app_path" "$dmg_path" "$stage/$artifact_name.dmg.sha256"
codesign --verify --strict "$app_path"
if [[ "$mode" == release ]]; then
    codesign --verify --strict "$dmg_path"
    xcrun stapler validate "$app_path"
    xcrun stapler validate "$dmg_path"
fi
# Move verified artifacts only after every applicable check has passed.
mkdir -p "$output_dir"
mv "$app_path" "$output_dir/$app_name.app"
mv "$dmg_path" "$output_dir/$artifact_name.dmg"
mv "$stage/$artifact_name.dmg.sha256" "$output_dir/$artifact_name.dmg.sha256"
print "Built and verified ($mode): $output_dir/$artifact_name.dmg"
