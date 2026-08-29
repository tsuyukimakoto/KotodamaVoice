#!/bin/zsh

set -euo pipefail

usage() {
    print -u2 "usage: $0 --repository /path/to/repository [--app /path/to/KotodamaVoice.app] [--dmg-root /path/to/mounted-dmg]"
    exit 64
}

repository_root=""
app_path=""
dmg_root=""
while (( $# > 0 )); do
    case $1 in
        --repository)
            (( $# >= 2 )) || usage
            repository_root=$2
            shift 2
            ;;
        --app)
            (( $# >= 2 )) || usage
            app_path=$2
            shift 2
            ;;
        --dmg-root)
            (( $# >= 2 )) || usage
            dmg_root=$2
            shift 2
            ;;
        *) usage ;;
    esac
done

[[ -n $repository_root ]] || usage
manifest_path="$repository_root/Resources/ThirdPartyComponents.json"
runtime_lock_path="$repository_root/Config/runtime-lock.json"
models_path="$repository_root/Resources/Models.json"

fail() {
    print -u2 "license verification failed: $1"
    exit 1
}

require_file() {
    local path=$1
    [[ -f $path ]] || fail "missing file: $path"
}

require_matching_file() {
    local expected=$1
    local actual=$2
    local label=$3
    require_file "$expected"
    require_file "$actual"
    /usr/bin/cmp -s "$expected" "$actual" \
        || fail "$label does not match the tracked source: $actual"
}

manifest_value() {
    local key_path=$1
    local file_path=$2
    /usr/bin/plutil -extract "$key_path" raw -o - "$file_path" 2>/dev/null
}

find_model_index() {
    local target_id=$1
    local model_index=0
    local candidate
    while candidate=$(manifest_value "models.$model_index.id" "$models_path"); do
        if [[ $candidate == $target_id ]]; then
            print "$model_index"
            return 0
        fi
        (( model_index += 1 ))
    done
    return 1
}

require_file "$manifest_path"
require_file "$runtime_lock_path"
require_file "$models_path"
require_file "$repository_root/LICENSE"
require_file "$repository_root/THIRD_PARTY_NOTICES.md"

if [[ -n $app_path ]]; then
    app_resources="$app_path/Contents/Resources"
    [[ -d $app_resources ]] || fail "missing app resources: $app_resources"
    require_matching_file \
        "$repository_root/LICENSE" \
        "$app_resources/LICENSE" \
        "app project license"
    require_matching_file \
        "$repository_root/THIRD_PARTY_NOTICES.md" \
        "$app_resources/THIRD_PARTY_NOTICES.md" \
        "app third-party notices"
    require_matching_file \
        "$manifest_path" \
        "$app_resources/ThirdPartyComponents.json" \
        "app third-party manifest"
fi

if [[ -n $dmg_root ]]; then
    [[ -d $dmg_root ]] || fail "missing DMG root: $dmg_root"
    require_matching_file \
        "$repository_root/LICENSE" \
        "$dmg_root/LICENSE" \
        "DMG project license"
    require_matching_file \
        "$repository_root/THIRD_PARTY_NOTICES.md" \
        "$dmg_root/THIRD_PARTY_NOTICES.md" \
        "DMG third-party notices"
    require_matching_file \
        "$manifest_path" \
        "$dmg_root/ThirdPartyComponents.json" \
        "DMG third-party manifest"
fi

component_index=0
while component_id=$(manifest_value "components.$component_index.id" "$manifest_path"); do
    version=$(manifest_value "components.$component_index.version" "$manifest_path")
    license_name=$(manifest_value "components.$component_index.licenseName" "$manifest_path")
    license_file=$(manifest_value "components.$component_index.licenseFile" "$manifest_path")
    expected_hash=$(manifest_value "components.$component_index.licenseSHA256" "$manifest_path")
    scopes=$(/usr/bin/plutil -extract "components.$component_index.scopes" json -o - "$manifest_path")
    tracked_license="$repository_root/$license_file"
    require_file "$tracked_license"
    actual_hash=$(/usr/bin/shasum -a 256 "$tracked_license" | /usr/bin/awk '{print $1}')
    [[ $actual_hash == $expected_hash ]] \
        || fail "tracked license hash mismatch for $component_id"

    if [[ -n $app_path && $scopes == *'"application"'* ]]; then
        require_matching_file \
            "$tracked_license" \
            "$app_resources/${license_file:t}" \
            "app license for $component_id"
    fi
    if [[ -n $dmg_root && $scopes == *'"diskImage"'* ]]; then
        require_matching_file \
            "$tracked_license" \
            "$dmg_root/Licenses/${license_file:t}" \
            "DMG license for $component_id"
    fi

    runtime_id=$(manifest_value "components.$component_index.runtimeID" "$manifest_path" || true)
    if [[ -n $runtime_id ]]; then
        runtime_commit=$(manifest_value "runtimes.$runtime_id.commit" "$runtime_lock_path") \
            || fail "runtime is missing from lock: $runtime_id"
        [[ $runtime_commit == $version ]] \
            || fail "runtime revision mismatch for $component_id"
    fi

    model_id_index=0
    while model_id=$(manifest_value "components.$component_index.modelIDs.$model_id_index" "$manifest_path"); do
        model_index=$(find_model_index "$model_id") \
            || fail "model is missing from manifest: $model_id"
        model_revision=$(manifest_value "models.$model_index.revision" "$models_path")
        model_license=$(manifest_value "models.$model_index.licenseName" "$models_path")
        model_license_file=$(manifest_value "models.$model_index.licenseFile" "$models_path")
        [[ $model_revision == $version ]] \
            || fail "model revision mismatch for $model_id"
        [[ $model_license == $license_name ]] \
            || fail "model license mismatch for $model_id"
        [[ $model_license_file == ${license_file:t} ]] \
            || fail "model bundled license mismatch for $model_id"
        (( model_id_index += 1 ))
    done

    (( component_index += 1 ))
done

print "license materials verified"
