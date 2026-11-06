//! A prediction belongs to one dispatched command. Each field is released only
//! by its own Linn event; scheduling, deadlines and supersession live elsewhere.
use crate::pb::{
    CurrentItem, MediaItem, MediaItemType, NowPlayingState, PlaylistItem, StateSnapshot, Timeline,
    Track, TransportState,
};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    Transport(i32),
    Select(i32),
    Skip,
    Seek(i32),
    Media {
        placement: String,
        count: Option<i32>,
        preview: Option<CurrentItem>,
    },
    Volume(i32, bool),
    Mute(bool, bool),
}

impl Command {
    pub fn from_request(
        path: &str,
        body: &Value,
        preview: Option<&MediaItem>,
        first: Option<&MediaItem>,
    ) -> Option<Self> {
        let number = |key| {
            body.get(key)
                .and_then(Value::as_i64)
                .and_then(|n| i32::try_from(n).ok())
        };
        let group = body.get("group").and_then(Value::as_bool).unwrap_or(true);
        Some(match path {
            "/V2/transport/play" => Self::Transport(TransportState::Playing as i32),
            "/V2/transport/pause" => Self::Transport(TransportState::Paused as i32),
            "/V2/playlist/select" => Self::Select(number("index")?),
            "/V2/transport/skip_track" => Self::Skip,
            "/V2/seek/set_position" => Self::Seek(number("position")?),
            "/V2/volume/set_vol" => Self::Volume(number("volume")?, group),
            "/V2/volume/set_mute" => Self::Mute(body.get("mute")?.as_bool()?, group),
            "/V2/media/select" => Self::Media {
                placement: body.get("queue")?.as_str()?.to_owned(),
                count: preview.and_then(queued_track_count),
                preview: first
                    .and_then(media_preview)
                    .or_else(|| preview.and_then(media_preview))
                    .or_else(|| preview.and_then(container_preview)),
            },
            _ => return None,
        })
    }

    pub fn changes_track(&self) -> bool {
        matches!(self, Self::Select(_) | Self::Skip)
            || matches!(self, Self::Media { placement, .. } if matches!(placement.as_str(), "now" | "replace"))
    }

    pub fn replaces_queue(&self) -> bool {
        matches!(self, Self::Media { placement, .. } if placement == "replace")
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Prediction {
    transport: Option<i32>,
    item: Option<Option<CurrentItem>>,
    index: Option<Option<i32>>,
    total: Option<Option<i32>>,
    timeline: Option<Option<Timeline>>,
    volume: Option<i32>,
    mute: Option<bool>,
    clear_items: bool,
    baseline: NowPlayingState,
    queue_change: bool,
    expected_total: Option<i32>,
    track_position: Option<i32>,
    saw_transport: bool,
}

impl Prediction {
    pub fn new(command: &Command, state: &StateSnapshot) -> Self {
        let baseline = state.now_playing.clone().unwrap_or_default();
        let mut p = Self {
            baseline,
            ..Self::default()
        };
        match command {
            Command::Transport(value) => p.transport = Some(*value),
            Command::Volume(value, _) => p.volume = Some(*value),
            Command::Mute(value, _) => p.mute = Some(*value),
            Command::Seek(position) => {
                let mut timeline = p.baseline.timeline.unwrap_or_default();
                timeline.position_seconds = Some(*position);
                timeline.position_sampled_at = Some(std::time::SystemTime::now().into());
                p.timeline = Some(Some(timeline));
            }
            Command::Select(index) => {
                p.index = Some(Some(*index));
                p.item = Some(
                    p.baseline
                        .playlist
                        .as_ref()
                        .and_then(|q| q.items.iter().find(|row| row.index == *index))
                        .and_then(playlist_preview),
                );
                p.timeline = Some(None);
            }
            Command::Skip => {
                // Shuffle (or an unknown queue): do not invent a destination.
                p.index = Some(None);
                p.item = Some(None);
                p.timeline = Some(None);
            }
            Command::Media {
                placement,
                count,
                preview,
            } => {
                p.queue_change = true;
                if placement == "replace" {
                    p.index = Some(Some(0));
                    p.total = Some(*count);
                    p.clear_items = true;
                } else {
                    p.total = Some(
                        p.baseline
                            .playlist
                            .as_ref()
                            .and_then(|q| q.total)
                            .zip(*count)
                            .map(|(a, b)| a.saturating_add(b)),
                    );
                }
                if matches!(placement.as_str(), "now" | "replace") {
                    p.item = Some(preview.clone());
                    p.timeline = Some(None);
                }
            }
        }
        if command.changes_track() {
            p.transport = Some(TransportState::Playing as i32);
            // An unchanged transport state need not be pushed again. A later
            // stopped/loading event invalidates this standing evidence.
            p.saw_transport = p.baseline.transport_state == p.transport;
        }
        p.expected_total = p.total.flatten();
        p
    }

    /// Only call for a successfully decoded event containing this field. An
    /// unrelated volume/playlist frame must never confirm cached metadata.
    pub fn observe(&mut self, path: &str, observed: &StateSnapshot) {
        let Some(actual) = observed.now_playing.as_ref() else {
            return;
        };
        match path {
            "/V2/transport/status" => {
                self.saw_transport =
                    self.transport.is_some() && self.transport == actual.transport_state;
            }
            "volume" | "mute" => {
                if let Some(room) = &actual.room_volume {
                    if path == "volume" && self.volume == room.volume {
                        self.volume = None;
                    }
                    if path == "mute" && self.mute == room.is_muted {
                        self.mute = None;
                    }
                }
            }
            "/V2/playlist/subscribe" => {
                if let Some(queue) = &actual.playlist {
                    let baseline = self.baseline.playlist.as_ref();
                    let revision_changed = queue.content_revision.is_some()
                        && queue.content_revision != baseline.and_then(|q| q.content_revision);
                    // Revisions also change on selection updates. Require a
                    // changed queue, not just a new revision. Counts are hints:
                    // expose an actual mismatch but keep the lane bounded/pending.
                    let contents_changed = queue.total != baseline.and_then(|q| q.total)
                        || baseline.is_some_and(|old| {
                            queue
                                .items
                                .iter()
                                .map(|i| (&i.display_name, &i.album, &i.artist))
                                .ne(old
                                    .items
                                    .iter()
                                    .map(|i| (&i.display_name, &i.album, &i.artist)))
                        });
                    if self.queue_change && revision_changed {
                        if self
                            .expected_total
                            .map_or(contents_changed, |n| queue.total == Some(n))
                        {
                            self.queue_change = false;
                        }
                        if contents_changed || !self.queue_change {
                            self.total = None;
                            self.clear_items = false;
                        }
                    }
                    if !self.queue_change
                        && self.index.is_some_and(|index| {
                            index.map_or(
                                queue.current_index != baseline.and_then(|q| q.current_index),
                                |i| queue.current_index == Some(i),
                            )
                        })
                    {
                        self.index = None;
                    }
                }
            }
            "/V2/metadata/status" => {
                let incoming = actual.current_item.as_ref();
                let expected = self.item.as_ref().and_then(Option::as_ref);
                if incoming.is_some_and(has_title)
                    && (same_track(incoming, expected)
                        || !same_track(incoming, self.baseline.current_item.as_ref()))
                {
                    self.item = None;
                    // A track change invalidates the old timeline, but only a
                    // subsequent seek event may supply the new track's position.
                }
            }
            "/V2/seek/status" => {
                if let Some(target) = self.timeline {
                    if let Some(target) = target {
                        let near = actual
                            .timeline
                            .and_then(|t| t.position_seconds)
                            .zip(target.position_seconds)
                            .is_some_and(|(a, b)| (i64::from(a) - i64::from(b)).abs() <= 2);
                        if near {
                            self.timeline = None;
                        }
                    } else {
                        let position = actual.timeline.and_then(|t| t.position_seconds);
                        // Anchor at a reset. Continue beyond it only after
                        // the new song's metadata confirms: during a quick
                        // second skip, low ticks may still belong to song one.
                        // A jump away from the sequence invalidates the anchor.
                        self.track_position = position.filter(|p| {
                            (0..=2).contains(p)
                                || (self.item.is_none()
                                    && self.track_position.is_some_and(|last| {
                                        (last..=last.saturating_add(2)).contains(p)
                                    }))
                        });
                    }
                }
            }
            _ => {}
        }
        // During a track start, an early "playing" frame may still describe
        // the old song. Keep the requested transport through stop/loading until
        // the queue/song have settled and transport evidence agrees.
        if self.saw_transport && self.item.is_none() && self.index.is_none() && !self.queue_change {
            self.transport = None;
        }
        // Seek and metadata may arrive in either order. Retain the seek evidence
        // instead of demanding another frame after the song is confirmed.
        if self.timeline == Some(None)
            && self.item.is_none()
            && self.index.is_none()
            && self.track_position.is_some()
        {
            self.timeline = None;
        }
    }

    pub fn settled(&self) -> bool {
        self.transport.is_none()
            && self.item.is_none()
            && self.index.is_none()
            && self.total.is_none()
            && self.timeline.is_none()
            && self.volume.is_none()
            && self.mute.is_none()
            && !self.queue_change
    }

    pub fn project(&self, snapshot: &mut StateSnapshot) {
        let playing = snapshot.now_playing.get_or_insert_default();
        let flags = snapshot.pending.get_or_insert_default();
        if let Some(value) = self.transport {
            playing.transport_state = Some(value);
            flags.transport = true;
        }
        if let Some(value) = &self.item {
            playing.current_item = value.clone();
            flags.current_item = true;
        }
        if let Some(value) = self.timeline {
            playing.timeline = value;
            flags.timeline = true;
        }
        if let Some(value) = self.index {
            playing.playlist.get_or_insert_default().current_index = value;
            flags.queue_index = true;
        }
        if let Some(value) = self.total {
            playing.playlist.get_or_insert_default().total = value;
            flags.queue_total = true;
        }
        if self.clear_items {
            let queue = playing.playlist.get_or_insert_default();
            queue.items.clear();
            queue.content_revision = None;
        }
        if let Some(value) = self.volume {
            playing.room_volume.get_or_insert_default().volume = Some(value);
            flags.volume = true;
        }
        if let Some(value) = self.mute {
            playing.room_volume.get_or_insert_default().is_muted = Some(value);
            flags.mute = true;
        }
        flags.queue |= flags.queue_index || flags.queue_total || self.queue_change;
        flags.playback |= flags.transport || flags.current_item;
    }
}

fn has_title(item: &CurrentItem) -> bool {
    item.track
        .as_ref()
        .and_then(|t| t.title.as_deref())
        .or(item.display_name.as_deref())
        .is_some_and(|s| !s.trim().is_empty())
}

// The gateway exposes display metadata, not a stable track ID. This is evidence
// of the requested outcome, never proof of which command caused it.
fn same_track(a: Option<&CurrentItem>, b: Option<&CurrentItem>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a.track == b.track && a.display_name == b.display_name,
        (None, None) => true,
        _ => false,
    }
}

fn media_preview(item: &MediaItem) -> Option<CurrentItem> {
    if !matches!(
        MediaItemType::try_from(item.r#type).ok(),
        Some(MediaItemType::Track | MediaItemType::Station)
    ) {
        return None;
    }
    let title = item
        .title
        .as_deref()
        .filter(|title| !title.trim().is_empty())
        .or(item.name.as_deref().filter(|name| !name.trim().is_empty()))?
        .to_owned();
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

fn container_preview(item: &MediaItem) -> Option<CurrentItem> {
    if !matches!(
        MediaItemType::try_from(item.r#type).ok(),
        Some(MediaItemType::Album | MediaItemType::Playlist)
    ) {
        return None;
    }
    let name = item
        .title
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .or(item
            .name
            .as_deref()
            .filter(|value| !value.trim().is_empty()))?;
    Some(CurrentItem {
        id: format!("preview:{}", item.id),
        display_name: Some(name.to_owned()),
        artwork_url: item.artwork_url.clone(),
        track: None,
    })
}

fn queued_track_count(item: &MediaItem) -> Option<i32> {
    match MediaItemType::try_from(item.r#type).ok() {
        Some(MediaItemType::Track) => {
            Some(item.child_count.filter(|count| *count > 0).unwrap_or(1))
        }
        Some(MediaItemType::Album | MediaItemType::Playlist) => {
            item.child_count.filter(|count| *count > 0)
        }
        _ => None,
    }
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
