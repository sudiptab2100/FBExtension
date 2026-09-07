#!/bin/bash
set -euo pipefail

source "$HOME/.localdrive_flutter_env.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
platform="$developer/Platforms/MacOSX.platform/Developer"
scratch=".native-checks/runner-$$"
mkdir -p .native-checks
mkdir "$scratch"
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/scratch" "$scratch/module-cache"
export TMPDIR="$PWD/$scratch/scratch"

xcrun swiftc -swift-version 5 \
  -module-cache-path "$scratch/module-cache" \
  -I "$platform/usr/lib" -L "$platform/usr/lib" \
  -F "$platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$platform/usr/lib" \
  Runner/BackgroundUploadState.swift RunnerTests/RunnerTests.swift \
  RunnerTests/Standalone/main.swift -o "$scratch/native-regressions"

DYLD_FRAMEWORK_PATH="$platform/Library/PrivateFrameworks:$platform/Library/Frameworks:$(dirname "$developer")/SharedFrameworks" \
  "$scratch/native-regressions"
