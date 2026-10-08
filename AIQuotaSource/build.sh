#!/bin/zsh
set -euo pipefail
source_dir="${0:A:h}"
build_dir="${source_dir:h}/AI Quota.app"
mkdir -p "$build_dir/Contents/MacOS"
architecture="$(uname -m)"
xcrun swiftc -swift-version 5 -O -module-cache-path "${TMPDIR:-/tmp}/aiquota-module-cache" \
  -target "$architecture-apple-macosx14.0" \
  "$source_dir/QuotaClient.swift" "$source_dir/App.swift" \
  -o "$build_dir/Contents/MacOS/AIQuota"
cp "$source_dir/Info.plist" "$build_dir/Contents/Info.plist"
codesign --force --sign - "$build_dir"
print "Built: $build_dir"
