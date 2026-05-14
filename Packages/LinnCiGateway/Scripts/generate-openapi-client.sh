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

# YAML 1.1 parsers treat unquoted ON/OFF as booleans. The Linn spec uses
# those strings for StandbyStateEnum, so normalize them before generation.
perl -0pi -e 's/^([[:space:]]*-[[:space:]]*)(OFF|MIXED|ON)[[:space:]]*$/$1"$2"/mg; s/^([[:space:]]*standbyState:[[:space:]]*)(OFF|MIXED|ON)[[:space:]]*$/$1"$2"/mg' "${SPEC_PATH}"

# The live gateway sends track artists as an array of strings, even though the
# published schema currently says the field is a single string.
perl -0pi -e 's/(      artist:\r?\n)        type: string\r?\n(        description: Artist name\r?\n)/$1        type: array\n        items:\n          type: string\n$2/g' "${SPEC_PATH}"

# Playlist children are returned as an object keyed by playlist index, not as a
# literal "index" property.
perl -0pi -e "s~  V2PlaylistBrowseIndex:\r?\n    type: object\r?\n    description: Index of a position in a rooms playlist and the item metadata it contains\.\r?\n    properties:\r?\n      index:\r?\n        \\\$ref: '#/definitions/V2PlaylistItemMetadata'\r?\n~  V2PlaylistBrowseIndex:\n    type: object\n    description: Index of a position in a rooms playlist and the item metadata it contains.\n    additionalProperties:\n      \\\$ref: '#/definitions/V2PlaylistItemMetadata'\n~g" "${SPEC_PATH}"

# Playlist item metadata includes track details in live responses.
perl -0pi -e 's/(      art_uri:\r?\n        type: string\r?\n        description: URL for associated logo\/album art for item\. Can be null\.\r?\n)(      disabledActions:\r?\n)/$1      album:\n        type: string\n        description: Album name\n      artist:\n        type: array\n        items:\n          type: string\n        description: Artist name\n      duration:\n        type: integer\n        format: int32\n        description: Duration of the item in seconds. 0 if unknown\n$2/g' "${SPEC_PATH}"

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
