#!/usr/bin/env bash
set -euo pipefail

readonly project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly fixture_root="$project_root/.build/test-fixtures"
readonly model_path="$fixture_root/ggml-tiny.en-q5_1.bin"
readonly model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.en-q5_1.bin?download=true"
readonly model_sha256="c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b"
readonly audio_path="$project_root/.build/runtimes/sources/whisper/samples/jfk.wav"
readonly audio_sha256="59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"

for tool in curl shasum; do
  if ! command -v "$tool" >/dev/null; then
    echo "error: required tool is missing: $tool" >&2
    exit 1
  fi
done

verify_sha256() {
  local path="$1"
  local expected="$2"
  [[ -f "$path" ]] || return 1
  [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected" ]]
}

if ! verify_sha256 "$audio_path" "$audio_sha256"; then
  echo "error: pinned jfk.wav is missing or invalid; run Scripts/build-runtime-xcframeworks.sh" >&2
  exit 1
fi

mkdir -p "$fixture_root"
if ! verify_sha256 "$model_path" "$model_sha256"; then
  readonly download_path="$(mktemp "$fixture_root/model.XXXXXX")"
  trap 'rm -f "$download_path"' EXIT
  curl --fail --location --retry 3 --output "$download_path" "$model_url"
  if ! verify_sha256 "$download_path" "$model_sha256"; then
    echo "error: downloaded speech test model failed SHA-256 verification" >&2
    exit 1
  fi
  mv "$download_path" "$model_path"
  trap - EXIT
fi
