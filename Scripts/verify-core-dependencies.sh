#!/bin/sh
set -eu

source_root="${1:-$SRCROOT/Sources/KotodamaCore}"
forbidden_pattern='(^|[[:space:]])(import|@_exported[[:space:]]+import)[[:space:]]+(AppKit|AVFoundation|whisper|llama)($|[[:space:]])'

if /usr/bin/grep -ERn "$forbidden_pattern" "$source_root"; then
  echo "error: KotodamaCore contains a forbidden dependency" >&2
  exit 1
fi
