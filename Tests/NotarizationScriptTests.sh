#!/bin/zsh

set -euo pipefail

repository_root=${0:A:h:h}
script_path="$repository_root/Scripts/sign-and-notarize-dmg.sh"

fail() {
    print -u2 "notarization script verification failed: $1"
    exit 1
}

if [[ ! -f $script_path ]]; then
    fail "script is missing: $script_path"
fi

script=$(/bin/cat "$script_path")

if [[ $script == *'/usr/bin/zip '* ]]; then
    fail "must not package the app with /usr/bin/zip"
fi

if [[ $script == *'--force --deep'* ]]; then
    fail "must not re-sign the exported app with --force --deep"
fi

if [[ $script != *'notary submit "$dmg_output"'* ]]; then
    fail "must submit the signed DMG to notarytool"
fi

if [[ $script != *'status'* || $script != *'Accepted'* ]]; then
    fail "must require an Accepted notarization status"
fi

if [[ $script != *'notary log'* ]]; then
    fail "must retrieve the notarization log"
fi

if [[ $script != *'stapler staple "$dmg_output"'* ]]; then
    fail "must staple the notarization ticket to the DMG"
fi

if [[ $script != *'stapler validate "$dmg_output"'* ]]; then
    fail "must validate the stapled DMG"
fi

create_line=$(
    /usr/bin/grep -n 'create-direct-distribution-dmg.sh.*"$app_path".*"$dmg_output"' "$script_path" \
    | /usr/bin/head -1 \
    | /usr/bin/cut -d: -f1
)
submit_line=$(
    /usr/bin/grep -n 'notary submit "$dmg_output"' "$script_path" \
    | /usr/bin/head -1 \
    | /usr/bin/cut -d: -f1
)
staple_line=$(
    /usr/bin/grep -n 'stapler staple "$dmg_output"' "$script_path" \
    | /usr/bin/head -1 \
    | /usr/bin/cut -d: -f1
)

if [[ -z $create_line || -z $submit_line || -z $staple_line ]]; then
    fail "could not determine DMG notarization operation order"
fi

if (( create_line >= submit_line || submit_line >= staple_line )); then
    fail "required order is create DMG, submit DMG, then staple DMG"
fi

/bin/zsh -n "$script_path"
print "notarization script verified"
