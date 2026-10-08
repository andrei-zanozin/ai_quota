#!/bin/zsh
set -euo pipefail
source_dir="${0:A:h}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiquota-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
architecture="$(uname -m)"
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/aiquota-module-cache" \
  -target "$architecture-apple-macosx14.0" \
  "$source_dir/QuotaClient.swift" "$source_dir/ClientTests.swift" -o "$test_dir/client-tests"
"$test_dir/client-tests"
