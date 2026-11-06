#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
spec="$repo_root/server/linn-ci-gateway/openapi.yaml"
output="$repo_root/server/linn-ci-gateway/src/models"
image=openapitools/openapi-generator-cli@sha256:1f459499a7c794aa0ea769c3c9b0eb54806c5ad2f68510a0ebb9338d0a626ced
scratch="$(mktemp -d "${TMPDIR:-/tmp}/linn-openapi-rust.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Rust's model module index is a supporting file, so include it alongside models.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$(dirname "$spec"),target=/spec,readonly" \
  --mount "type=bind,source=$scratch,target=/out" \
  "$image" generate \
  --input-spec /spec/openapi.yaml \
  --generator-name rust \
  --global-property models,supportingFiles=mod.rs,modelDocs=false,modelTests=false \
  --output /out/generated \
  --additional-properties packageName=linn-ci-gateway,hideGenerationTimestamp=true \
  >/dev/null

rm -rf "$output"
cp -R "$scratch/generated/src/models" "$output"
(cd "$repo_root/server" && cargo fmt -p linn-ci-gateway)
echo "Generated Rust models in $output"
