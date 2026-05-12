#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

GENERATOR_IMAGE_TAG="${OPENAPI_GENERATOR_IMAGE_TAG:-v7.22.0}"
GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://192.168.7.218:4100}"
SPEC_URL="${OPENAPI_SPEC_URL:-${GATEWAY_BASE_URL}/api/swagger.yaml}"

SPEC_PATH="${PACKAGE_DIR}/Sources/LinnCiGateway/openapi.yaml"
GENERATED_DIR="${PACKAGE_DIR}/Sources/LinnCiGateway/Generated"
WORK_DIR="${PACKAGE_DIR}/.build/openapi-generator"
OUTPUT_DIR="${WORK_DIR}/output"

GENERATOR_PROPERTIES="projectName=LinnCiGateway,packageName=LinnCiGateway,swiftPackagePath=Sources/LinnCiGateway/Generated,nonPublicApi=true,hideGenerationTimestamp=true"

mkdir -p "$(dirname "${SPEC_PATH}")" "${WORK_DIR}"

echo "Downloading OpenAPI document from ${SPEC_URL}"
curl --fail --location --silent --show-error "${SPEC_URL}" --output "${SPEC_PATH}"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

generate_with_docker() {
    docker run --rm \
        --volume "${PACKAGE_DIR}:/local" \
        "openapitools/openapi-generator-cli:${GENERATOR_IMAGE_TAG}" generate \
        --input-spec /local/Sources/LinnCiGateway/openapi.yaml \
        --generator-name swift6 \
        --output /local/.build/openapi-generator/output \
        --additional-properties "${GENERATOR_PROPERTIES}"
}

if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<EOF
Docker is required to generate the LinnCiGateway OpenAPI client.
EOF
    exit 1
fi

echo "Generating with Docker"
generate_with_docker

rm -rf "${GENERATED_DIR}"
mkdir -p "${GENERATED_DIR}"
cp -R "${OUTPUT_DIR}/Sources/LinnCiGateway/Generated/." "${GENERATED_DIR}/"

find "${GENERATED_DIR}" -name '*.swift' -print0 |
    xargs -0 perl -0pi -e 's/enum CodingKeys: String, CodingKey, CaseIterable \{\n(\s*)\}/enum CodingKeys: CodingKey, CaseIterable {\n$1}/g'
find "${GENERATED_DIR}" -name '*.swift' -print0 |
    xargs -0 perl -0pi -e 's/var container = encoder\.container\(keyedBy: CodingKeys\.self\)\n(\s*)\}/_ = encoder.container(keyedBy: CodingKeys.self)\n$1}/g'

echo "Updated ${SPEC_PATH}"
echo "Generated Swift client sources in ${GENERATED_DIR}"
