use std::{
    collections::{HashMap, HashSet, VecDeque},
    time::{Duration, SystemTime},
};

use futures_util::{SinkExt, StreamExt};
use linn_ci_gateway::{models, websocket};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{info, warn};

use crate::optimism::Optimism;
use crate::pb::{
    ConnectionStatus, CurrentItem, NowPlayingState, PendingState, Playlist, PlaylistItem,
    StateSnapshot, Track, TransportState,
};

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct GatewayRequest {
    path: &'static str,
    body: Value,
    preview: Option<crate::pb::MediaItem>,
    first_track: Option<crate::pb::MediaItem>,
    reply: oneshot::Sender<Result<Value, tonic::Status>>,
}

struct Pending {
    reply: oneshot::Sender<Result<Value, tonic::Status>>,
    deadline: tokio::time::Instant,
    coalesce_key: Option<CoalesceKey>,
    search: bool,
}

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
struct CoalesceKey {
    path: &'static str,
    group: bool,
}

struct TaggedRequest {
    tag: String,
    request: GatewayRequest,
}

#[derive(Clone)]
pub struct Gateway {
    requests: mpsc::Sender<GatewayRequest>,
    state: watch::Receiver<StateSnapshot>,
    maximum_volume: i32,
}

impl Gateway {
    pub fn start(url: String, room: String, maximum_volume: i32) -> Self {
        let (requests, rx) = mpsc::channel(64);
        let initial = StateSnapshot {
            room: room.clone(),
            published_at: Some(now()),
            connection_status: ConnectionStatus::Connecting as i32,
            connection_error: None,
            now_playing: None,
            now_playing_session_id: format!("linn:{room}"),
            pending: Some(PendingState::default()),
        };
        let (state_tx, state) = watch::channel(initial);
        tokio::spawn(run_gateway(url, room, maximum_volume, rx, state_tx));
        Self {
            requests,
            state,
            maximum_volume,
        }
    }

    pub fn maximum_volume(&self) -> i32 {
        self.maximum_volume
    }

    pub fn snapshot(&self) -> StateSnapshot {
        self.state.borrow().clone()
    }

    pub fn subscribe(&self) -> watch::Receiver<StateSnapshot> {
        self.state.clone()
    }

    pub async fn request(&self, path: &'static str, body: Value) -> Result<Value, tonic::Status> {
        self.request_with_preview(path, body, None, None).await
    }

    pub async fn skip(&self, step: i32) -> Result<(), tonic::Status> {
        self.request("/louie/skip", json!({"step": step}))
            .await
            .map(|_| ())
    }

    pub async fn request_with_preview(
        &self,
        path: &'static str,
        body: Value,
        preview: Option<crate::pb::MediaItem>,
        first_track: Option<crate::pb::MediaItem>,
    ) -> Result<Value, tonic::Status> {
        if self.state.borrow().connection_status != ConnectionStatus::Connected as i32 {
            return Err(tonic::Status::unavailable("Linn gateway is disconnected"));
        }
        let (reply, result) = oneshot::channel();
        self.requests
            .send(GatewayRequest {
                path,
                body,
                preview,
                first_track,
                reply,
            })
            .await
            .map_err(|_| tonic::Status::unavailable("Linn gateway worker stopped"))?;
        match tokio::time::timeout(Duration::from_secs(5), result).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(tonic::Status::unavailable(
                "Linn gateway connection dropped",
            )),
            Err(_) => Err(tonic::Status::deadline_exceeded(
                "Linn gateway did not acknowledge the request",
            )),
        }
    }
}

async fn run_gateway(
    url: String,
    requested_room: String,
    maximum_volume: i32,
    mut rx: mpsc::Receiver<GatewayRequest>,
    state: watch::Sender<StateSnapshot>,
) {
    let mut delay = Duration::from_millis(500);
    let mut observed = state.borrow().clone();
    loop {
        observed.connection_status = ConnectionStatus::Connecting as i32;
        observed.connection_error = None;
        state.send_replace(observed.clone());
        let result = run_connection(
            &url,
            &requested_room,
            maximum_volume,
            &mut rx,
            &state,
            &mut observed,
        )
        .await;
        if state.borrow().connection_status == ConnectionStatus::Connected as i32 {
            delay = Duration::from_millis(500);
        }
        let message = result.err().unwrap_or_else(|| "connection closed".into());
        warn!("Linn gateway disconnected: {message}");
        observed.connection_status = ConnectionStatus::Disconnected as i32;
        observed.connection_error = Some(message);
        observed.pending = Some(PendingState::default());
        observed.published_at = Some(now());
        state.send_replace(observed.clone());
        while let Ok(request) = rx.try_recv() {
            let _ = request.reply.send(Err(tonic::Status::unavailable(
                "Linn gateway is disconnected",
            )));
        }
        tokio::time::sleep(delay).await;
        delay = (delay * 2).min(Duration::from_secs(10));
    }
}

async fn run_connection(
    url: &str,
    requested_room: &str,
    maximum_volume: i32,
    rx: &mut mpsc::Receiver<GatewayRequest>,
    state: &watch::Sender<StateSnapshot>,
    observed: &mut StateSnapshot,
) -> Result<(), String> {
    let (mut socket, _) = tokio::time::timeout(Duration::from_secs(10), connect_async(url))
        .await
        .map_err(|_| "timed out connecting to Linn gateway".to_string())?
        .map_err(|e| e.to_string())?;
    socket
        .send(Message::Text(
            json!({
                "requestPath": "/session/create",
                "userAgent": "Louie-Pi/1.0",
                "timeout": 10000
            })
            .to_string()
            .into(),
        ))
        .await
        .map_err(|e| e.to_string())?;
    let session_reply = await_path(&mut socket, "/session/create").await?;
    let session = websocket::decode::<models::SessionResponse>(&session_reply)
        .map_err(|e| format!("invalid Linn session: {e}"))?
        .session
        .ok_or("missing gateway session")?;

    socket
        .send(Message::Text(
            json!({
                "requestPath": "/V2/topology/status", "tag": "topology-status", "session": session
            })
            .to_string()
            .into(),
        ))
        .await
        .map_err(|e| e.to_string())?;
    let topology = await_path(&mut socket, "/V2/topology/status").await?;
    let topology = websocket::decode::<models::V2TopologyStatusResponse>(&topology)
        .map_err(|e| format!("invalid Linn topology: {e}"))?;
    let rooms = topology
        .data
        .and_then(|data| data.rooms)
        .ok_or("gateway topology contains no rooms")?;
    let room = rooms
        .iter()
        .find_map(|entry| {
            let name = entry.name.as_deref();
            let udn = entry.udn.as_deref();
            ((name == Some(requested_room)) || (udn == Some(requested_room)))
                .then(|| name.or(udn).unwrap_or(requested_room).to_owned())
        })
        .ok_or_else(|| format!("configured Linn room '{requested_room}' was not found"))?;

    for (tag, path, mut body) in subscriptions(&session, &room) {
        body["tag"] = json!(tag);
        body["requestPath"] = json!(path);
        socket
            .send(Message::Text(body.to_string().into()))
            .await
            .map_err(|e| e.to_string())?;
    }
    info!("Connected to Linn room {room}");
    publish_connected(state, observed, &room, maximum_volume);
    let mut optimism = Optimism::default();
    let mut pending: HashMap<String, Pending> = HashMap::new();
    let mut in_flight: HashSet<CoalesceKey> = HashSet::new();
    let mut deferred: HashMap<CoalesceKey, TaggedRequest> = HashMap::new();
    let mut search_in_flight = false;
    let mut search_queue: VecDeque<TaggedRequest> = VecDeque::new();
    let mut next_tag = 0_u64;
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let mut last_frame = tokio::time::Instant::now();
    loop {
        tokio::select! {
            message = socket.next() => {
                let message = message.ok_or("gateway websocket closed")?
                    .map_err(|e| e.to_string())?;
                last_frame = tokio::time::Instant::now();
                let text = match message {
                    Message::Text(text) => text.to_string(),
                    Message::Binary(bytes) => String::from_utf8(bytes.to_vec()).map_err(|e| e.to_string())?,
                    Message::Ping(payload) => {
                        socket.send(Message::Pong(payload)).await.map_err(|e| e.to_string())?;
                        continue;
                    }
                    Message::Close(_) => return Err("gateway websocket closed".into()),
                    _ => continue,
                };
                let envelope: Value = match serde_json::from_str(&text) {
                    Ok(value) => value,
                    Err(error) => { warn!("Invalid gateway JSON: {error}"); continue; }
                };
                let header: websocket::Envelope = match websocket::decode(&envelope) {
                    Ok(header) => header,
                    Err(error) => { warn!("Invalid Linn WebSocket envelope: {error}"); continue; }
                };
                if let Some(tag) = header.tag.as_deref()
                    && let Some(waiter) = pending.remove(tag) {
                    let result = if let Some(code) = header.error_code {
                        Err(tonic::Status::failed_precondition(format!("Linn error {code}: {}", header.message.as_deref().unwrap_or("request failed"))))
                    } else { Ok(envelope.clone()) };
                    if result.is_err() && optimism.fail(tag) {
                        state.send_replace(optimism.snapshot(observed));
                    }
                    let _ = waiter.reply.send(result);
                    if let Some(key) = waiter.coalesce_key {
                        in_flight.remove(&key);
                        if let Some(next) = deferred.remove(&key) {
                            send_request(&mut socket, next, &session, &mut pending, &mut in_flight, Some(key), false).await?;
                        }
                    }
                    if waiter.search {
                        search_in_flight = false;
                        if let Some(next) = search_queue.pop_front() {
                            send_request(&mut socket, next, &session, &mut pending, &mut in_flight, None, true).await?;
                            search_in_flight = true;
                        }
                    }
                    continue;
                }
                let changed = apply_update(observed, &header.request_path, &envelope);
                let settled = optimism.reconcile(observed);
                if changed || settled {
                    state.send_replace(optimism.snapshot(observed));
                }
            }
            _ = ping.tick() => {
                if last_frame.elapsed() > Duration::from_secs(30) {
                    return Err("Linn gateway stopped responding to WebSocket pings".into());
                }
                socket.send(Message::Ping(Vec::new().into())).await.map_err(|e| e.to_string())?;
            }
            Some(mut request) = rx.recv() => {
                if request.path == "/louie/skip" {
                    let step = request.body["step"].as_i64().unwrap_or(0) as i32;
                    let effective = optimism.snapshot(observed);
                    let playlist = effective.now_playing.and_then(|state| state.playlist);
                    if let Some(playlist) = playlist
                        && let Some(current) = playlist.current_index {
                        let target = current.saturating_add(step);
                        if target < 0 || playlist.total.is_some_and(|total| target >= total) {
                            let _ = request.reply.send(Ok(Value::Null));
                            continue;
                        }
                        request.path = "/V2/playlist/select";
                        request.body = json!({"room": observed.room, "index": target});
                    } else {
                        request.path = "/V2/transport/skip_track";
                        request.body = json!({"room": observed.room, "skip_track": step});
                    }
                }
                next_tag += 1;
                let tag = format!("pi-{next_tag}");
                let key = coalesce_key(&request);
                if request.path == "/V2/services/search" && search_in_flight {
                    if search_queue.len() >= 64 {
                        let _ = request.reply.send(Err(tonic::Status::resource_exhausted("too many queued Linn searches")));
                    } else {
                        search_queue.push_back(TaggedRequest { tag, request });
                    }
                    continue;
                }
                if let Some(key) = key
                    && in_flight.contains(&key) {
                    if let Some(old) = deferred.remove(&key) {
                        optimism.fail(&old.tag);
                        let _ = old.request.reply.send(Err(tonic::Status::cancelled("superseded by a newer value")));
                    }
                    let effective = optimism.snapshot(observed);
                    if optimism.apply(&tag, request.path, &request.body, request.preview.clone(), request.first_track.clone(), &effective) {
                        state.send_replace(optimism.snapshot(observed));
                    }
                    deferred.insert(key, TaggedRequest { tag, request });
                    continue;
                }
                let effective = optimism.snapshot(observed);
                if optimism.apply(&tag, request.path, &request.body, request.preview.clone(), request.first_track.clone(), &effective) {
                    state.send_replace(optimism.snapshot(observed));
                }
                let search = request.path == "/V2/services/search";
                send_request(&mut socket, TaggedRequest { tag, request }, &session, &mut pending, &mut in_flight, key, search).await?;
                search_in_flight |= search;
            }
            _ = tick.tick() => {
                let now = tokio::time::Instant::now();
                let expired: Vec<_> = pending.iter()
                    .filter(|(_, waiter)| waiter.deadline <= now)
                    .map(|(tag, _)| tag.clone()).collect();
                for tag in expired {
                    if let Some(waiter) = pending.remove(&tag) {
                        if optimism.fail(&tag) {
                            state.send_replace(optimism.snapshot(observed));
                        }
                        let _ = waiter.reply.send(Err(tonic::Status::deadline_exceeded("Linn request timed out")));
                        if let Some(key) = waiter.coalesce_key {
                            in_flight.remove(&key);
                            if let Some(next) = deferred.remove(&key) {
                                send_request(&mut socket, next, &session, &mut pending, &mut in_flight, Some(key), false).await?;
                            }
                        }
                        if waiter.search {
                            search_in_flight = false;
                            if let Some(next) = search_queue.pop_front() {
                                send_request(&mut socket, next, &session, &mut pending, &mut in_flight, None, true).await?;
                                search_in_flight = true;
                            }
                        }
                    }
                }
                if optimism.expire() {
                    state.send_replace(optimism.snapshot(observed));
                }
            }
        }
    }
}

fn publish_connected(
    state: &watch::Sender<StateSnapshot>,
    observed: &mut StateSnapshot,
    room: &str,
    maximum_volume: i32,
) {
    if observed.room != room || observed.now_playing.is_none() {
        observed.now_playing = Some(NowPlayingState::default());
    }
    observed.room = room.to_owned();
    observed.connection_status = ConnectionStatus::Connected as i32;
    observed.connection_error = None;
    observed
        .now_playing
        .as_mut()
        .expect("now-playing state initialized")
        .room_volume
        .get_or_insert_default()
        .maximum_volume = maximum_volume;
    observed.pending = Some(PendingState::default());
    observed.published_at = Some(now());
    state.send_replace(observed.clone());
}

fn coalesce_key(request: &GatewayRequest) -> Option<CoalesceKey> {
    matches!(
        request.path,
        "/V2/volume/set_vol" | "/V2/volume/set_mute" | "/V2/playlist/select"
    )
    .then(|| CoalesceKey {
        path: request.path,
        group: request.body.get("group").and_then(Value::as_bool) == Some(true),
    })
}

async fn send_request(
    socket: &mut Socket,
    tagged: TaggedRequest,
    session: &str,
    pending: &mut HashMap<String, Pending>,
    in_flight: &mut HashSet<CoalesceKey>,
    key: Option<CoalesceKey>,
    search: bool,
) -> Result<(), String> {
    let TaggedRequest { tag, request } = tagged;
    let mut body = request.body;
    body["requestPath"] = json!(request.path);
    body["tag"] = json!(tag);
    body["session"] = json!(session);
    let body = match websocket::encode_request(request.path, body) {
        Ok(body) => body,
        Err(error) => {
            let _ = request
                .reply
                .send(Err(tonic::Status::invalid_argument(format!(
                    "invalid {} request: {error}",
                    request.path
                ))));
            return Ok(());
        }
    };
    if let Some(key) = key {
        in_flight.insert(key);
    }
    pending.insert(
        tag.clone(),
        Pending {
            reply: request.reply,
            deadline: tokio::time::Instant::now() + Duration::from_secs(5),
            coalesce_key: key,
            search,
        },
    );
    if let Err(error) = socket.send(Message::Text(body.to_string().into())).await {
        if let Some(waiter) = pending.remove(&tag) {
            let _ = waiter.reply.send(Err(tonic::Status::unavailable(format!(
                "failed to send {}: {error}",
                request.path
            ))));
        }
        if let Some(key) = key {
            in_flight.remove(&key);
        }
        return Err(error.to_string());
    }
    Ok(())
}

async fn await_path(socket: &mut Socket, path: &str) -> Result<Value, String> {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let message = socket
                .next()
                .await
                .ok_or("gateway websocket closed")?
                .map_err(|e| e.to_string())?;
            if let Message::Text(text) = message {
                let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
                if str_at(&value, "requestPath") == Some(path) {
                    return Ok(value);
                }
            }
        }
    })
    .await
    .map_err(|_| format!("timed out waiting for {path}"))?
}

fn subscriptions(session: &str, room: &str) -> Vec<(&'static str, &'static str, Value)> {
    let paths = [
        ("subscription-play-state", "/V2/transport/status"),
        ("subscription-position", "/V2/seek/status"),
        ("subscription-room-state", "/V2/volume/status"),
        ("subscription-metadata", "/V2/metadata/status"),
    ];
    let mut result: Vec<_> = paths
        .into_iter()
        .map(|(tag, path)| {
            (
                tag,
                path,
                json!({"session": session, "room": room, "update": 1}),
            )
        })
        .collect();
    result.push((
        "subscription-playlist",
        "/V2/playlist/subscribe",
        json!({"session": session, "room": room, "index": 0, "count": 100, "concise": false}),
    ));
    result
}

fn apply_update(snapshot: &mut StateSnapshot, path: &str, value: &Value) -> bool {
    let room = snapshot.room.clone();
    let Some(now_playing) = snapshot.now_playing.as_mut() else {
        return false;
    };
    let previous = now_playing.clone();
    let changed = match path {
        "/V2/transport/status" => {
            let Ok(response) = websocket::decode::<models::V2TransportStatusResponse>(value) else {
                warn!("Invalid Linn transport status");
                return false;
            };
            let transport = response
                .data
                .and_then(|data| data.transport_state)
                .map(|s| match s.to_ascii_lowercase().as_str() {
                    "stop" | "stopped" => TransportState::Stopped,
                    "play" | "playing" => TransportState::Playing,
                    "pause" | "paused" => TransportState::Paused,
                    "buffering" => TransportState::Buffering,
                    "waiting" => TransportState::Waiting,
                    _ => TransportState::Unknown,
                } as i32);
            if let Some(transport) = transport {
                if now_playing.transport_state != Some(transport) {
                    now_playing.transport_state = Some(transport);
                    if let Some(timeline) = now_playing.timeline.as_mut() {
                        timeline.position_sampled_at = Some(now());
                    }
                }
                true
            } else {
                false
            }
        }
        "/V2/seek/status" => {
            let Ok(response) = websocket::decode::<models::V2SeekStatusResponse>(value) else {
                warn!("Invalid Linn seek status");
                return false;
            };
            let Some(data) = response.data else {
                return false;
            };
            let timeline = now_playing.timeline.get_or_insert_default();
            if let Some(position) = data.elapsed {
                timeline.position_seconds = Some(position);
                timeline.position_sampled_at = Some(now());
            }
            if let Some(duration) = data.duration {
                timeline.duration_seconds = Some(duration);
            }
            if let Some(seekable) = data.seekable {
                timeline.is_seekable = Some(seekable);
                timeline.seek_lower_bound_seconds = seekable.then_some(0);
                timeline.seek_upper_bound_seconds = if seekable {
                    timeline.duration_seconds
                } else {
                    None
                };
            }
            if timeline.is_seekable == Some(true) {
                timeline.seek_upper_bound_seconds = timeline.duration_seconds;
            }
            true
        }
        "/V2/volume/status" => {
            let Ok(response) = websocket::decode::<models::V2VolumeStatusResponse>(value) else {
                warn!("Invalid Linn volume status");
                return false;
            };
            let Some(data) = response.data else {
                return false;
            };
            let volume = now_playing.room_volume.get_or_insert_default();
            if let Some(level) = data.volume {
                volume.volume = Some(level.min(volume.maximum_volume));
            }
            if let Some(muted) = data.mute {
                volume.is_muted = Some(muted);
            }
            true
        }
        "/V2/metadata/status" => {
            let Ok(response) = websocket::decode::<models::V2MetadataStatusResponse>(value) else {
                warn!("Invalid Linn metadata status");
                return false;
            };
            let Some(metadata) = response.metadata else {
                return false;
            };
            let title = metadata.line_1.as_deref();
            let artist = metadata.line_2.as_deref();
            let album = metadata.line_3.as_deref();
            let art = metadata.art_uri.as_deref();
            now_playing.current_item = Some(CurrentItem {
                id: art.or(title).unwrap_or(&room).to_owned(),
                display_name: title.map(str::to_owned),
                artwork_url: art.map(str::to_owned),
                track: Some(Track {
                    title: title.map(str::to_owned),
                    album: album.map(str::to_owned),
                    artist: artist.map(str::to_owned),
                }),
            });
            true
        }
        "/V2/playlist/subscribe" => {
            let Ok(response) = websocket::decode_playlist(value.clone()) else {
                warn!("Invalid Linn playlist status");
                return false;
            };
            let Some(data) = response.data else {
                return false;
            };
            let mut items = Vec::new();
            if let Some(children) = data.children {
                for (key, item) in children {
                    let Ok(index) = key.parse::<i32>() else {
                        continue;
                    };
                    let is_current = item.playing == Some(true) || item.selected == Some(true);
                    items.push(PlaylistItem {
                        index,
                        display_name: item.name,
                        album: item.album,
                        artist: item.artist.map(|artists| artists.join(", ")),
                        duration_seconds: item.duration,
                        artwork_url: item.art_uri,
                        is_current,
                    });
                }
            }
            items.sort_by_key(|item| item.index);
            now_playing.playlist = Some(Playlist {
                current_index: items
                    .iter()
                    .find(|item| item.is_current)
                    .map(|item| item.index),
                items,
                total: data.total,
                content_revision: data.content_revision.map(i64::from),
            });
            true
        }
        _ => false,
    };
    let meaningful = changed
        && if path == "/V2/seek/status" {
            let before = previous.timeline.as_ref();
            let after = now_playing.timeline.as_ref();
            match (before, after) {
                (Some(before), Some(after)) => {
                    before.duration_seconds != after.duration_seconds
                        || before.is_seekable != after.is_seekable
                        || before.seek_upper_bound_seconds != after.seek_upper_bound_seconds
                        || before
                            .position_seconds
                            .zip(after.position_seconds)
                            .is_none_or(|(old, new)| !(0..=2).contains(&(new - old)))
                }
                _ => before != after,
            }
        } else {
            *now_playing != previous
        };
    if meaningful {
        snapshot.published_at = Some(now());
    }
    meaningful
}

fn now() -> prost_types::Timestamp {
    SystemTime::now().into()
}

fn str_at<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(Value::as_str)
}

#[cfg(test)]
fn int_at(value: &Value, field: &str) -> Option<i32> {
    value
        .get(field)
        .and_then(Value::as_i64)
        .and_then(|n| i32::try_from(n).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;

    #[test]
    fn reconnect_keeps_same_room_snapshot_and_resets_changed_room() {
        let (state, _) = watch::channel(StateSnapshot {
            room: "Linn".into(),
            connection_status: ConnectionStatus::Disconnected as i32,
            now_playing: Some(NowPlayingState {
                current_item: Some(CurrentItem {
                    id: "song-1".into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        });

        let mut observed = state.borrow().clone();
        publish_connected(&state, &mut observed, "Linn", 70);
        assert_eq!(
            state
                .borrow()
                .now_playing
                .as_ref()
                .unwrap()
                .current_item
                .as_ref()
                .unwrap()
                .id,
            "song-1"
        );
        publish_connected(&state, &mut observed, "Other Room", 70);
        assert!(
            state
                .borrow()
                .now_playing
                .as_ref()
                .unwrap()
                .current_item
                .is_none()
        );
    }

    async fn wait_for(
        state: &mut watch::Receiver<StateSnapshot>,
        predicate: impl Fn(&StateSnapshot) -> bool,
    ) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while !predicate(&state.borrow()) {
                state.changed().await.expect("gateway state stream ended");
            }
        })
        .await
        .expect("gateway state did not reach expected value");
    }

    #[tokio::test]
    async fn sends_only_latest_queued_volume_after_first_ack() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (volume_tx, mut volumes) = mpsc::channel(3);
        let (release_tx, release_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = accept_async(stream).await.unwrap();
            let mut release_rx = Some(release_rx);
            while let Some(Ok(Message::Text(text))) = socket.next().await {
                let request: Value = serde_json::from_str(&text).unwrap();
                let path = str_at(&request, "requestPath").unwrap();
                let reply = match path {
                    "/session/create" => Some(json!({"requestPath": path, "session": "test"})),
                    "/V2/topology/status" => Some(json!({
                        "requestPath": path, "data": {"rooms": [{"name": "Linn"}]}
                    })),
                    "/V2/volume/set_vol" => {
                        let volume = int_at(&request, "volume").unwrap();
                        volume_tx.send(volume).await.unwrap();
                        if volume == 10 {
                            release_rx.take().unwrap().await.unwrap();
                        }
                        Some(json!({"requestPath": path, "tag": request["tag"]}))
                    }
                    _ => None,
                };
                if let Some(reply) = reply {
                    socket
                        .send(Message::Text(reply.to_string().into()))
                        .await
                        .unwrap();
                }
            }
        });

        let gateway = Gateway::start(format!("ws://{address}"), "Linn".into(), 70);
        let mut state = gateway.subscribe();
        wait_for(&mut state, |s| {
            s.connection_status == ConnectionStatus::Connected as i32
        })
        .await;

        let first_gateway = gateway.clone();
        let first = tokio::spawn(async move {
            first_gateway
                .request(
                    "/V2/volume/set_vol",
                    json!({"room": "Linn", "volume": 10, "group": false}),
                )
                .await
        });
        assert_eq!(volumes.recv().await, Some(10));

        let second_gateway = gateway.clone();
        let second = tokio::spawn(async move {
            second_gateway
                .request(
                    "/V2/volume/set_vol",
                    json!({"room": "Linn", "volume": 20, "group": false}),
                )
                .await
        });
        wait_for(&mut state, |s| {
            s.now_playing
                .as_ref()
                .and_then(|p| p.room_volume.as_ref())
                .and_then(|v| v.volume)
                == Some(20)
        })
        .await;

        let third_gateway = gateway.clone();
        let third = tokio::spawn(async move {
            third_gateway
                .request(
                    "/V2/volume/set_vol",
                    json!({"room": "Linn", "volume": 30, "group": false}),
                )
                .await
        });
        assert_eq!(
            second.await.unwrap().unwrap_err().code(),
            tonic::Code::Cancelled
        );
        // A view disappearing after its final slider value must not discard it.
        third.abort();
        release_tx.send(()).unwrap();
        assert_eq!(volumes.recv().await, Some(30));
        first.await.unwrap().unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(100), volumes.recv())
                .await
                .is_err()
        );
        server.abort();
    }

    #[tokio::test]
    async fn serializes_searches_on_the_shared_gateway_socket() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (search_tx, mut searches) = mpsc::channel(2);
        let (release_tx, release_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = accept_async(stream).await.unwrap();
            let mut release_rx = Some(release_rx);
            while let Some(Ok(Message::Text(text))) = socket.next().await {
                let request: Value = serde_json::from_str(&text).unwrap();
                let path = str_at(&request, "requestPath").unwrap();
                let reply = match path {
                    "/session/create" => Some(json!({"requestPath": path, "session": "test"})),
                    "/V2/topology/status" => {
                        Some(json!({"requestPath": path, "data": {"rooms": [{"name": "Linn"}]}}))
                    }
                    "/V2/services/search" => {
                        let query = str_at(&request, "search_arg").unwrap().to_owned();
                        search_tx.send(query.clone()).await.unwrap();
                        if query == "first" {
                            release_rx.take().unwrap().await.unwrap();
                        }
                        Some(
                            json!({"requestPath": path, "tag": request["tag"], "data": {"children": []}}),
                        )
                    }
                    _ => None,
                };
                if let Some(reply) = reply {
                    socket
                        .send(Message::Text(reply.to_string().into()))
                        .await
                        .unwrap();
                }
            }
        });
        let gateway = Gateway::start(format!("ws://{address}"), "Linn".into(), 70);
        let mut state = gateway.subscribe();
        wait_for(&mut state, |snapshot| {
            snapshot.connection_status == ConnectionStatus::Connected as i32
        })
        .await;
        let search = |query: &'static str| json!({"media_id":"qobuz", "search_arg":query, "search_type":"tracks", "index":0, "count":10});
        let first_gateway = gateway.clone();
        let first = tokio::spawn(async move {
            first_gateway
                .request("/V2/services/search", search("first"))
                .await
        });
        assert_eq!(searches.recv().await.as_deref(), Some("first"));
        let second_gateway = gateway.clone();
        let second = tokio::spawn(async move {
            second_gateway
                .request("/V2/services/search", search("second"))
                .await
        });
        assert!(
            tokio::time::timeout(Duration::from_millis(100), searches.recv())
                .await
                .is_err()
        );
        release_tx.send(()).unwrap();
        assert_eq!(searches.recv().await.as_deref(), Some("second"));
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        server.abort();
    }
}
