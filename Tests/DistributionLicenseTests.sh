#!/bin/zsh

set -euo pipefail

repository_root=${0:A:h:h}
fixture_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/KotodamaVoice-license-test.XXXXXX")
mounted_fixture=""
cleanup() {
    if [[ -n $mounted_fixture ]]; then
        /usr/bin/hdiutil detach "$mounted_fixture" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$fixture_root"
}
trap cleanup EXIT

fixture_repository="$fixture_root/repository"
app_resources="$fixture_root/KotodamaVoice.app/Contents/Resources"
dmg_root="$fixture_root/dmg"
/bin/mkdir -p \
    "$fixture_repository/Config" \
    "$fixture_repository/Resources" \
    "$fixture_repository/Licenses" \
    "$app_resources" \
    "$dmg_root/Licenses"

/bin/cp "$repository_root/LICENSE" "$fixture_repository/LICENSE"
/bin/cp "$repository_root/THIRD_PARTY_NOTICES.md" "$fixture_repository/THIRD_PARTY_NOTICES.md"
/bin/cp "$repository_root/Config/runtime-lock.json" "$fixture_repository/Config/runtime-lock.json"
/bin/cp "$repository_root/Resources/Models.json" "$fixture_repository/Resources/Models.json"
/bin/cp "$repository_root/Resources/ThirdPartyComponents.json" "$fixture_repository/Resources/ThirdPartyComponents.json"
/bin/cp "$repository_root"/Licenses/*.txt "$fixture_repository/Licenses/"

copy_distribution_documents() {
    /bin/cp "$fixture_repository/LICENSE" "$app_resources/LICENSE"
    /bin/cp "$fixture_repository/THIRD_PARTY_NOTICES.md" "$app_resources/THIRD_PARTY_NOTICES.md"
    /bin/cp "$fixture_repository/Resources/ThirdPartyComponents.json" "$app_resources/ThirdPartyComponents.json"
    /bin/cp "$fixture_repository"/Licenses/*.txt "$app_resources/"
    /bin/cp "$fixture_repository/LICENSE" "$dmg_root/LICENSE"
    /bin/cp "$fixture_repository/THIRD_PARTY_NOTICES.md" "$dmg_root/THIRD_PARTY_NOTICES.md"
    /bin/cp "$fixture_repository/Resources/ThirdPartyComponents.json" "$dmg_root/ThirdPartyComponents.json"
    /bin/cp "$fixture_repository"/Licenses/*.txt "$dmg_root/Licenses/"
}

verify() {
    "$repository_root/Scripts/verify-license-compliance.sh" \
        --repository "$fixture_repository" \
        --app "$fixture_root/KotodamaVoice.app" \
        --dmg-root "$dmg_root"
}

expect_failure() {
    local label=$1
    if verify; then
        print -u2 "expected license verification failure: $label"
        exit 1
    fi
}

copy_distribution_documents
verify

fixture_dmg="$fixture_root/KotodamaVoice-license-fixture.dmg"
fixture_mount="$fixture_root/mounted-dmg"
/usr/bin/ditto "$fixture_root/KotodamaVoice.app" "$dmg_root/KotodamaVoice.app"
/usr/bin/hdiutil create \
    -volname KotodamaVoiceLicenseFixture \
    -srcfolder "$dmg_root" \
    -format UDZO \
    "$fixture_dmg" >/dev/null
/bin/mkdir "$fixture_mount"
/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$fixture_mount" \
    "$fixture_dmg" >/dev/null
mounted_fixture=$fixture_mount
"$repository_root/Scripts/verify-license-compliance.sh" \
    --repository "$fixture_repository" \
    --app "$fixture_mount/KotodamaVoice.app" \
    --dmg-root "$fixture_mount"
/usr/bin/hdiutil detach "$fixture_mount" >/dev/null
mounted_fixture=""

/bin/rm "$app_resources/Apache-2.0.txt"
expect_failure "missing app license"
/bin/cp "$fixture_repository/Licenses/Apache-2.0.txt" "$app_resources/Apache-2.0.txt"

/bin/rm "$dmg_root/Licenses/OpenAI-Whisper-LICENSE.txt"
expect_failure "missing DMG license"
/bin/cp "$fixture_repository/Licenses/OpenAI-Whisper-LICENSE.txt" "$dmg_root/Licenses/OpenAI-Whisper-LICENSE.txt"

print "tampered" >> "$app_resources/whisper.cpp-LICENSE.txt"
expect_failure "license hash mismatch"
/bin/cp "$fixture_repository/Licenses/whisper.cpp-LICENSE.txt" "$app_resources/whisper.cpp-LICENSE.txt"

/usr/bin/plutil -replace runtimes.whisper.commit \
    -string 0000000000000000000000000000000000000000 \
    "$fixture_repository/Config/runtime-lock.json"
expect_failure "runtime revision mismatch"
/bin/cp "$repository_root/Config/runtime-lock.json" "$fixture_repository/Config/runtime-lock.json"

/usr/bin/plutil -replace models.0.revision \
    -string 0000000000000000000000000000000000000000 \
    "$fixture_repository/Resources/Models.json"
expect_failure "model revision mismatch"

print "license distribution fixtures verified"
