use std::time::Duration;

use serde_json::Value;
use tokio::time::Instant;

use crate::pb::{
    CurrentItem, MediaItem, MediaItemType, NowPlayingState, PendingState, PlaylistItem,
    StateSnapshot, Timeline, Track, TransportState,
};

struct Pending<T> {
    tag: String,
    value: T,
    expires: Instant,
}

impl<T> Pending<T> {
    fn new(tag: &str, value: T, seconds: u64) -> Self {
        Self {
            tag: tag.into(),
            value,
            expires: Instant::now() + Duration::from_secs(seconds),
        }
    }

    fn expired(&self) -> bool {
        Instant::now() >= self.expires
    }
}

#[derive(Default)]
pub struct Optimism {
    transport: Option<Pending<i32>>,
    current_item: Option<Pending<CurrentItem>>,
    queue_index: Option<Pending<i32>>,
    queue_total: Option<Pending<i32>>,
    timeline: Option<Pending<Option<Timeline>>>,
    volume: Option<Pending<i32>>,
    mute: Option<Pending<bool>>,
}

impl Optimism {
    pub fn apply(
        &mut self,
        tag: &str,
        path: &str,
        body: &Value,
        preview: Option<MediaItem>,
        observed: &StateSnapshot,
    ) -> bool {
        let Some(playing) = observed.now_playing.as_ref() else {
            return false;
        };
        match path {
            "/V2/transport/play" => {
                self.transport = Some(Pending::new(tag, TransportState::Playing as i32, 4));
            }
            "/V2/transport/pause" => {
                self.transport = Some(Pending::new(tag, TransportState::Paused as i32, 4));
            }
            "/V2/transport/skip_track" => {
                let step = body.get("skip_track").and_then(Value::as_i64).unwrap_or(0);
                let Some(current) = playing.playlist.as_ref().and_then(|p| p.current_index) else {
                    return false;
                };
                self.select_queue(tag, current.saturating_add(step as i32), playing);
            }
            "/V2/playlist/select" => {
                let Some(index) = body.get("index").and_then(Value::as_i64) else {
                    return false;
                };
                self.select_queue(tag, index as i32, playing);
            }
            "/V2/seek/set_position" => {
                let Some(position) = body.get("position").and_then(Value::as_i64) else {
                    return false;
                };
                let mut timeline = playing.timeline.unwrap_or_default();
                timeline.position_seconds = Some(position as i32);
                timeline.position_sampled_at = Some(std::time::SystemTime::now().into());
                self.timeline = Some(Pending::new(tag, Some(timeline), 4));
            }
            "/V2/volume/set_vol" => {
                let Some(volume) = body.get("volume").and_then(Value::as_i64) else {
                    return false;
                };
                self.volume = Some(Pending::new(tag, volume as i32, 3));
            }
            "/V2/volume/set_mute" => {
                let Some(mute) = body.get("mute").and_then(Value::as_bool) else {
                    return false;
                };
                self.mute = Some(Pending::new(tag, mute, 3));
            }
            "/V2/media/select" => {
                let queue = body
                    .get("queue")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if queue != "now" && queue != "replace" {
                    return false;
                }
                self.transport = Some(Pending::new(tag, TransportState::Playing as i32, 8));
                self.timeline = Some(Pending::new(tag, None, 8));
                if let Some(item) = preview {
                    let total = match MediaItemType::try_from(item.r#type).ok() {
                        Some(MediaItemType::Track) => Some(1),
                        _ => item.child_count,
                    };
                    if queue == "replace"
                        && let Some(total) = total
                    {
                        self.queue_total = Some(Pending::new(tag, total, 8));
                        self.queue_index = Some(Pending::new(tag, 0, 8));
                    }
                    if let Some(song) = media_preview(&item) {
                        self.current_item = Some(Pending::new(tag, song, 8));
                    }
                }
            }
            _ => return false,
        }
        true
    }

    fn select_queue(&mut self, tag: &str, index: i32, playing: &NowPlayingState) {
        if index < 0
            || playing
                .playlist
                .as_ref()
                .and_then(|p| p.total)
                .is_some_and(|n| index >= n)
        {
            return;
        }
        self.queue_index = Some(Pending::new(tag, index, 6));
        self.timeline = Some(Pending::new(tag, None, 6));
        if let Some(item) = playing
            .playlist
            .as_ref()
            .and_then(|p| p.items.iter().find(|item| item.index == index))
            && let Some(preview) = playlist_preview(item)
        {
            self.current_item = Some(Pending::new(tag, preview, 6));
        }
    }

    pub fn reconcile(&mut self, observed: &StateSnapshot) -> bool {
        let Some(playing) = observed.now_playing.as_ref() else {
            return self.expire();
        };
        let before = self.count();
        clear_if(&mut self.transport, playing.transport_state);
        clear_if(
            &mut self.queue_index,
            playing.playlist.as_ref().and_then(|p| p.current_index),
        );
        clear_if(
            &mut self.queue_total,
            playing.playlist.as_ref().and_then(|p| p.total),
        );
        clear_if(
            &mut self.volume,
            playing.room_volume.as_ref().and_then(|v| v.volume),
        );
        clear_if(
            &mut self.mute,
            playing.room_volume.as_ref().and_then(|v| v.is_muted),
        );
        if self.current_item.as_ref().is_some_and(|p| {
            p.expired()
                || playing.current_item.as_ref().is_some_and(|item| {
                    title(item).eq_ignore_ascii_case(title(&p.value))
                        && item.track.as_ref().and_then(|t| t.artist.as_deref())
                            == p.value.track.as_ref().and_then(|t| t.artist.as_deref())
                })
        }) {
            self.current_item = None;
        }
        if self.timeline.as_ref().is_some_and(|p| {
            p.expired()
                || match (&p.value, &playing.timeline) {
                    (Some(target), Some(actual)) => target
                        .position_seconds
                        .zip(actual.position_seconds)
                        .is_some_and(|(a, b)| (a - b).abs() <= 2),
                    (None, _) => self.current_item.is_none() && self.queue_index.is_none(),
                    _ => false,
                }
        }) {
            self.timeline = None;
        }
        before != self.count()
    }

    pub fn fail(&mut self, tag: &str) -> bool {
        let before = self.count();
        clear_tag(&mut self.transport, tag);
        clear_tag(&mut self.current_item, tag);
        clear_tag(&mut self.queue_index, tag);
        clear_tag(&mut self.queue_total, tag);
        clear_tag(&mut self.timeline, tag);
        clear_tag(&mut self.volume, tag);
        clear_tag(&mut self.mute, tag);
        before != self.count()
    }

    pub fn expire(&mut self) -> bool {
        let before = self.count();
        expire(&mut self.transport);
        expire(&mut self.current_item);
        expire(&mut self.queue_index);
        expire(&mut self.queue_total);
        expire(&mut self.timeline);
        expire(&mut self.volume);
        expire(&mut self.mute);
        before != self.count()
    }

    pub fn snapshot(&self, observed: &StateSnapshot) -> StateSnapshot {
        let mut effective = observed.clone();
        let Some(playing) = effective.now_playing.as_mut() else {
            return effective;
        };
        if let Some(p) = &self.transport {
            playing.transport_state = Some(p.value);
        }
        if let Some(p) = &self.current_item {
            playing.current_item = Some(p.value.clone());
        }
        if let Some(p) = &self.timeline {
            playing.timeline = p.value;
        }
        if let Some(p) = &self.queue_index {
            playing.playlist.get_or_insert_default().current_index = Some(p.value);
        }
        if let Some(p) = &self.queue_total {
            playing.playlist.get_or_insert_default().total = Some(p.value);
        }
        if let Some(p) = &self.volume {
            playing.room_volume.get_or_insert_default().volume = Some(p.value);
        }
        if let Some(p) = &self.mute {
            playing.room_volume.get_or_insert_default().is_muted = Some(p.value);
        }
        effective.pending = Some(PendingState {
            playback: self.transport.is_some() || self.current_item.is_some(),
            queue: self.queue_index.is_some() || self.queue_total.is_some(),
            timeline: self.timeline.is_some(),
            volume: self.volume.is_some(),
            mute: self.mute.is_some(),
        });
        effective.published_at = Some(std::time::SystemTime::now().into());
        effective
    }

    fn count(&self) -> usize {
        [
            &self.transport.is_some(),
            &self.current_item.is_some(),
            &self.queue_index.is_some(),
            &self.queue_total.is_some(),
            &self.timeline.is_some(),
            &self.volume.is_some(),
            &self.mute.is_some(),
        ]
        .into_iter()
        .filter(|yes| **yes)
        .count()
    }
}

fn clear_if<T: PartialEq>(pending: &mut Option<Pending<T>>, actual: Option<T>) {
    if pending
        .as_ref()
        .is_some_and(|p| p.expired() || actual.as_ref() == Some(&p.value))
    {
        *pending = None;
    }
}

fn clear_tag<T>(pending: &mut Option<Pending<T>>, tag: &str) {
    if pending.as_ref().is_some_and(|p| p.tag == tag) {
        *pending = None;
    }
}

fn expire<T>(pending: &mut Option<Pending<T>>) {
    if pending.as_ref().is_some_and(Pending::expired) {
        *pending = None;
    }
}

fn title(item: &CurrentItem) -> &str {
    item.track
        .as_ref()
        .and_then(|track| track.title.as_deref())
        .or(item.display_name.as_deref())
        .unwrap_or_default()
}

fn media_preview(item: &MediaItem) -> Option<CurrentItem> {
    let title = item.title.as_deref().or(item.name.as_deref())?.to_owned();
    Some(CurrentItem {
        id: format!("preview:{}", item.id),
        display_name: Some(title.clone()),
        artwork_url: item.artwork_url.clone(),
        track: Some(Track {
            title: Some(title),
            album: item.album.clone(),
            artist: (!item.artists.is_empty()).then(|| item.artists.join(", ")),
        }),
    })
}

fn playlist_preview(item: &PlaylistItem) -> Option<CurrentItem> {
    let title = item.display_name.as_deref()?.to_owned();
    Some(CurrentItem {
        id: format!("playlist:{}", item.index),
        display_name: Some(title.clone()),
        artwork_url: item.artwork_url.clone(),
        track: Some(Track {
            title: Some(title),
            album: item.album.clone(),
            artist: item.artist.clone(),
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pb::{ConnectionStatus, MediaProvider, Playlist, RoomVolume};
    use serde_json::json;

    fn state() -> StateSnapshot {
        StateSnapshot {
            room: "Linn".into(),
            connection_status: ConnectionStatus::Connected as i32,
            now_playing: Some(NowPlayingState {
                transport_state: Some(TransportState::Stopped as i32),
                current_item: Some(CurrentItem {
                    id: "old".into(),
                    display_name: Some("Old Song".into()),
                    track: Some(Track {
                        title: Some("Old Song".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                playlist: Some(Playlist {
                    total: Some(3),
                    current_index: Some(1),
                    ..Default::default()
                }),
                room_volume: Some(RoomVolume {
                    volume: Some(20),
                    maximum_volume: 70,
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn media_preview_survives_stale_linn_state_until_confirmed() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        let preview = MediaItem {
            id: "new".into(),
            r#type: MediaItemType::Track as i32,
            title: Some("New Song".into()),
            provider: MediaProvider::Qobuz as i32,
            ..Default::default()
        };
        assert!(optimism.apply(
            "command-1",
            "/V2/media/select",
            &json!({"queue": "replace"}),
            Some(preview),
            &observed
        ));

        let first = optimism.snapshot(&observed);
        assert_eq!(
            first.now_playing.as_ref().and_then(|p| p.transport_state),
            Some(TransportState::Playing as i32)
        );
        assert_eq!(
            first
                .now_playing
                .as_ref()
                .and_then(|p| p.current_item.as_ref())
                .map(title),
            Some("New Song")
        );
        assert!(first.pending.as_ref().is_some_and(|p| p.playback));

        // Linn can report its old stopped state while the selection is loading.
        optimism.reconcile(&observed);
        let stale = optimism.snapshot(&observed);
        assert_eq!(
            stale
                .now_playing
                .as_ref()
                .and_then(|p| p.current_item.as_ref())
                .map(title),
            Some("New Song")
        );

        let playing = observed.now_playing.as_mut().unwrap();
        playing.transport_state = Some(TransportState::Playing as i32);
        playing.current_item = Some(CurrentItem {
            id: "gateway-id".into(),
            display_name: Some("New Song".into()),
            track: Some(Track {
                title: Some("New Song".into()),
                ..Default::default()
            }),
            ..Default::default()
        });
        playing.playlist.as_mut().unwrap().total = Some(1);
        playing.playlist.as_mut().unwrap().current_index = Some(0);
        assert!(optimism.reconcile(&observed));
        let confirmed = optimism.snapshot(&observed);
        assert_eq!(
            confirmed
                .now_playing
                .as_ref()
                .and_then(|p| p.current_item.as_ref())
                .map(title),
            Some("New Song")
        );
        assert!(
            !confirmed
                .pending
                .as_ref()
                .is_some_and(|p| p.playback || p.queue)
        );
    }

    #[test]
    fn rejected_command_rolls_back_to_observed_state() {
        let observed = state();
        let mut optimism = Optimism::default();
        assert!(optimism.apply(
            "command-2",
            "/V2/transport/play",
            &json!({}),
            None,
            &observed
        ));
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .transport_state,
            Some(TransportState::Playing as i32)
        );
        assert!(optimism.fail("command-2"));
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .transport_state,
            Some(TransportState::Stopped as i32)
        );
    }
}
