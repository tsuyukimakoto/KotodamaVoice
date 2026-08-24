#!/bin/zsh

set -euo pipefail

if (( $# != 2 )); then
    print -u2 "usage: $0 /path/to/KotodamaVoice.app /path/to/KotodamaVoice.dmg"
    exit 64
fi

app_path=$1
dmg_path=$2
script_directory=${0:A:h}
info_plist_path="$app_path/Contents/Info.plist"

if [[ ! -d $app_path ]]; then
    print -u2 "app bundle not found: $app_path"
    exit 66
fi

if [[ ${dmg_path:e:l} != dmg ]]; then
    print -u2 "destination must use the .dmg extension: $dmg_path"
    exit 64
fi

if [[ -e $dmg_path ]]; then
    print -u2 "destination already exists: $dmg_path"
    exit 73
fi

"$script_directory/verify-direct-distribution.sh" "$app_path"

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist_path")
if [[ -z $bundle_identifier ]]; then
    print -u2 "could not determine the app bundle identifier"
    exit 1
fi

working_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/KotodamaVoice-dmg.XXXXXX")
payload_directory="$working_directory/payload"
/bin/mkdir "$payload_directory"
cleanup() {
    /bin/rm -rf "$working_directory"
}
trap cleanup EXIT

certificate_prefix="$working_directory/signing-certificate"
/usr/bin/codesign -d --extract-certificates="$certificate_prefix" "$app_path"
signing_identity=$(
    /usr/bin/openssl x509 \
        -inform DER \
        -fingerprint \
        -sha1 \
        -noout \
        -in "${certificate_prefix}0" \
    | /usr/bin/sed 's/^[^=]*=//; s/://g'
)
if [[ -z $signing_identity ]]; then
    print -u2 "could not determine the app signing certificate fingerprint"
    exit 1
fi

temporary_dmg_path="$working_directory/KotodamaVoice.dmg"

# A disk image preserves the signed bundle without relying on a ZIP extractor.
# Exclude filesystem metadata so it cannot reappear as AppleDouble files.
/usr/bin/ditto \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$app_path" \
    "$payload_directory/KotodamaVoice.app"

"$script_directory/verify-direct-distribution.sh" "$payload_directory/KotodamaVoice.app"
/bin/ln -s /Applications "$payload_directory/Applications"

/usr/bin/hdiutil create \
    -volname KotodamaVoice \
    -srcfolder "$payload_directory" \
    -format UDZO \
    -ov \
    "$temporary_dmg_path"

/usr/bin/codesign \
    --sign "$signing_identity" \
    --timestamp \
    --identifier "$bundle_identifier.distribution-dmg" \
    "$temporary_dmg_path"
/usr/bin/codesign --verify --verbose=2 "$temporary_dmg_path"
/bin/mv "$temporary_dmg_path" "$dmg_path"

print "created: $dmg_path"
