#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 /path/to/KotodamaVoice.dmg"
    exit 64
fi

dmg_path=$1
script_directory=${0:A:h}
if [[ ! -f $dmg_path ]]; then
    print -u2 "disk image not found: $dmg_path"
    exit 66
fi

/usr/bin/codesign --verify --verbose=2 "$dmg_path"

working_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/KotodamaVoice-dmg-verify.XXXXXX")
mount_point="$working_directory/mount"
/bin/mkdir "$mount_point"
mounted=false
cleanup() {
    if [[ $mounted == true ]]; then
        /usr/bin/hdiutil detach "$mount_point" >/dev/null
    fi
    /bin/rm -rf "$working_directory"
}
trap cleanup EXIT

/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mount_point" \
    "$dmg_path" >/dev/null
mounted=true

app_path="$mount_point/KotodamaVoice.app"
"$script_directory/verify-license-compliance.sh" \
    --repository "$script_directory/.." \
    --app "$app_path" \
    --dmg-root "$mount_point"
"$script_directory/verify-direct-distribution.sh" "$app_path"

print "verified DMG: $dmg_path"
