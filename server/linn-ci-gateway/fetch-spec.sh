#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gateway_base_url="${GATEWAY_BASE_URL:-http://192.168.7.218:4100}"
spec_url="${OPENAPI_SPEC_URL:-${gateway_base_url}/api/swagger.yaml}"
target="$script_dir/openapi.original.yaml"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/linn-openapi-upstream.XXXXXX")"
scratch="$scratch_dir/spec.yaml"
trap 'rm -rf "$scratch_dir"' EXIT

curl --fail --location --silent --show-error "$spec_url" --output "$scratch"
mv "$scratch" "$target"
chmod 644 "$target"
echo "Updated $target from $spec_url"
