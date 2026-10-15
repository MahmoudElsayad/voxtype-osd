#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d /tmp/voxtype-tests.XXXXXX)
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos13 -o "$output/settings-test" \
  $(rg --files Sources -g '*.swift' -g '!main.swift') tests/main.swift
"$output/settings-test" "${1:-/tmp/voxtype-codex-settings.png}"
