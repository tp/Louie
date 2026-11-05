//! Typed payloads for the Linn CI Gateway WebSocket protocol.
//! `requestPath` and `tag` belong to the WebSocket envelope; the payloads
//! come from the locally normalized OpenAPI schema.

use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;

use crate::models;

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub request_path: String,
    pub tag: Option<String>,
    pub error_code: Option<i32>,
    pub message: Option<String>,
}

pub fn decode<T: DeserializeOwned>(value: &Value) -> Result<T, serde_json::Error> {
    serde_json::from_value(value.clone())
}

pub fn encode<T: Serialize>(value: &T) -> Result<Value, serde_json::Error> {
    serde_json::to_value(value)
}

/// Validate and serialize command bodies against generated request models.
/// Paths absent from the published schema keep their original body.
pub fn encode_request(path: &str, value: Value) -> Result<Value, serde_json::Error> {
    fn round_trip<T: DeserializeOwned + Serialize>(
        value: Value,
    ) -> Result<Value, serde_json::Error> {
        encode(&decode::<T>(&value)?)
    }
    let mut encoded = match path {
        "/V2/transport/play" => round_trip::<models::V2TransportPlayPostRequest>(value)?,
        "/V2/transport/skip_track" => round_trip::<models::V2TransportSkipTrackPostRequest>(value)?,
        "/V2/seek/set_position" => round_trip::<models::V2SeekSetPositionPostRequest>(value)?,
        "/V2/playlist/select" => round_trip::<models::V2PlaylistSelectPostRequest>(value)?,
        "/V2/volume/set_vol" => round_trip::<models::V2VolumeSetVolPostRequest>(value)?,
        "/V2/volume/set_mute" => round_trip::<models::V2VolumeSetMutePostRequest>(value)?,
        "/V2/services/search" => round_trip::<models::V2ServicesSearchGetRequest>(value)?,
        "/V2/media/browse" => round_trip::<models::V2MediaBrowseGetRequest>(value)?,
        "/V2/media/select" => round_trip::<models::V2MediaSelectPostRequest>(value)?,
        "/V2/media/favourite" => round_trip::<models::V2MediaFavouritePostRequest>(value)?,
        _ => value,
    };
    encoded["requestPath"] = Value::String(path.to_owned());
    Ok(encoded)
}

/// The live gateway uses either a string or a list for artists, although the
/// published schema says list. Normalize this known deviation before decoding.
pub fn decode_media_item(mut value: Value) -> Result<models::ItemMetaData, serde_json::Error> {
    normalize_artist(&mut value);
    decode(&value)
}

pub fn decode_playlist_item(
    mut value: Value,
) -> Result<models::V2PlaylistItemMetadata, serde_json::Error> {
    normalize_artist(&mut value);
    decode(&value)
}

pub fn decode_media_page(
    mut value: Value,
) -> Result<models::MediaBrowseResponse, serde_json::Error> {
    if let Some(children) = value
        .pointer_mut("/data/children")
        .and_then(Value::as_array_mut)
    {
        for item in children {
            normalize_artist(item);
        }
    }
    decode(&value)
}

pub fn decode_playlist(
    mut value: Value,
) -> Result<models::V2PlaylistSubscribeResponse, serde_json::Error> {
    if let Some(children) = value
        .pointer_mut("/data/children")
        .and_then(Value::as_object_mut)
    {
        for item in children.values_mut() {
            normalize_artist(item);
        }
    }
    decode(&value)
}

fn normalize_artist(value: &mut Value) {
    if let Some(artist) = value.get_mut("artist")
        && artist.is_string()
    {
        let single = artist.take();
        *artist = Value::Array(vec![single]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn album_accepts_string_artist_and_camel_case_favourite() {
        let item = decode_media_item(json!({
            "id": "album:1", "class": "md.qobuz.album", "name": "Album",
            "artist": "Nala Sinephro", "isFavourite": true,
            "disabledActions": ["queue"], "art_uri": "https://example.com/art"
        }))
        .unwrap();
        assert_eq!(item.artist, Some(vec!["Nala Sinephro".into()]));
        assert_eq!(item.is_favourite, Some(true));
        assert_eq!(item.disabled_actions, Some(vec!["queue".into()]));
    }
}
