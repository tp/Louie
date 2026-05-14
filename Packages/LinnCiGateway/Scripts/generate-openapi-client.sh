#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

GENERATOR_IMAGE_TAG="${OPENAPI_GENERATOR_IMAGE_TAG:-v7.22.0}"
GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://192.168.7.218:4100}"
SPEC_URL="${OPENAPI_SPEC_URL:-${GATEWAY_BASE_URL}/api/swagger.yaml}"

ORIGINAL_SPEC_PATH="${PACKAGE_DIR}/Sources/LinnCiGateway/openapi.original.yaml"
SPEC_PATH="${PACKAGE_DIR}/Sources/LinnCiGateway/openapi.yaml"
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

echo "Downloading OpenAPI document from ${SPEC_URL}"
curl --fail --location --silent --show-error "${SPEC_URL}" --output "${ORIGINAL_SPEC_PATH}"
cp "${ORIGINAL_SPEC_PATH}" "${SPEC_PATH}"

# Keep only the websocket paths the package wraps. The generated HTTP API
# classes are not used, but path filtering prevents operation-derived models
# from being generated for unrelated endpoints.
yq -i '.paths = (.paths | pick([
    "/session/create",
    "/V2/topology/status",
    "/V2/transport/status",
    "/V2/transport/play",
    "/V2/transport/pause",
    "/V2/transport/skip_track",
    "/V2/seek/status",
    "/V2/metadata/status",
    "/V2/volume/status",
    "/V2/volume/set_vol",
    "/V2/volume/set_mute",
    "/V2/playlist/subscribe",
    "/V2/playlist/select"
]))' "${SPEC_PATH}"

# YAML 1.1 parsers treat unquoted ON/OFF as booleans. The Linn spec uses those
# strings for StandbyStateEnum, so normalize them before generation.
yq -i '.definitions.StandbyStateEnum.enum = ["OFF", "MIXED", "ON"]' "${SPEC_PATH}"

# The live gateway sends track artists as an array of strings, even though the
# published schema currently says the field is a single string.
yq -i '(.definitions[]?.properties.artist | select(.type == "string")) = {
    "type": "array",
    "items": {"type": "string"},
    "description": "Artist name"
}' "${SPEC_PATH}"

# Playlist children are returned as an object keyed by playlist index, not as a
# literal "index" property.
yq -i '.definitions.V2PlaylistBrowseIndex = {
    "type": "object",
    "description": "Index of a position in a rooms playlist and the item metadata it contains.",
    "additionalProperties": {"$ref": "#/definitions/V2PlaylistItemMetadata"}
}' "${SPEC_PATH}"

# Playlist item metadata includes track details in live responses.
yq -i '.definitions.V2PlaylistItemMetadata.properties.album = {
    "type": "string",
    "description": "Album name"
} |
.definitions.V2PlaylistItemMetadata.properties.artist = {
    "type": "array",
    "items": {"type": "string"},
    "description": "Artist name"
} |
.definitions.V2PlaylistItemMetadata.properties.duration = {
    "type": "integer",
    "format": "int32",
    "description": "Duration of the item in seconds. 0 if unknown"
}' "${SPEC_PATH}"

# Keep the refined spec small without hand-authoring generated schemas here.
# This keeps the session helpers, shared request params, and the V2 surfaces
# the wrapper uses. A few nearby V2 models are cheaper than a brittle script.
yq -i '.definitions = (.definitions | with_entries(select(
    .key == "FilterSpec" or
    .key == "SessionData" or
    .key == "SessionResponse" or
    (.key | test("^Param(Tag|Session|Room|Update|Filter)$")) or
    (.key | test("^V2(TopologyStatus|Transport|Seek|Metadata|Volume|Playlist)"))
)))' "${SPEC_PATH}"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

generate_with_docker() {
    docker run --rm \
        --volume "${PACKAGE_DIR}:/local" \
        "openapitools/openapi-generator-cli:${GENERATOR_IMAGE_TAG}" generate \
        --input-spec /local/Sources/LinnCiGateway/openapi.yaml \
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
rm -rf "${OUTPUT_DIR}"

echo "Stored original OpenAPI document at ${ORIGINAL_SPEC_PATH}"
echo "Updated ${SPEC_PATH}"
echo "Generated Swift client sources in ${GENERATED_DIR}"
