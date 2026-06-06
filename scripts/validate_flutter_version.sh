#!/usr/bin/env bash
set -euo pipefail

version_line="$(grep -E '^version:[[:space:]]*' pubspec.yaml | head -n 1)"
version="${version_line#version:}"
version="$(echo "$version" | tr -d '[:space:]')"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
  echo "pubspec.yaml version must use x.y.z+build, got: $version" >&2
  exit 1
fi

build_number="${version##*+}"
if [[ "$build_number" -le 0 ]]; then
  echo "Flutter build number must be greater than zero." >&2
  exit 1
fi

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  expected_tag="v$version"
  actual_tag="${GITHUB_REF_NAME:-}"
  if [[ "$actual_tag" != "$expected_tag" ]]; then
    echo "Release tag must match pubspec.yaml version." >&2
    echo "Expected: $expected_tag" >&2
    echo "Actual:   $actual_tag" >&2
    exit 1
  fi
fi

echo "Flutter version ok: $version"
