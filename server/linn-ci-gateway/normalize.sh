#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIGINAL_SPEC_PATH="$repo_root/server/linn-ci-gateway/openapi.original.yaml"
OUTPUT_SPEC_PATH="$repo_root/server/linn-ci-gateway/openapi.yaml"

if ! command -v yq >/dev/null 2>&1 || ! yq --version | grep -Eq 'mikefarah/yq.*version v4\.'; then
  echo "mikefarah yq v4 is required to normalize the Linn gateway OpenAPI spec" >&2
  exit 1
fi

SPEC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linn-openapi.XXXXXX")"
SPEC_PATH="$SPEC_DIR/spec.yaml"
trap 'rm -rf "$SPEC_DIR"' EXIT
cp "${ORIGINAL_SPEC_PATH}" "${SPEC_PATH}"

# Keep only the websocket paths the package wraps. The generated HTTP API
# classes are not used, but path filtering prevents operation-derived models
# from being generated for unrelated endpoints.
yq -i '.paths = (.paths | pick([
    "/session/create",
    "/V2/topology/status",
    "/V2/product/status",
    "/V2/product/set_standby",
    "/V2/transport/status",
    "/V2/transport/play",
    "/V2/transport/pause",
    "/V2/transport/skip_track",
    "/V2/seek/status",
    "/V2/seek/set_position",
    "/V2/metadata/status",
    "/V2/volume/status",
    "/V2/volume/set_vol",
    "/V2/volume/set_mute",
    "/V2/playlist/subscribe",
    "/V2/playlist/select",
    "/V2/services/status",
    "/V2/services/search",
    "/V2/media/browse",
    "/V2/media/select",
    "/V2/media/favourite"
]))' "${SPEC_PATH}"

# YAML 1.1 parsers treat unquoted ON/OFF as booleans. The Linn spec uses those
# strings for StandbyStateEnum, so normalize them before generation.
yq -i '.definitions.StandbyStateEnum.enum = ["OFF", "MIXED", "ON"]' "${SPEC_PATH}"

# The live gateway sends track artists as an array of strings, even though the
# published schema currently says the field is a single string.
yq -i 'with(.definitions[] | select(.properties.artist.type == "string"); .properties.artist = {
    "type": "array",
    "items": {"type": "string"},
    "description": "Artist name"
})' "${SPEC_PATH}"

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
} |
del(.definitions.V2PlaylistItemMetadata.discriminator)' "${SPEC_PATH}"

# Media browse items are modeled in the upstream spec through composed
# subclasses, but the websocket wrapper maps a flat item model. Keep the
# generated model broad enough for Qobuz album, track, playlist, and favourite
# metadata without hand-authoring service-specific response structs.
yq -i '.definitions.ItemMetaData.properties.title = {
    "type": "string",
    "description": "Track title"
} |
.definitions.ItemMetaData.properties.album = {
    "type": "string",
    "description": "Album name"
} |
.definitions.ItemMetaData.properties.artist = {
    "type": "array",
    "items": {"type": "string"},
    "description": "Artist name"
} |
.definitions.ItemMetaData.properties.duration = {
    "type": "integer",
    "format": "int32",
    "description": "Duration of the item in seconds. 0 if unknown"
} |
.definitions.ItemMetaData.properties.contained_classes = {
    "type": "array",
    "items": {"type": "string"},
    "description": "Array of class ids indicating the type(s) of the content of this item."
} |
.definitions.ItemMetaData.properties.count = {
    "type": "integer",
    "format": "int32",
    "description": "Number of direct children of the container. -1 if unknown"
} |
.definitions.ItemMetaData.properties.isFavourite = {
    "type": "boolean",
    "description": "True if favourited, false if not. The presence of this attribute indicates that the item can be marked as a favourite."
} |
.definitions.ItemMetaData.properties.album_id = {
    "type": "string",
    "description": "Media id of the album from which this item comes."
} |
.definitions.ItemMetaData.properties.artist_id = {
    "type": "string",
    "description": "Media id of the artist that created this item."
} |
del(.definitions.ItemMetaData.discriminator)' "${SPEC_PATH}"

# Keep the refined spec small without hand-authoring generated schemas here.
# This keeps the session helpers, shared request params, and the V2 surfaces
# the wrapper uses. A few nearby V2 models are cheaper than a brittle script.
yq -i '.definitions = (.definitions | with_entries(select(
    .key == "FilterSpec" or
    .key == "SessionData" or
    .key == "SessionResponse" or
    (.key | test("^Param(Tag|Session|Room|Update|Filter)$")) or
    (.key | test("^V2(TopologyStatus|ProductStatus|Transport|Seek|Metadata|Volume|Playlist|ServicesStatus)")) or
    (.key | test("^MediaBrowse(Response|Data)$")) or
    .key == "ItemMetaData"
)))' "${SPEC_PATH}"

# The upstream allOf request for services/status is omitted by the Swift
# generator. Name its actual wire shape so both client generators emit it.
yq -i '.definitions.V2ServicesStatusGetRequest = {
    "type": "object",
    "required": ["session", "room"],
    "properties": {
        "tag": {"type": "string"},
        "session": {"type": "string"},
        "room": {"type": "string"},
        "update": {"type": "integer"}
    }
} |
.paths."/V2/services/status".get.parameters[0].schema = {
    "$ref": "#/definitions/V2ServicesStatusGetRequest"
}' "${SPEC_PATH}"

# Revisions can exceed a signed 32-bit integer over the life of a library.
# Null alphabet offsets are normalized at the handwritten WebSocket boundary;
# neither pinned generator supports nullable array elements here.
yq -i 'with(.definitions[] | select(.properties.content_revision.type == "integer"); .properties.content_revision.format = "int64")' "${SPEC_PATH}"

mv "$SPEC_PATH" "$OUTPUT_SPEC_PATH"
