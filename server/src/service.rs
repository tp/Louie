use std::pin::Pin;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use linn_ci_gateway::{models, websocket};
use serde_json::{Value, json};
use tokio_stream::{Stream, StreamExt, wrappers::WatchStream};
use tonic::{Request, Response, Status};

use crate::{
    gateway::Gateway,
    pb::{self, linn_server::Linn},
};

#[derive(Clone)]
pub struct LinnService {
    gateway: Gateway,
    first_tracks: Arc<Mutex<HashMap<String, pb::MediaItem>>>,
}

impl LinnService {
    pub fn new(gateway: Gateway) -> Self {
        Self {
            gateway,
            first_tracks: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    async fn command(&self, path: &'static str, body: Value) -> Result<Response<()>, Status> {
        self.gateway.request(path, body).await?;
        Ok(Response::new(()))
    }

    fn room(&self) -> String {
        self.gateway.snapshot().room
    }

    async fn skip(&self, step: i32) -> Result<Response<()>, Status> {
        self.gateway.skip(step).await?;
        Ok(Response::new(()))
    }
}

#[tonic::async_trait]
impl Linn for LinnService {
    async fn get_state(&self, _: Request<()>) -> Result<Response<pb::StateSnapshot>, Status> {
        Ok(Response::new(self.gateway.snapshot()))
    }

    type WatchStateStream = Pin<Box<dyn Stream<Item = Result<pb::StateSnapshot, Status>> + Send>>;

    async fn watch_state(
        &self,
        _: Request<()>,
    ) -> Result<Response<Self::WatchStateStream>, Status> {
        let stream = WatchStream::new(self.gateway.subscribe()).map(Ok);
        Ok(Response::new(Box::pin(stream)))
    }

    async fn play(&self, _: Request<()>) -> Result<Response<()>, Status> {
        self.command("/V2/transport/play", json!({"room": self.room()}))
            .await
    }

    async fn pause(&self, _: Request<()>) -> Result<Response<()>, Status> {
        self.command("/V2/transport/pause", json!({"room": self.room()}))
            .await
    }

    async fn previous(&self, _: Request<()>) -> Result<Response<()>, Status> {
        self.skip(-1).await
    }

    async fn next(&self, _: Request<()>) -> Result<Response<()>, Status> {
        self.skip(1).await
    }

    async fn seek(&self, request: Request<pb::SeekRequest>) -> Result<Response<()>, Status> {
        let position = validated_seek_position(
            &self.gateway.snapshot(),
            request.into_inner().position_seconds,
        )?;
        self.command(
            "/V2/seek/set_position",
            json!({"room": self.room(), "position": position}),
        )
        .await
    }

    async fn select_playlist_item(
        &self,
        request: Request<pb::SelectPlaylistItemRequest>,
    ) -> Result<Response<()>, Status> {
        let index = request.into_inner().index;
        if index < 0 {
            return Err(Status::invalid_argument("index must be nonnegative"));
        }
        self.command(
            "/V2/playlist/select",
            json!({"room": self.room(), "index": index}),
        )
        .await
    }

    async fn set_volume(
        &self,
        request: Request<pb::SetVolumeRequest>,
    ) -> Result<Response<()>, Status> {
        let request = request.into_inner();
        if !(0..=100).contains(&request.volume) {
            return Err(Status::invalid_argument("volume must be 0..100"));
        }
        let volume = request.volume.min(self.gateway.maximum_volume());
        self.command(
            "/V2/volume/set_vol",
            json!({
                "room": self.room(), "volume": volume, "group": group(request.scope)?
            }),
        )
        .await
    }

    async fn set_muted(
        &self,
        request: Request<pb::SetMutedRequest>,
    ) -> Result<Response<()>, Status> {
        let request = request.into_inner();
        self.command(
            "/V2/volume/set_mute",
            json!({
                "room": self.room(), "mute": request.is_muted, "group": group(request.scope)?
            }),
        )
        .await
    }

    async fn list_media_services(
        &self,
        _: Request<()>,
    ) -> Result<Response<pb::MediaServicesResponse>, Status> {
        let response = self
            .gateway
            .request(
                "/V2/services/status",
                json!({
                    "room": self.room(), "update": 0
                }),
            )
            .await?;
        let status: models::V2ServicesStatusResponse =
            websocket::decode(&response).map_err(|error| {
                Status::internal(format!("invalid Linn services response: {error}"))
            })?;
        let services = status
            .data
            .and_then(|data| data.children)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|item| {
                Some(pb::MediaService {
                    id: item.id?,
                    name: item.name?,
                })
            })
            .collect();
        Ok(Response::new(pb::MediaServicesResponse { services }))
    }

    async fn browse_media(
        &self,
        request: Request<pb::BrowseMediaRequest>,
    ) -> Result<Response<pb::MediaPage>, Status> {
        let request = request.into_inner();
        validate_page(request.index, request.count)?;
        if request.media_id.is_empty() {
            return Err(Status::invalid_argument("media_id is required"));
        }
        let response = self
            .gateway
            .request(
                "/V2/media/browse",
                json!({
                    "media_id": request.media_id, "index": request.index,
                    "count": request.count, "browse_type": request.browse_type
                }),
            )
            .await?;
        let page = media_page(response)?;
        if page.index == 0
            && let Some(first) = page.children.first()
            && first.r#type == pb::MediaItemType::Track as i32
        {
            let mut cache = self
                .first_tracks
                .lock()
                .expect("first-track cache poisoned");
            if cache.len() >= 128 {
                cache.clear();
            }
            cache.insert(request.media_id, first.clone());
        }
        Ok(Response::new(page))
    }

    async fn search_media(
        &self,
        request: Request<pb::SearchMediaRequest>,
    ) -> Result<Response<pb::MediaPage>, Status> {
        let request = request.into_inner();
        validate_page(request.index, request.count)?;
        if request.service_id.is_empty() || request.query.is_empty() {
            return Err(Status::invalid_argument(
                "service_id and query are required",
            ));
        }
        let search_type = match pb::MediaSearchType::try_from(request.r#type).ok() {
            Some(pb::MediaSearchType::Albums) => "albums",
            Some(pb::MediaSearchType::Artists) => "artists",
            Some(pb::MediaSearchType::Tracks) => "tracks",
            Some(pb::MediaSearchType::Playlists) => "playlists",
            Some(pb::MediaSearchType::Composers) => "composers",
            Some(pb::MediaSearchType::Stations) => "stations",
            _ => return Err(Status::invalid_argument("search type is required")),
        };
        let response = self
            .gateway
            .request(
                "/V2/services/search",
                json!({
                    "media_id": request.service_id, "search_arg": request.query,
                    "search_type": search_type, "index": request.index, "count": request.count
                }),
            )
            .await?;
        Ok(Response::new(media_page(response)?))
    }

    async fn select_media(
        &self,
        request: Request<pb::SelectMediaRequest>,
    ) -> Result<Response<()>, Status> {
        let request = request.into_inner();
        if request.media_id.is_empty() {
            return Err(Status::invalid_argument("media_id is required"));
        }
        let queue = match pb::QueuePlacement::try_from(request.queue).ok() {
            Some(pb::QueuePlacement::Now) => "now",
            Some(pb::QueuePlacement::Next) => "next",
            Some(pb::QueuePlacement::Last) => "last",
            Some(pb::QueuePlacement::Replace) => "replace",
            _ => return Err(Status::invalid_argument("queue placement is required")),
        };
        let first_track = self
            .first_tracks
            .lock()
            .expect("first-track cache poisoned")
            .get(&request.media_id)
            .cloned();
        self.gateway
            .request_with_preview(
                "/V2/media/select",
                json!({
                    "room": self.room(), "media_id": request.media_id, "queue": queue
                }),
                request.preview,
                first_track,
            )
            .await?;
        Ok(Response::new(()))
    }

    async fn set_media_favourite(
        &self,
        request: Request<pb::SetMediaFavouriteRequest>,
    ) -> Result<Response<()>, Status> {
        let request = request.into_inner();
        if request.media_id.is_empty() {
            return Err(Status::invalid_argument("media_id is required"));
        }
        self.command(
            "/V2/media/favourite",
            json!({
                "media_id": request.media_id, "favourite": request.is_favourite
            }),
        )
        .await
    }

    async fn register_now_playing_token(
        &self,
        _: Request<pb::RegisterNowPlayingTokenRequest>,
    ) -> Result<Response<()>, Status> {
        Err(Status::unimplemented(
            "Now Playing push registration is not enabled yet",
        ))
    }

    async fn remove_now_playing_token(
        &self,
        _: Request<pb::RemoveNowPlayingTokenRequest>,
    ) -> Result<Response<()>, Status> {
        Err(Status::unimplemented(
            "Now Playing push registration is not enabled yet",
        ))
    }
}

fn group(scope: i32) -> Result<bool, Status> {
    match pb::VolumeScope::try_from(scope).ok() {
        Some(pb::VolumeScope::Group) => Ok(true),
        Some(pb::VolumeScope::Room) => Ok(false),
        _ => Err(Status::invalid_argument("volume scope is required")),
    }
}

fn validate_page(index: i32, count: i32) -> Result<(), Status> {
    if index < 0 || !(1..=200).contains(&count) {
        Err(Status::invalid_argument(
            "index must be nonnegative and count must be 1..200",
        ))
    } else {
        Ok(())
    }
}

fn validated_seek_position(snapshot: &pb::StateSnapshot, mut position: i32) -> Result<i32, Status> {
    if position < 0 {
        return Err(Status::invalid_argument("position must be nonnegative"));
    }
    if let Some(timeline) = snapshot
        .now_playing
        .as_ref()
        .and_then(|state| state.timeline.as_ref())
    {
        if timeline.is_seekable == Some(false) {
            return Err(Status::failed_precondition(
                "current source is not seekable",
            ));
        }
        if let Some(lower) = timeline.seek_lower_bound_seconds {
            position = position.max(lower);
        }
        if let Some(upper) = timeline.seek_upper_bound_seconds {
            position = position.min(upper);
        }
    }
    Ok(position)
}

fn media_page(response: Value) -> Result<pb::MediaPage, Status> {
    let page = websocket::decode_media_page(response)
        .map_err(|error| Status::internal(format!("invalid Linn media response: {error}")))?;
    let Some(data) = page.data else {
        return Ok(pb::MediaPage::default());
    };
    let children: Vec<_> = data
        .children
        .unwrap_or_default()
        .iter()
        .map(media_item)
        .collect();
    Ok(pb::MediaPage {
        id: data.id,
        content_revision: data.content_revision,
        index: data.index.unwrap_or(0),
        count: data.count.unwrap_or(children.len() as i32),
        total: data.total,
        children,
    })
}

fn media_item(item: &models::ItemMetaData) -> pb::MediaItem {
    let class = item.class.to_ascii_lowercase();
    let contained = item.contained_classes.clone().unwrap_or_default();
    let child_count = item.count;
    let is_container = class.contains("container")
        || class.contains("album")
        || class.contains("playlist")
        || class.starts_with("md.qobuz")
        || child_count.is_some()
        || !contained.is_empty();
    let item_type = if class.contains("track") || class.contains("song") {
        pb::MediaItemType::Track
    } else if class.contains("album") {
        pb::MediaItemType::Album
    } else if class.contains("artist") {
        pb::MediaItemType::Artist
    } else if class.contains("playlist") {
        pb::MediaItemType::Playlist
    } else if class.contains("station") || class.contains("radio") {
        pb::MediaItemType::Station
    } else if is_container {
        pb::MediaItemType::Container
    } else {
        pb::MediaItemType::Other
    };
    let disabled = item.disabled_actions.as_deref().unwrap_or_default();
    let is_favourite = item.is_favourite;
    pb::MediaItem {
        id: item.id.clone(),
        r#type: item_type as i32,
        name: item.name.clone(),
        title: item.title.clone(),
        album: item.album.clone(),
        artists: item.artist.clone().unwrap_or_default(),
        artwork_url: item.art_uri.clone(),
        duration_seconds: item.duration,
        child_count,
        is_favourite,
        is_container,
        can_favourite: is_favourite.is_some()
            && !disabled.iter().any(|action| action == "favourite"),
        provider: if class.contains("qobuz") {
            pb::MediaProvider::Qobuz as i32
        } else {
            pb::MediaProvider::Other as i32
        },
        linn_class: Some(item.class.clone()),
        contained_classes: contained,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn seek_forwards_clamped_seconds_and_rejects_radio() {
        let mut snapshot = pb::StateSnapshot {
            now_playing: Some(pb::NowPlayingState {
                timeline: Some(pb::Timeline {
                    is_seekable: Some(true),
                    seek_lower_bound_seconds: Some(0),
                    seek_upper_bound_seconds: Some(215),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert_eq!(validated_seek_position(&snapshot, 500).unwrap(), 215);
        assert_eq!(validated_seek_position(&snapshot, 42).unwrap(), 42);
        snapshot
            .now_playing
            .as_mut()
            .unwrap()
            .timeline
            .as_mut()
            .unwrap()
            .is_seekable = Some(false);
        assert_eq!(
            validated_seek_position(&snapshot, 42).unwrap_err().code(),
            tonic::Code::FailedPrecondition
        );
    }

    #[test]
    fn browse_maps_favourite_and_string_artist_from_gateway_payload() {
        let page = media_page(json!({
            "data": {
                "id": "qobuz", "index": 0, "count": 1, "total": 1,
                "children": [{
                    "id": "album:1", "class": "md.qobuz.album", "name": "Album",
                    "artist": "Nala Sinephro", "isFavourite": true,
                    "art_uri": "https://example.com/art"
                }]
            }
        }))
        .unwrap();
        let album = &page.children[0];
        assert_eq!(album.artists, ["Nala Sinephro"]);
        assert_eq!(album.is_favourite, Some(true));
        assert!(album.can_favourite);
        assert_eq!(album.r#type, pb::MediaItemType::Album as i32);
        assert_eq!(album.linn_class.as_deref(), Some("md.qobuz.album"));

        let folder = media_page(json!({
            "data": {"children": [{
                "id": "folder:1", "class": "md.container.qobuz.album",
                "contained_classes": ["md.album.qobuz"]
            }]}
        }))
        .unwrap();
        assert_eq!(
            folder.children[0].linn_class.as_deref(),
            Some("md.container.qobuz.album")
        );
        assert_eq!(folder.children[0].contained_classes, ["md.album.qobuz"]);
    }
}
