#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}

scheme=KotodamaVoice
configuration=Release
archive_path=""
export_dir=""
app_name=KotodamaVoice.app
export_options="$repository_root/Config/DeveloperIDExportOptions.plist"
dmg_output=""
keychain_profile=KotodamaVoice

while (( $# )); do
    case $1 in
        --scheme)            scheme=$2; shift 2 ;;
        --configuration)     configuration=$2; shift 2 ;;
        --archive-path)      archive_path=$2; shift 2 ;;
        --export-dir)        export_dir=$2; shift 2 ;;
        --dmg)               dmg_output=$2; shift 2 ;;
        --keychain-profile)  keychain_profile=$2; shift 2 ;;
        -h|--help)
            print "usage: $0 --dmg PATH [--scheme NAME] [--configuration CONFIG]"
            print "          [--archive-path PATH] [--export-dir DIR]"
            print "          [--keychain-profile NAME]"
            exit 0
            ;;
        *)
            print -u2 "unknown argument: $1"
            exit 64
            ;;
    esac
done

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print -u2 "required tool not found on PATH: $1"
        exit 70
    fi
}

if [[ -z $dmg_output ]]; then
    print -u2 "--dmg is required because the signed DMG is the notarization target"
    exit 64
fi

if [[ ! -f $export_options ]]; then
    print -u2 "export options plist not found: $export_options"
    exit 66
fi

require xcodebuild
require xcrun

team_id=$(/usr/bin/plutil -extract teamID raw -o - "$export_options")
if [[ -z $team_id ]]; then
    print -u2 "could not read teamID from export options"
    exit 1
fi

artifact_root="$repository_root/.build/direct-distribution"
/bin/mkdir -p "$artifact_root"
run_directory=$(/usr/bin/mktemp -d "$artifact_root/run.XXXXXX")

if [[ -z $archive_path ]]; then
    archive_path="$run_directory/KotodamaVoice.xcarchive"
else
    archive_path=${archive_path:A}
fi

if [[ -z $export_dir ]]; then
    export_dir="$run_directory/export"
else
    export_dir=${export_dir:A}
fi

dmg_output=${dmg_output:A}
app_path="$export_dir/$app_name"
notary_result_path="$run_directory/notary-submit.json"
notary_log_path="$run_directory/notary-log.json"

if [[ -e $archive_path ]]; then
    print -u2 "archive destination already exists: $archive_path"
    exit 73
fi

if [[ -e $export_dir ]]; then
    print -u2 "export destination already exists: $export_dir"
    exit 73
fi

if [[ -e $dmg_output ]]; then
    print -u2 "DMG destination already exists: $dmg_output"
    exit 73
fi

/bin/mkdir -p "${archive_path:h}" "${export_dir:h}" "${dmg_output:h}"

notary() {
    /usr/bin/xcrun notarytool "$@"
}

print "== Building Release archive =="
/usr/bin/xcodebuild \
    -project "$repository_root/KotodamaVoice.xcodeproj" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -archivePath "$archive_path" \
    -destination "generic/platform=macOS" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team_id" \
    archive

print "== Exporting Developer-ID-signed app =="
/usr/bin/xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportOptionsPlist "$export_options" \
    -exportPath "$export_dir" \
    -allowProvisioningUpdates

if [[ ! -d $app_path ]]; then
    print -u2 "exported app not found: $app_path"
    exit 66
fi

print "== Verifying exported app =="
"$script_directory/verify-direct-distribution.sh" "$app_path"

print "== Creating signed DMG =="
"$script_directory/create-direct-distribution-dmg.sh" "$app_path" "$dmg_output"

print "== Submitting DMG to Apple notarization =="
if ! notary submit "$dmg_output" \
    --wait \
    --output-format json \
    --keychain-profile "$keychain_profile" \
    > "$notary_result_path"; then
    /bin/cat "$notary_result_path" >&2
    print -u2 "notarytool submission failed"
    exit 1
fi

/bin/cat "$notary_result_path"
submission_id=$(/usr/bin/plutil -extract id raw -o - "$notary_result_path" 2>/dev/null || true)
notary_status=$(/usr/bin/plutil -extract status raw -o - "$notary_result_path" 2>/dev/null || true)

if [[ -z $submission_id || -z $notary_status ]]; then
    print -u2 "notarytool response did not contain id and status"
    exit 1
fi

print "== Retrieving notarization log =="
if ! notary log "$submission_id" "$notary_log_path" \
    --keychain-profile "$keychain_profile"; then
    print -u2 "could not retrieve notarization log for submission: $submission_id"
    exit 1
fi
/bin/cat "$notary_log_path"

if [[ $notary_status != Accepted ]]; then
    print -u2 "notarization was not accepted: $notary_status"
    print -u2 "submission id: $submission_id"
    print -u2 "notarization log: $notary_log_path"
    exit 1
fi

print "== Stapling and validating DMG ticket =="
/usr/bin/xcrun stapler staple "$dmg_output"
/usr/bin/xcrun stapler validate "$dmg_output"

print "== Assessing notarized DMG =="
/usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$dmg_output"
"$script_directory/verify-direct-distribution-dmg.sh" "$dmg_output"

mount_directory=$(/usr/bin/mktemp -d "$run_directory/mount.XXXXXX")
mounted=false
cleanup_mount() {
    if [[ $mounted == true ]]; then
        /usr/bin/hdiutil detach "$mount_directory" >/dev/null 2>&1 || true
    fi
}
trap cleanup_mount EXIT

/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mount_directory" \
    "$dmg_output" >/dev/null
mounted=true

print "== Assessing app inside notarized DMG =="
/usr/sbin/spctl \
    --assess \
    --type exec \
    --verbose=4 \
    "$mount_directory/$app_name"

/usr/bin/hdiutil detach "$mount_directory" >/dev/null
mounted=false

print "notarized dmg: $dmg_output"
print "exported app: $app_path"
print "submission id: $submission_id"
print "notarization status: $notary_status"
print "notarization log: $notary_log_path"
