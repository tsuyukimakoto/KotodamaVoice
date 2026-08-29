#!/usr/bin/env bash
set -euo pipefail

readonly project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly lock_file="$project_root/Config/runtime-lock.json"
readonly work_root="${KOTODAMA_RUNTIME_BUILD_ROOT:-$project_root/.build/runtimes}"
readonly source_root="$work_root/sources"
readonly build_root="$work_root/build"
readonly artifact_root="$work_root/artifacts"
readonly deployment_target="14.0"

for tool in cmake git xcrun plutil shasum; do
  if ! command -v "$tool" >/dev/null; then
    echo "error: required tool is missing: $tool" >&2
    exit 1
  fi
done

mkdir -p "$source_root" "$build_root" "$artifact_root"

lock_value() {
  /usr/bin/plutil -extract "runtimes.$1.$2" raw -o - "$lock_file"
}

checkout_runtime() {
  local runtime="$1"
  local repository commit directory actual_commit
  repository="$(lock_value "$runtime" repository)"
  commit="$(lock_value "$runtime" commit)"
  directory="$source_root/$runtime"

  if [[ ! -d "$directory/.git" ]]; then
    git clone --filter=blob:none "$repository" "$directory"
  fi

  git -C "$directory" fetch --depth 1 origin "$commit"
  git -C "$directory" checkout --detach "$commit"
  actual_commit="$(git -C "$directory" rev-parse HEAD)"
  if [[ "$actual_commit" != "$commit" ]]; then
    echo "error: $runtime checkout does not match runtime lock" >&2
    exit 1
  fi
}

cmake_common_args=(
  -G Xcode
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target"
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_BLAS_DEFAULT=ON
  -DGGML_CCACHE=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
)

create_framework() {
  local runtime="$1"
  local include_directory="$2"
  shift 2
  local static_libraries=("$@")
  local runtime_build="$build_root/$runtime"
  local framework_root="$runtime_build/framework/$runtime.framework"
  local version_root="$framework_root/Versions/A"
  local combined_archive="$runtime_build/lib${runtime}-combined.a"
  local binary="$version_root/$runtime"
  local xcframework="$artifact_root/$runtime.xcframework"
  local expected_hash actual_hash architectures

  mkdir -p "$version_root/Headers" "$version_root/Modules" "$version_root/Resources"
  ln -sfn A "$framework_root/Versions/Current"
  ln -sfn Versions/Current/Headers "$framework_root/Headers"
  ln -sfn Versions/Current/Modules "$framework_root/Modules"
  ln -sfn Versions/Current/Resources "$framework_root/Resources"
  ln -sfn "Versions/Current/$runtime" "$framework_root/$runtime"

  cp "$include_directory"/*.h "$version_root/Headers/"
  local public_headers
  if [[ "$runtime" == "whisper" ]]; then
    public_headers='  header "whisper.h"
  header "parakeet.h"
  header "ggml.h"
  header "ggml-alloc.h"
  header "ggml-backend.h"
  header "ggml-blas.h"
  header "ggml-cpu.h"
  header "ggml-metal.h"
  header "gguf.h"'
  else
    public_headers='  header "llama.h"
  header "ggml.h"
  header "ggml-alloc.h"
  header "ggml-backend.h"
  header "ggml-blas.h"
  header "ggml-cpu.h"
  header "ggml-metal.h"
  header "ggml-opt.h"
  header "gguf.h"'
  fi

  cat > "$version_root/Modules/module.modulemap" <<MODULEMAP
framework module $runtime {
$public_headers
  link "c++"
  link framework "Accelerate"
  link framework "Foundation"
  link framework "Metal"
  export *
}
MODULEMAP

  cat > "$version_root/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$runtime</string>
  <key>CFBundleIdentifier</key><string>com.tsuyukimakoto.KotodamaVoice.$runtime</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$runtime</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$deployment_target</string>
</dict>
</plist>
PLIST

  xcrun libtool -static -o "$combined_archive" "${static_libraries[@]}"
  xcrun --sdk macosx clang++ -dynamiclib \
    -arch arm64 \
    -mmacosx-version-min="$deployment_target" \
    -Wl,-force_load,"$combined_archive" \
    -framework Accelerate \
    -framework Foundation \
    -framework Metal \
    -install_name "@rpath/$runtime.framework/Versions/Current/$runtime" \
    -o "$binary"

  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "error: $runtime has unexpected architectures: $architectures" >&2
    exit 1
  fi

  if [[ -e "$xcframework" ]]; then
    rm -r "$xcframework"
  fi
  xcrun xcodebuild -create-xcframework -framework "$framework_root" -output "$xcframework"

  actual_hash="$(shasum -a 256 "$binary" | awk '{print $1}')"
  expected_hash="$(lock_value "$runtime" binarySha256)"
  echo "$runtime binary SHA-256: $actual_hash"
  if [[ -n "$expected_hash" && "$actual_hash" != "$expected_hash" ]]; then
    echo "error: $runtime binary hash does not match runtime lock" >&2
    exit 1
  fi
}

build_whisper() {
  local source="$source_root/whisper"
  local output="$build_root/whisper/cmake"
  local headers="$build_root/whisper/headers"
  cmake -S "$source" -B "$output" "${cmake_common_args[@]}" \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_COREML=OFF
  cmake --build "$output" --config Release --target whisper --parallel -- -quiet

  mkdir -p "$headers"
  cp "$source/include/"*.h "$headers/"
  cp "$source/ggml/include/"*.h "$headers/"

  local libraries=(
    "$output/src/Release/libwhisper.a"
    "$output/ggml/src/Release/libggml.a"
    "$output/ggml/src/Release/libggml-base.a"
    "$output/ggml/src/Release/libggml-cpu.a"
    "$output/ggml/src/ggml-metal/Release/libggml-metal.a"
    "$output/ggml/src/ggml-blas/Release/libggml-blas.a"
  )
  create_framework whisper "$headers" "${libraries[@]}"
}

build_llama() {
  local source="$source_root/llama"
  local output="$build_root/llama/cmake"
  local headers="$build_root/llama/headers"
  cmake -S "$source" -B "$output" "${cmake_common_args[@]}" \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_MTMD=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_OPENSSL=OFF
  cmake --build "$output" --config Release --target llama --parallel -- -quiet

  mkdir -p "$headers"
  cp "$source/include/"*.h "$headers/"
  cp "$source/ggml/include/"*.h "$headers/"

  local libraries=(
    "$output/src/Release/libllama.a"
    "$output/ggml/src/Release/libggml.a"
    "$output/ggml/src/Release/libggml-base.a"
    "$output/ggml/src/Release/libggml-cpu.a"
    "$output/ggml/src/ggml-metal/Release/libggml-metal.a"
    "$output/ggml/src/ggml-blas/Release/libggml-blas.a"
  )
  create_framework llama "$headers" "${libraries[@]}"
}

checkout_runtime whisper
checkout_runtime llama
build_whisper
build_llama
