#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd -- "${PACKAGE_DIR}/../.." && pwd)"

GENERATOR_IMAGE_TAG="${OPENAPI_GENERATOR_IMAGE_TAG:-v7.22.0}"
GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://192.168.7.218:4100}"
SPEC_URL="${OPENAPI_SPEC_URL:-${GATEWAY_BASE_URL}/api/swagger.yaml}"

ORIGINAL_SPEC_PATH="${REPO_DIR}/server/linn-ci-gateway/openapi.original.yaml"
SPEC_PATH="${REPO_DIR}/server/linn-ci-gateway/openapi.yaml"
GENERATED_DIR="${PACKAGE_DIR}/Sources/LinnCiGateway/Generated"
WORK_DIR="${PACKAGE_DIR}/.build/openapi-generator"
OUTPUT_NAME="output-$$"
OUTPUT_DIR="${WORK_DIR}/${OUTPUT_NAME}"

GENERATOR_PROPERTIES="projectName=LinnCiGateway,packageName=LinnCiGateway,swiftPackagePath=Sources/LinnCiGateway/Generated,nonPublicApi=true,hideGenerationTimestamp=true"
GENERATOR_GLOBAL_PROPERTIES="models,supportingFiles"

mkdir -p "$(dirname "${SPEC_PATH}")" "${WORK_DIR}"

if ! command -v yq >/dev/null 2>&1; then
    cat >&2 <<EOF
yq is required to normalize the LinnCiGateway OpenAPI spec.
EOF
    exit 1
fi

if [[ "${OPENAPI_USE_LOCAL_SPEC:-0}" == "1" ]]; then
    echo "Using checked-in OpenAPI source at ${ORIGINAL_SPEC_PATH}"
else
    echo "Downloading OpenAPI document from ${SPEC_URL}"
    curl --fail --location --silent --show-error "${SPEC_URL}" --output "${ORIGINAL_SPEC_PATH}"
fi
bash "${REPO_DIR}/server/linn-ci-gateway/normalize.sh"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

generate_with_docker() {
    docker run --rm \
        --volume "${PACKAGE_DIR}:/local" \
        --volume "${REPO_DIR}/server/linn-ci-gateway:/spec:ro" \
        "openapitools/openapi-generator-cli:${GENERATOR_IMAGE_TAG}" generate \
        --input-spec /spec/openapi.yaml \
        --generator-name swift6 \
        --output "/local/.build/openapi-generator/${OUTPUT_NAME}" \
        --global-property "${GENERATOR_GLOBAL_PROPERTIES}" \
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
find "${GENERATED_DIR}" -name '*.swift' -type f -print0 | xargs -0 perl -0777 -i -pe 's/\n+\z/\n/'
rm -rf "${OUTPUT_DIR}"

echo "Stored original OpenAPI document at ${ORIGINAL_SPEC_PATH}"
echo "Updated ${SPEC_PATH}"
echo "Generated Swift client sources in ${GENERATED_DIR}"
