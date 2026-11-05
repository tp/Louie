use std::pin::Pin;

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
}

impl LinnService {
    pub fn new(gateway: Gateway) -> Self {
        Self { gateway }
    }

    async fn command(&self, path: &'static str, body: Value) -> Result<Response<()>, Status> {
        self.gateway.request(path, body).await?;
        Ok(Response::new(()))
    }

    fn room(&self) -> String {
        self.gateway.snapshot().room
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
        self.command(
            "/V2/transport/skip_track",
            json!({"room": self.room(), "skip_track": -1}),
        )
        .await
    }

    async fn next(&self, _: Request<()>) -> Result<Response<()>, Status> {
        self.command(
            "/V2/transport/skip_track",
            json!({"room": self.room(), "skip_track": 1}),
        )
        .await
    }

    async fn seek(&self, request: Request<pb::SeekRequest>) -> Result<Response<()>, Status> {
        let position = request.into_inner().position_seconds;
        if position < 0 {
            return Err(Status::invalid_argument("position must be nonnegative"));
        }
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
        let services = response
            .pointer("/data/children")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        Some(pb::MediaService {
                            id: string(item, "id")?.to_owned(),
                            name: string(item, "name")?.to_owned(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
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
        Ok(Response::new(media_page(&response)))
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
        Ok(Response::new(media_page(&response)))
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
        self.gateway
            .request_with_preview(
                "/V2/media/select",
                json!({
                    "room": self.room(), "media_id": request.media_id, "queue": queue
                }),
                request.preview,
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

fn media_page(response: &Value) -> pb::MediaPage {
    let data = response.get("data").unwrap_or(&Value::Null);
    let children = data
        .get("children")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(media_item).collect())
        .unwrap_or_default();
    pb::MediaPage {
        id: string(data, "id").map(str::to_owned),
        content_revision: integer(data, "content_revision"),
        index: integer(data, "index").unwrap_or(0) as i32,
        count: integer(data, "count").unwrap_or_else(|| {
            data.get("children")
                .and_then(Value::as_array)
                .map_or(0, |items| items.len() as i64)
        }) as i32,
        total: integer(data, "total").map(|n| n as i32),
        children,
    }
}

fn media_item(item: &Value) -> pb::MediaItem {
    let class = string(item, "class")
        .unwrap_or_default()
        .to_ascii_lowercase();
    let contained = strings(item, "contained_classes");
    let child_count = integer(item, "count").map(|n| n as i32);
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
    let disabled = strings(item, "disabledActions");
    let is_favourite = item.get("is_favourite").and_then(Value::as_bool);
    pb::MediaItem {
        id: string(item, "id").unwrap_or_default().to_owned(),
        r#type: item_type as i32,
        name: string(item, "name").map(str::to_owned),
        title: string(item, "title").map(str::to_owned),
        album: string(item, "album").map(str::to_owned),
        artists: strings(item, "artist"),
        artwork_url: string(item, "art_uri").map(str::to_owned),
        duration_seconds: integer(item, "duration").map(|n| n as i32),
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
    }
}

fn string<'a>(item: &'a Value, name: &str) -> Option<&'a str> {
    item.get(name).and_then(Value::as_str)
}
fn integer(item: &Value, name: &str) -> Option<i64> {
    item.get(name).and_then(Value::as_i64)
}
fn strings(item: &Value, name: &str) -> Vec<String> {
    item.get(name)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}
