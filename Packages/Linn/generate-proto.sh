#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$package_dir/../.." && pwd)"
swift_protobuf="$package_dir/.build/checkouts/swift-protobuf"
grpc_protobuf="$package_dir/.build/checkouts/grpc-swift-protobuf"
output="$package_dir/Sources/Linn/Generated"

command -v protoc >/dev/null || { echo 'Install a local protoc first.' >&2; exit 1; }
swift package --package-path "$package_dir" resolve
swift build --package-path "$swift_protobuf" -c release --product protoc-gen-swift
swift build --package-path "$grpc_protobuf" -c release --product protoc-gen-grpc-swift-2
mkdir -p "$output"

protoc \
  -I "$repo_dir/proto" \
  --plugin="protoc-gen-swift=$swift_protobuf/.build/release/protoc-gen-swift" \
  --plugin="protoc-gen-grpc-swift-2=$grpc_protobuf/.build/release/protoc-gen-grpc-swift-2" \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_out="$output" \
  --grpc-swift-2_opt=Client=true,Server=false \
  --grpc-swift-2_opt=FileNaming=PathToUnderscores \
  --grpc-swift-2_out="$output" \
  "$repo_dir/proto/louie/linn/v1/linn.proto"
