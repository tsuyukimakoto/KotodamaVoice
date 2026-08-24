#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 /path/to/KotodamaVoice.app"
    exit 64
fi

app_path=$1
if [[ ! -d $app_path ]]; then
    print -u2 "app bundle not found: $app_path"
    exit 66
fi

forbidden_entitlements=(
    com.apple.security.app-sandbox
    com.apple.security.cs.allow-jit
    com.apple.security.cs.allow-unsigned-executable-memory
    com.apple.security.cs.disable-library-validation
    com.apple.security.get-task-allow
)

verify_code() {
    local code_path=$1
    local details entitlements entitlement

    /usr/bin/codesign --verify --strict --verbose=2 "$code_path"
    details=$(/usr/bin/codesign -dvvv "$code_path" 2>&1)

    if ! /usr/bin/grep -Fq "Authority=Developer ID Application:" <<< "$details"; then
        print -u2 "not signed with Developer ID Application: $code_path"
        exit 1
    fi
    if ! /usr/bin/grep -Eq 'flags=.*\(runtime\)' <<< "$details"; then
        print -u2 "hardened runtime is not enabled: $code_path"
        exit 1
    fi
    if ! /usr/bin/grep -Fq "Timestamp=" <<< "$details"; then
        print -u2 "secure timestamp is missing: $code_path"
        exit 1
    fi

    entitlements=$(/usr/bin/codesign -d --entitlements - "$code_path" 2>&1 || true)
    for entitlement in $forbidden_entitlements; do
        if /usr/bin/grep -Fq "$entitlement" <<< "$entitlements"; then
            print -u2 "forbidden entitlement $entitlement: $code_path"
            exit 1
        fi
    done

    print "verified: $code_path"
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
verify_code "$app_path"

while IFS= read -r code_path; do
    verify_code "$code_path"
done < <(/usr/bin/find "$app_path" -mindepth 1 -type d \( -name '*.xpc' -o -name '*.framework' \) -print | /usr/bin/sort)

while IFS= read -r code_path; do
    verify_code "$code_path"
done < <(/usr/bin/find "$app_path" -type f -name '*.dylib' -print | /usr/bin/sort)
