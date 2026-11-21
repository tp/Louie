//! A single worker publishes the latest projection; no queue of stale playback pushes.
use crate::{
    apns::{self, Outcome, Provider},
    pb,
    push_registry::{Registration, Registry},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    env,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::watch;

#[derive(Clone)]
pub struct PushService {
    registry: Registry,
    environments: [bool; 2],
}

impl PushService {
    pub fn start(state: watch::Receiver<pb::StateSnapshot>) -> Result<Option<Self>, apns::Error> {
        let Some(provider) = Provider::from_env()? else {
            return Ok(None);
        };
        let environments = [provider.supports(1), provider.supports(2)];
        let path = match env::var_os("LOUIE_PUSH_REGISTRY") {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(
                env::var_os("HOME").ok_or("Set LOUIE_PUSH_REGISTRY when HOME is absent")?,
            )
            .join(".local/state/louie/nowplaying.json"),
        };
        let registry = Registry::open(path)?;
        tokio::spawn(run(state, registry.clone(), provider));
        tracing::info!("Now Playing APNs delivery enabled");
        Ok(Some(Self {
            registry,
            environments,
        }))
    }

    pub async fn register(
        &self,
        request: pb::RegisterNowPlayingTokenRequest,
    ) -> Result<(), tonic::Status> {
        let entry = Registration::from_request(request, unix_now())?;
        if !self.environments[(entry.environment - 1) as usize] {
            return Err(tonic::Status::failed_precondition(
                "APNs environment is not configured on the home server",
            ));
        }
        self.registry.register(entry).await
    }

    pub async fn remove(
        &self,
        request: pb::RemoveNowPlayingTokenRequest,
    ) -> Result<(), tonic::Status> {
        self.registry.remove(&request).await
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Default)]
struct Delivery {
    token: String,
    last: Option<Value>,
    next_attempt: u64,
    failures: u32,
}

async fn run(
    state: watch::Receiver<pb::StateSnapshot>,
    registry: Registry,
    mut provider: Provider,
) {
    let mut deliveries: HashMap<String, Delivery> = HashMap::new();
    let started = unix_now();
    let mut timer = tokio::time::interval(Duration::from_secs(1));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        timer.tick().await;
        let now = unix_now();
        let snapshot = state.borrow().clone();
        // A server restart begins with an empty connecting snapshot. Give it a
        // chance to reconnect before ending persisted remote sessions.
        if snapshot.connection_status != pb::ConnectionStatus::Connected as i32
            && now < started + 15
        {
            continue;
        }
        let entries = registry.entries().await;
        deliveries.retain(|key, _| entries.iter().any(|e| &e.key() == key));
        for entry in &entries {
            // Old installations eventually age out even if playback never changes.
            if now.saturating_sub(entry.registered_at) > 90 * 86400 {
                if registry.retire(entry).await.is_err() {
                    tracing::warn!("Could not expire APNs registration");
                }
                continue;
            }
            let delivery = deliveries.entry(entry.key()).or_default();
            if delivery.token != entry.token {
                *delivery = Delivery {
                    token: entry.token.clone(),
                    next_attempt: now + if entry.kind == 1 { 5 } else { 0 },
                    ..Default::default()
                };
            }
            let Some(payload) = plan(&snapshot, entry, &entries, delivery.last.as_ref(), now)
            else {
                // Once a session exists (or playback ends), a future playback
                // start must not inherit the previous push-to-start retry delay.
                if entry.kind == 1 {
                    delivery.next_attempt = now;
                }
                continue;
            };
            if now < delivery.next_attempt {
                continue;
            }
            let outcome = provider
                .send(entry.environment, &entry.token, &payload, now)
                .await;
            match outcome {
                Outcome::Accepted => {
                    delivery.failures = 0;
                    delivery.last = Some(payload.clone());
                    delivery.next_attempt = now + if entry.kind == 1 { 60 } else { 1 };
                    if payload["aps"]["event"] == "end" && registry.retire(entry).await.is_err() {
                        tracing::warn!("Could not retire ended APNs session");
                    }
                }
                Outcome::InvalidToken => {
                    if registry.retire(entry).await.is_err() {
                        tracing::warn!("Could not retire invalid APNs token");
                    }
                    delivery.next_attempt = now + 60;
                }
                Outcome::Retry => {
                    delivery.failures = delivery.failures.saturating_add(1);
                    delivery.next_attempt = now + (1u64 << delivery.failures.min(6)).min(60);
                }
                Outcome::Rejected => {
                    delivery.next_attempt = now + 300;
                }
            }
        }
    }
}

fn plan(
    snapshot: &pb::StateSnapshot,
    entry: &Registration,
    entries: &[Registration],
    last: Option<&Value>,
    now: u64,
) -> Option<Value> {
    let attrs = attributes(snapshot, entry, now);
    // An unknown predicted destination is not an ended session. Wait for
    // confirmation/expiry, while still honoring stop, standby and disconnect.
    if attrs["canControlPlayback"] == true
        && attrs["playback"]["song"].is_null()
        && snapshot.pending.is_some_and(|pending| pending.current_item)
        && matches!(
            attrs["playback"]["state"].as_str(),
            Some("playing" | "paused" | "buffering")
        )
    {
        return None;
    }
    let active = attrs["canControlPlayback"] == true
        && !attrs["playback"]["song"].is_null()
        && matches!(
            attrs["playback"]["state"].as_str(),
            Some("playing" | "paused" | "buffering")
        );
    let event = if entry.kind == 1 {
        if !active
            || entries.iter().any(|other| {
                other.installation_id == entry.installation_id
                    && other.environment == entry.environment
                    && other.kind == 2
            })
        {
            return None;
        }
        "start"
    } else if !active {
        "end"
    } else {
        "update"
    };
    if event == "update"
        && last.is_some_and(|previous| !changed(&previous["aps"]["attributes"], &attrs))
    {
        return None;
    }
    let attrs = if event == "end" {
        json!({"id": entry.session_id})
    } else {
        attrs
    };
    Some(json!({"aps": {"event": event, "timestamp": now, "attributes": attrs}}))
}

fn changed(previous: &Value, current: &Value) -> bool {
    fn without_clock(value: &Value) -> Value {
        let mut v = value.clone();
        v.as_object_mut().map(|o| o.remove("timestampSeconds"));
        if let Some(t) = v["playback"]["timeline"].as_object_mut() {
            for key in ["position", "progress", "sampledAtSeconds"] {
                t.remove(key);
            }
        }
        v
    }
    if without_clock(previous) != without_clock(current) {
        return true;
    }
    let p = previous["playback"]["timeline"]["position"].as_f64();
    let c = current["playback"]["timeline"]["position"].as_f64();
    match (p, c) {
        (Some(p), Some(c)) => {
            let elapsed = if previous["playback"]["state"] == "playing" {
                (current["timestampSeconds"].as_f64().unwrap_or(0.)
                    - previous["timestampSeconds"].as_f64().unwrap_or(0.))
                .max(0.)
            } else {
                0.
            };
            (c - p - elapsed).abs() > 2.
        }
        _ => p != c,
    }
}

fn seconds(timestamp: &prost_types::Timestamp) -> f64 {
    timestamp.seconds as f64 + f64::from(timestamp.nanos) / 1e9
}

fn attributes(snapshot: &pb::StateSnapshot, entry: &Registration, now: u64) -> Value {
    let state = snapshot.now_playing.clone().unwrap_or_default();
    let can_control = snapshot.connection_status == pb::ConnectionStatus::Connected as i32
        && state.is_standby != Some(true);
    let playlist = state.playlist.unwrap_or_default();
    let index = playlist.current_index;
    let song = state.current_item.and_then(|item| {
        let track = item.track.unwrap_or_default();
        let title = track.title.or(item.display_name).filter(|s| !s.is_empty())?;
        Some(json!({"id": if item.id.len() > 256 { format!("{:x}", Sha256::digest(item.id.as_bytes())) } else { item.id }, "title": bounded(&title, 160), "artist": track.artist.map(|s| bounded(&s, 160)),
            "album": track.album.map(|s| bounded(&s, 160)), "artworkURL": item.artwork_url.filter(|s| s.len() <= 768), "queueIndex": index}))
    });
    let sampled = state
        .timeline
        .as_ref()
        .filter(|_| !snapshot.pending.is_some_and(|pending| pending.transport))
        .and_then(|t| t.position_sampled_at.as_ref())
        .map(seconds);
    let timestamp = sampled
        .or(snapshot.published_at.as_ref().map(seconds))
        .unwrap_or(now as f64);
    let timeline = state.timeline.map(|t| {
        let range = match (t.is_seekable, t.seek_lower_bound_seconds, t.seek_upper_bound_seconds) {
            (Some(true), Some(lower), Some(upper)) if lower >= 0 && upper > lower => Some([lower, upper]),
            _ => None,
        };
        let progress = t.position_seconds.zip(t.duration_seconds).filter(|(_, d)| *d > 0).map(|(p, d)| f64::from(p) / f64::from(d));
        json!({"position": t.position_seconds, "duration": t.duration_seconds, "progress": progress, "seekableRange": range, "sampledAtSeconds": sampled})
    });
    let volume = state.room_volume.unwrap_or_default();
    let play_state = match state
        .transport_state
        .and_then(|s| pb::TransportState::try_from(s).ok())
    {
        Some(pb::TransportState::Playing) => "playing",
        Some(pb::TransportState::Paused) => "paused",
        Some(pb::TransportState::Buffering | pb::TransportState::Waiting) => "buffering",
        _ => "stopped",
    };
    json!({
        "id": if entry.kind == 2 { entry.session_id.clone() } else { format!("{}|{}", entry.server_url, snapshot.room) },
        "serverURL": entry.server_url, "room": snapshot.room, "maximumVolume": volume.maximum_volume.clamp(0, 70),
        "playback": {"song": song, "state": play_state, "timeline": timeline}, "timestampSeconds": timestamp,
        "hasPrevious": can_control && index.is_some_and(|i| i > 0),
        "hasNext": can_control && index.zip(playlist.total).is_some_and(|(i, total)| i.saturating_add(1) < total),
        "volume": volume.volume, "canControlPlayback": can_control,
        "installationID": entry.installation_id,
        "pushEnvironment": if entry.environment == 1 { "sandbox" } else { "production" }
    })
}

fn bounded(value: &str, max_bytes: usize) -> String {
    let mut end = value.len().min(max_bytes);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

#[cfg(test)]
#[path = "push_tests.rs"]
mod tests;
