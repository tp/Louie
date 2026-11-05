#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
spec="$repo_root/Packages/LinnCiGateway/Sources/LinnCiGateway/openapi.yaml"
output="$repo_root/server/linn-ci-gateway/src/models"
image=openapitools/openapi-generator-cli@sha256:1f459499a7c794aa0ea769c3c9b0eb54806c5ad2f68510a0ebb9338d0a626ced
scratch="$(mktemp -d "${TMPDIR:-/tmp}/linn-openapi-rust.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [[ -n "${OPENAPI_GENERATOR_JAR:-}" ]]; then
  "${JAVA_BIN:-java}" -jar "$OPENAPI_GENERATOR_JAR" generate \
    --input-spec "$spec" \
    --generator-name rust \
    --output "$scratch/generated" \
    --additional-properties packageName=linn-ci-gateway,hideGenerationTimestamp=true \
    >/dev/null
else
  docker run --rm \
    --mount "type=bind,source=$(dirname "$spec"),target=/spec,readonly" \
    --mount "type=bind,source=$scratch,target=/out" \
    "$image" generate \
    --input-spec /spec/openapi.yaml \
    --generator-name rust \
    --output /out/generated \
    --additional-properties packageName=linn-ci-gateway,hideGenerationTimestamp=true \
    >/dev/null
fi

rm -rf "$output"
cp -R "$scratch/generated/src/models" "$output"
cargo fmt --manifest-path "$repo_root/server/linn-ci-gateway/Cargo.toml" --all
echo "Generated Rust models in $output"
