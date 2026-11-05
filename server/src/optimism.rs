use std::time::Duration;

use serde_json::Value;
use tokio::time::Instant;

use crate::pb::{
    CurrentItem, MediaItem, MediaItemType, NowPlayingState, PendingState, PlaylistItem,
    StateSnapshot, Timeline, Track, TransportState,
};

#[derive(Clone)]
struct Pending<T> {
    tag: String,
    value: T,
    expires: Instant,
    saw_different_value: bool,
    dispatched: bool,
}

impl<T> Pending<T> {
    fn new(tag: &str, value: T, seconds: u64) -> Self {
        Self {
            tag: tag.into(),
            value,
            expires: Instant::now() + Duration::from_secs(seconds),
            saw_different_value: false,
            dispatched: true,
        }
    }

    fn expired(&self) -> bool {
        Instant::now() >= self.expires
    }
}

struct ReplaceBaseline {
    revision: Option<i64>,
    total: Option<i32>,
    current_index: Option<i32>,
}

struct QueueAdditions {
    base_total: i32,
    deltas: Vec<Pending<i32>>,
}

#[derive(Clone)]
enum PreviewRule {
    Row,
    Media {
        baseline_title: Option<String>,
        baseline_revision: Option<i64>,
        superseded_titles: Vec<String>,
        superseded_row_titles: Vec<String>,
    },
}

struct ShuffleTimelineBaseline {
    title: Option<String>,
    index: Option<i32>,
}

struct ReplaceFallback {
    active_tag: String,
    queue_index: Option<Pending<i32>>,
    current_item: Option<Pending<Option<CurrentItem>>>,
    current_item_rule: Option<PreviewRule>,
    timeline: Option<Pending<Option<Timeline>>>,
    queue_baseline_index: Option<i32>,
    queue_baseline_direct: bool,
}

#[derive(Default)]
pub struct Optimism {
    transport: Option<Pending<i32>>,
    current_item: Option<Pending<Option<CurrentItem>>>,
    current_item_rule: Option<PreviewRule>,
    queue_index: Option<Pending<i32>>,
    queue_baseline_index: Option<i32>,
    queue_baseline_direct: bool,
    queue_total: Option<Pending<i32>>,
    queue_additions: Option<QueueAdditions>,
    timeline: Option<Pending<Option<Timeline>>>,
    shuffle_timeline_baseline: Option<ShuffleTimelineBaseline>,
    volume: Option<Pending<i32>>,
    mute: Option<Pending<bool>>,
    replace_revision: Option<Pending<ReplaceBaseline>>,
    replace_fallback: Option<ReplaceFallback>,
    select_fallback: Option<ReplaceFallback>,
    superseded_replace_totals: Vec<i32>,
    last_observed_total: Option<i32>,
}

impl Optimism {
    pub fn apply(
        &mut self,
        tag: &str,
        path: &str,
        body: &Value,
        preview: Option<MediaItem>,
        first_track: Option<MediaItem>,
        observed: &StateSnapshot,
    ) -> bool {
        let Some(playing) = observed.now_playing.as_ref() else {
            return false;
        };
        self.last_observed_total = playing.playlist.as_ref().and_then(|p| p.total);
        match path {
            "/V2/transport/play" => {
                self.transport = Some(Pending::new(tag, TransportState::Playing as i32, 4));
            }
            "/V2/transport/pause" => {
                self.transport = Some(Pending::new(tag, TransportState::Paused as i32, 4));
            }
            "/V2/transport/skip_track" => {
                if body.get("shuffle").and_then(Value::as_bool) == Some(true) {
                    self.timeline = Some(Pending::new(tag, None, 6));
                    self.shuffle_timeline_baseline = Some(ShuffleTimelineBaseline {
                        title: playing.current_item.as_ref().map(title).map(str::to_owned),
                        index: playing.playlist.as_ref().and_then(|p| p.current_index),
                    });
                    return true;
                }
                if self.replace_has_unknown_size() && self.queue_index.is_none() {
                    self.timeline = Some(Pending::new(tag, None, 6));
                    return true;
                }
                let step = body.get("skip_track").and_then(Value::as_i64).unwrap_or(0);
                let Some(current) = self
                    .queue_index
                    .as_ref()
                    .map(|p| p.value)
                    .or_else(|| playing.playlist.as_ref().and_then(|p| p.current_index))
                else {
                    return false;
                };
                self.select_queue(tag, current.saturating_add(step as i32), playing, false);
            }
            "/V2/playlist/select" => {
                let Some(index) = body.get("index").and_then(Value::as_i64) else {
                    return false;
                };
                self.select_queue(tag, index as i32, playing, false);
            }
            "/V2/seek/set_position" => {
                let Some(position) = body.get("position").and_then(Value::as_i64) else {
                    return false;
                };
                let mut timeline = playing.timeline.unwrap_or_default();
                timeline.position_seconds = Some(position as i32);
                timeline.position_sampled_at = Some(std::time::SystemTime::now().into());
                self.timeline = Some(Pending::new(tag, Some(timeline), 4));
                self.shuffle_timeline_baseline = None;
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
                let placement = queue;
                if !matches!(placement, "now" | "next" | "last" | "replace") {
                    return false;
                }
                if matches!(placement, "now" | "replace") {
                    self.transport = Some(Pending::new(tag, TransportState::Playing as i32, 8));
                    self.timeline = Some(Pending::new(tag, None, 8));
                    self.shuffle_timeline_baseline = None;
                }
                let count = preview.as_ref().and_then(queued_track_count);
                if placement == "replace" {
                    if self.replace_revision.is_some()
                        && let Some(total) = self.queue_total.as_ref().map(|p| p.value)
                    {
                        self.superseded_replace_totals.push(total);
                    }
                    self.queue_index = None;
                    self.queue_total = None;
                    self.queue_baseline_index = None;
                    self.queue_baseline_direct = false;
                    self.queue_additions = None;
                    self.replace_fallback = None;
                    self.replace_revision = Some(Pending::new(
                        tag,
                        ReplaceBaseline {
                            revision: playing.playlist.as_ref().and_then(|p| p.content_revision),
                            total: playing.playlist.as_ref().and_then(|p| p.total),
                            current_index: playing.playlist.as_ref().and_then(|p| p.current_index),
                        },
                        8,
                    ));
                    if let Some(count) = count {
                        self.queue_total = Some(Pending::new(tag, count, 8));
                        self.queue_index = Some(Pending::new(tag, 0, 8));
                        self.queue_baseline_index = Some(0);
                    }
                } else if let Some(count) = count {
                    let base_total = self.queue_total.as_ref().map(|p| p.value).or_else(|| {
                        (self.replace_revision.is_none())
                            .then_some(playing.playlist.as_ref().and_then(|p| p.total))
                            .flatten()
                    });
                    if let Some(total) = base_total {
                        self.queue_additions
                            .get_or_insert_with(|| QueueAdditions {
                                base_total: total,
                                deltas: Vec::new(),
                            })
                            .deltas
                            .push(Pending::new(tag, count, 8));
                    }
                }
                if matches!(placement, "now" | "replace") {
                    let mut superseded_titles = match &self.current_item_rule {
                        Some(PreviewRule::Media {
                            superseded_titles, ..
                        }) => superseded_titles.clone(),
                        _ => Vec::new(),
                    };
                    let superseded_row_titles = match &self.current_item_rule {
                        Some(PreviewRule::Media {
                            superseded_row_titles,
                            ..
                        }) => superseded_row_titles.clone(),
                        _ => Vec::new(),
                    };
                    if let Some(previous) =
                        self.current_item.as_ref().and_then(|p| p.value.as_ref())
                    {
                        let previous_title = title(previous);
                        if !previous_title.is_empty() {
                            superseded_titles.push(previous_title.to_owned());
                        }
                    }
                    let predicted_item = first_track
                        .as_ref()
                        .and_then(media_preview)
                        .or_else(|| preview.as_ref().and_then(media_preview));
                    self.current_item = predicted_item.map(|item| Pending::new(tag, Some(item), 8));
                    if let Some(expected) = self
                        .current_item
                        .as_ref()
                        .and_then(|p| p.value.as_ref())
                        .map(title)
                    {
                        superseded_titles.retain(|old| !old.eq_ignore_ascii_case(expected));
                    }
                    if superseded_titles.len() > 8 {
                        superseded_titles.drain(..superseded_titles.len() - 8);
                    }
                    self.current_item_rule =
                        self.current_item.as_ref().map(|_| PreviewRule::Media {
                            baseline_title: playing
                                .current_item
                                .as_ref()
                                .map(title)
                                .map(str::to_owned),
                            baseline_revision: playing
                                .playlist
                                .as_ref()
                                .and_then(|p| p.content_revision),
                            superseded_titles,
                            superseded_row_titles,
                        });
                }
            }
            _ => return false,
        }
        true
    }

    pub fn apply_deferred_select(
        &mut self,
        tag: &str,
        body: &Value,
        observed: &StateSnapshot,
    ) -> bool {
        let Some(playing) = observed.now_playing.as_ref() else {
            return false;
        };
        let Some(index) = body
            .get("index")
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok())
        else {
            return false;
        };
        self.last_observed_total = playing.playlist.as_ref().and_then(|p| p.total);
        if self.replace_revision.is_none()
            && self.select_fallback.is_none()
            && self.queue_index.is_some()
        {
            self.select_fallback = Some(ReplaceFallback {
                active_tag: tag.to_owned(),
                queue_index: self.queue_index.clone(),
                current_item: self.current_item.clone(),
                current_item_rule: self.current_item_rule.clone(),
                timeline: self.timeline.clone(),
                queue_baseline_index: self.queue_baseline_index,
                queue_baseline_direct: self.queue_baseline_direct,
            });
        } else if let Some(fallback) = self.select_fallback.as_mut() {
            fallback.active_tag = tag.to_owned();
        }
        self.select_queue(tag, index, playing, true);
        if let Some(pending) = self
            .queue_index
            .as_mut()
            .filter(|pending| pending.tag == tag)
        {
            pending.dispatched = false;
        }
        true
    }

    fn select_queue(
        &mut self,
        tag: &str,
        index: i32,
        playing: &NowPlayingState,
        prior_select_in_flight: bool,
    ) {
        if index < 0
            || self
                .predicted_total(playing.playlist.as_ref().and_then(|p| p.total))
                .is_some_and(|n| index >= n)
        {
            return;
        }
        if !prior_select_in_flight
            && self.replace_revision.is_none()
            && let Some(previous) = self
                .queue_index
                .as_ref()
                .filter(|pending| pending.value == index)
        {
            let previous_tag = previous.tag.clone();
            let mut pending = previous.clone();
            pending.tag = tag.to_owned();
            pending.expires = Instant::now() + Duration::from_secs(6);
            self.queue_index = Some(pending);
            if let Some(item) = self.current_item.as_mut()
                && item.tag == previous_tag
            {
                item.tag = tag.to_owned();
            }
            if let Some(timeline) = self.timeline.as_mut()
                && timeline.tag == previous_tag
            {
                timeline.tag = tag.to_owned();
            }
            return;
        }
        if self.replace_revision.is_some() {
            if let Some(fallback) = self.replace_fallback.as_mut() {
                fallback.active_tag = tag.to_owned();
            } else {
                self.replace_fallback = Some(ReplaceFallback {
                    active_tag: tag.to_owned(),
                    queue_index: self.queue_index.clone(),
                    current_item: self.current_item.clone(),
                    current_item_rule: self.current_item_rule.clone(),
                    timeline: self.timeline.clone(),
                    queue_baseline_index: self.queue_baseline_index,
                    queue_baseline_direct: self.queue_baseline_direct,
                });
            }
        }
        let direct = !prior_select_in_flight
            && self.queue_index.is_none()
            && self.replace_revision.is_none();
        let baseline = self.queue_baseline_index.or_else(|| {
            (self.replace_revision.is_none() || self.queue_total.is_some())
                .then_some(playing.playlist.as_ref().and_then(|p| p.current_index))
                .flatten()
        });
        self.queue_baseline_index = baseline;
        self.queue_baseline_direct = direct;
        let mut pending = Pending::new(tag, index, 6);
        pending.saw_different_value =
            self.replace_revision.is_some() || baseline.is_some_and(|current| current != index);
        self.queue_index = Some(pending);
        self.timeline = Some(Pending::new(tag, None, 6));
        self.shuffle_timeline_baseline = None;
        let preview = if self.replace_revision.is_some() {
            None
        } else {
            playing
                .playlist
                .as_ref()
                .and_then(|p| p.items.iter().find(|item| item.index == index))
                .and_then(playlist_preview)
        };
        if preview.is_some()
            || self.current_item.is_some()
            || self.replace_revision.is_some()
            || prior_select_in_flight
        {
            self.current_item = Some(Pending::new(tag, preview, 6));
            self.current_item_rule = Some(PreviewRule::Row);
        }
    }

    pub fn acknowledged(&mut self, tag: &str) {
        if let Some(pending) = self
            .queue_index
            .as_mut()
            .filter(|pending| pending.tag == tag)
        {
            pending.dispatched = true;
        }
        if let Some(pending) = self.queue_index.as_mut()
            && pending.tag == tag
            && self.queue_baseline_direct
        {
            pending.saw_different_value = true;
        }
    }

    pub fn timeline_is_pending(&self) -> bool {
        self.timeline.is_some()
    }

    pub fn replace_has_unknown_size(&self) -> bool {
        self.replace_revision.is_some() && self.queue_total.is_none()
    }

    pub fn promote_surviving_select(&mut self, observed_index: Option<i32>) {
        self.select_fallback = None;
        if let Some(pending) = self.queue_index.as_mut() {
            self.queue_baseline_index = observed_index;
            self.queue_baseline_direct = true;
            pending.saw_different_value =
                observed_index.is_some_and(|index| index != pending.value);
        }
    }

    pub fn add_superseded_titles(&mut self, titles: Vec<String>) {
        if let Some(PreviewRule::Media {
            superseded_row_titles,
            ..
        }) = &mut self.current_item_rule
        {
            let expected = self
                .current_item
                .as_ref()
                .and_then(|pending| pending.value.as_ref())
                .map(title);
            for title in titles {
                if !title.trim().is_empty()
                    && !expected.is_some_and(|value| value.eq_ignore_ascii_case(&title))
                    && !superseded_row_titles
                        .iter()
                        .any(|old| old.eq_ignore_ascii_case(&title))
                {
                    superseded_row_titles.push(title);
                }
            }
            if superseded_row_titles.len() > 8 {
                superseded_row_titles.drain(..superseded_row_titles.len() - 8);
            }
        }
    }

    pub fn reconcile(&mut self, observed: &StateSnapshot) -> bool {
        let Some(playing) = observed.now_playing.as_ref() else {
            return self.expire();
        };
        self.last_observed_total = playing.playlist.as_ref().and_then(|p| p.total);
        let before = self.count();
        let before_total = self.predicted_total(None);
        clear_if(&mut self.transport, playing.transport_state);
        let revision = playing.playlist.as_ref().and_then(|p| p.content_revision);
        if self.replace_revision.as_ref().is_some_and(|pending| {
            let playlist = playing.playlist.as_ref();
            let new_revision = revision.is_some() && revision != pending.value.revision;
            let actual_total = playlist.and_then(|p| p.total);
            let predicted_total = self.queue_total.as_ref().map(|total| total.value);
            let belongs_to_older_replace = actual_total.is_some_and(|total| {
                predicted_total != Some(total) && self.superseded_replace_totals.contains(&total)
            });
            let changed_unversioned_queue = pending.value.revision.is_none()
                && (playlist.and_then(|p| p.total) != pending.value.total
                    || playlist.and_then(|p| p.current_index) != pending.value.current_index);
            pending.expired()
                || (!belongs_to_older_replace && (new_revision || changed_unversioned_queue))
        }) && let Some(replace) = self.replace_revision.take()
        {
            clear_tag(&mut self.queue_index, &replace.tag);
            clear_tag(&mut self.queue_total, &replace.tag);
            self.replace_fallback = None;
            self.superseded_replace_totals.clear();
        }
        if self.replace_revision.is_none() {
            clear_queue_index(
                &mut self.queue_index,
                playing.playlist.as_ref().and_then(|p| p.current_index),
            );
            clear_if(
                &mut self.queue_total,
                playing.playlist.as_ref().and_then(|p| p.total),
            );
            reconcile_additions(
                &mut self.queue_additions,
                playing.playlist.as_ref().and_then(|p| p.total),
            );
        } else {
            let expired_select_tag = self
                .queue_index
                .as_ref()
                .filter(|pending| pending.expired())
                .map(|pending| pending.tag.clone());
            expire(&mut self.queue_index);
            expire(&mut self.queue_total);
            expire_additions(&mut self.queue_additions);
            if let Some(tag) = expired_select_tag {
                self.restore_replace_fallback(&tag);
            }
        }
        if self.queue_index.is_none() {
            self.queue_baseline_index = None;
            self.queue_baseline_direct = false;
            self.select_fallback = None;
        }
        clear_if(
            &mut self.volume,
            playing.room_volume.as_ref().and_then(|v| v.volume),
        );
        clear_if(
            &mut self.mute,
            playing.room_volume.as_ref().and_then(|v| v.is_muted),
        );
        if self.current_item.as_ref().is_some_and(|p| {
            if p.expired() {
                return true;
            }
            match &self.current_item_rule {
                Some(PreviewRule::Row) => self.queue_index.is_none(),
                Some(PreviewRule::Media {
                    baseline_title,
                    baseline_revision,
                    superseded_titles,
                    superseded_row_titles,
                }) => playing.current_item.as_ref().is_some_and(|item| {
                    let incoming_title = title(item);
                    if incoming_title.trim().is_empty() {
                        return false;
                    }
                    let is_stale = baseline_title
                        .as_deref()
                        .is_some_and(|old| old.eq_ignore_ascii_case(incoming_title))
                        || superseded_titles
                            .iter()
                            .any(|old| old.eq_ignore_ascii_case(incoming_title))
                        || superseded_row_titles
                            .iter()
                            .any(|old| old.eq_ignore_ascii_case(incoming_title));
                    let expected_song = p.value.as_ref().is_some_and(|expected| {
                        incoming_title.eq_ignore_ascii_case(title(expected))
                    });
                    if baseline_revision.is_none() {
                        !is_stale
                    } else if revision == *baseline_revision {
                        expected_song && !is_stale
                    } else {
                        let matches_new_queue = playing.playlist.as_ref().is_some_and(|playlist| {
                            playlist.items.iter().any(|row| {
                                Some(row.index) == playlist.current_index
                                    && row.display_name.as_deref().is_some_and(|name| {
                                        name.eq_ignore_ascii_case(incoming_title)
                                    })
                            })
                        });
                        !is_stale
                            || expected_song
                            || (matches_new_queue
                                && !superseded_titles
                                    .iter()
                                    .any(|old| old.eq_ignore_ascii_case(incoming_title)))
                    }
                }),
                None => false,
            }
        }) {
            self.current_item = None;
            self.current_item_rule = None;
        }
        if self.timeline.as_ref().is_some_and(|p| {
            p.expired()
                || match (&p.value, &playing.timeline) {
                    (Some(target), Some(actual)) => target
                        .position_seconds
                        .zip(actual.position_seconds)
                        .is_some_and(|(a, b)| (a - b).abs() <= 2),
                    (None, _) => self.shuffle_timeline_baseline.as_ref().map_or_else(
                        || self.current_item.is_none() && self.queue_index.is_none(),
                        |baseline| {
                            let current_title = playing.current_item.as_ref().map(title);
                            (current_title.is_some_and(|value| !value.is_empty())
                                && current_title != baseline.title.as_deref())
                                || playing.playlist.as_ref().and_then(|p| p.current_index)
                                    != baseline.index
                        },
                    ),
                    _ => false,
                }
        }) {
            self.timeline = None;
            self.shuffle_timeline_baseline = None;
        }
        self.drop_out_of_bounds_select();
        before != self.count() || before_total != self.predicted_total(None)
    }

    pub fn fail(&mut self, tag: &str) -> bool {
        let before = self.count();
        let before_total = self.predicted_total(None);
        clear_tag(&mut self.transport, tag);
        clear_tag(&mut self.current_item, tag);
        if self.current_item.is_none() {
            self.current_item_rule = None;
        }
        clear_tag(&mut self.queue_index, tag);
        if self.queue_index.is_none() {
            self.queue_baseline_index = None;
            self.queue_baseline_direct = false;
        }
        clear_tag(&mut self.queue_total, tag);
        fail_addition(&mut self.queue_additions, tag);
        clear_tag(&mut self.timeline, tag);
        if self.timeline.is_none() {
            self.shuffle_timeline_baseline = None;
        }
        clear_tag(&mut self.volume, tag);
        clear_tag(&mut self.mute, tag);
        if self.select_fallback.as_ref().is_some_and(|fallback| {
            fallback
                .queue_index
                .as_ref()
                .is_some_and(|pending| pending.tag == tag)
        }) {
            self.select_fallback = None;
        }
        if self
            .replace_revision
            .as_ref()
            .is_some_and(|pending| pending.tag == tag)
        {
            self.replace_revision = None;
            self.replace_fallback = None;
            self.superseded_replace_totals.clear();
            if let (Some(additions), Some(total)) =
                (self.queue_additions.as_mut(), self.last_observed_total)
            {
                additions.base_total = total;
            } else {
                self.queue_additions = None;
            }
        }
        let restored = self.restore_replace_fallback(tag) || self.restore_select_fallback(tag);
        self.drop_out_of_bounds_select();
        restored || before != self.count() || before_total != self.predicted_total(None)
    }

    pub fn expire(&mut self) -> bool {
        let before = self.count();
        let before_total = self.predicted_total(None);
        let expired_select_tag = self
            .queue_index
            .as_ref()
            .filter(|pending| pending.expired())
            .map(|pending| pending.tag.clone());
        expire(&mut self.transport);
        expire(&mut self.current_item);
        if self.current_item.is_none() {
            self.current_item_rule = None;
        }
        expire(&mut self.queue_index);
        if self.queue_index.is_none() {
            self.queue_baseline_index = None;
            self.queue_baseline_direct = false;
        }
        expire(&mut self.queue_total);
        expire_additions(&mut self.queue_additions);
        expire(&mut self.timeline);
        if self.timeline.is_none() {
            self.shuffle_timeline_baseline = None;
        }
        expire(&mut self.volume);
        expire(&mut self.mute);
        expire(&mut self.replace_revision);
        if self.replace_revision.is_none() {
            self.replace_fallback = None;
            self.superseded_replace_totals.clear();
        }
        let restored = expired_select_tag.is_some_and(|tag| {
            self.restore_replace_fallback(&tag) || self.restore_select_fallback(&tag)
        });
        if self.queue_index.is_none() {
            self.select_fallback = None;
        }
        self.drop_out_of_bounds_select();
        restored || before != self.count() || before_total != self.predicted_total(None)
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
            playing.current_item = p.value.clone();
        }
        if let Some(p) = &self.timeline {
            playing.timeline = p.value;
        }
        if let Some(p) = &self.queue_index {
            playing.playlist.get_or_insert_default().current_index = Some(p.value);
        }
        if self.replace_has_unknown_size() {
            let playlist = playing.playlist.get_or_insert_default();
            playlist.total = None;
            if self.queue_index.is_none() {
                playlist.current_index = None;
            }
            playlist.items.clear();
        }
        if let Some(total) = self.predicted_total(playing.playlist.as_ref().and_then(|p| p.total)) {
            playing.playlist.get_or_insert_default().total = Some(total);
        }
        if let Some(p) = &self.volume {
            playing.room_volume.get_or_insert_default().volume = Some(p.value);
        }
        if let Some(p) = &self.mute {
            playing.room_volume.get_or_insert_default().is_muted = Some(p.value);
        }
        effective.pending = Some(PendingState {
            playback: self.transport.is_some() || self.current_item.is_some(),
            queue: self.queue_index.is_some()
                || self.queue_total.is_some()
                || self.queue_additions.is_some()
                || self.replace_has_unknown_size(),
            timeline: self.timeline.is_some(),
            volume: self.volume.is_some(),
            mute: self.mute.is_some(),
            queue_index: self.queue_index.is_some() || self.replace_has_unknown_size(),
            queue_total: self.queue_total.is_some()
                || self.queue_additions.is_some()
                || self.replace_has_unknown_size(),
            current_item: self.current_item.is_some(),
            transport: self.transport.is_some(),
        });
        effective.published_at = Some(std::time::SystemTime::now().into());
        effective
    }

    fn count(&self) -> usize {
        [
            &self.transport.is_some(),
            &self.current_item.is_some(),
            &self.queue_index.is_some(),
            &(self.queue_total.is_some() || self.queue_additions.is_some()),
            &self.timeline.is_some(),
            &self.volume.is_some(),
            &self.mute.is_some(),
            &self.replace_revision.is_some(),
        ]
        .into_iter()
        .filter(|yes| **yes)
        .count()
    }

    fn predicted_total(&self, observed_total: Option<i32>) -> Option<i32> {
        if self.replace_has_unknown_size() && self.queue_additions.is_none() {
            return None;
        }
        self.queue_additions.as_ref().map_or_else(
            || {
                self.queue_total
                    .as_ref()
                    .map(|p| p.value)
                    .or(observed_total)
            },
            |additions| {
                Some(
                    additions
                        .deltas
                        .iter()
                        .fold(additions.base_total, |total, delta| {
                            total.saturating_add(delta.value)
                        }),
                )
            },
        )
    }

    fn restore_replace_fallback(&mut self, tag: &str) -> bool {
        if self.replace_revision.is_some()
            && self
                .replace_fallback
                .as_ref()
                .is_some_and(|fallback| fallback.active_tag == tag)
            && let Some(fallback) = self.replace_fallback.take()
        {
            self.queue_index = fallback.queue_index;
            self.current_item = fallback.current_item;
            self.current_item_rule = fallback.current_item_rule;
            self.timeline = fallback.timeline;
            self.queue_baseline_index = fallback.queue_baseline_index;
            self.queue_baseline_direct = fallback.queue_baseline_direct;
            return true;
        }
        false
    }

    fn restore_select_fallback(&mut self, tag: &str) -> bool {
        if self
            .select_fallback
            .as_ref()
            .is_some_and(|fallback| fallback.active_tag == tag)
            && let Some(fallback) = self.select_fallback.take()
        {
            self.queue_index = fallback.queue_index;
            self.current_item = fallback.current_item;
            self.current_item_rule = fallback.current_item_rule;
            self.timeline = fallback.timeline;
            self.queue_baseline_index = fallback.queue_baseline_index;
            self.queue_baseline_direct = fallback.queue_baseline_direct;
            return true;
        }
        false
    }

    fn drop_out_of_bounds_select(&mut self) {
        let Some(total) = self.predicted_total(self.last_observed_total) else {
            return;
        };
        if let Some(tag) = self
            .queue_index
            .as_ref()
            .filter(|pending| pending.value >= total)
            .map(|pending| pending.tag.clone())
        {
            clear_tag(&mut self.queue_index, &tag);
            clear_tag(&mut self.current_item, &tag);
            clear_tag(&mut self.timeline, &tag);
            if self.current_item.is_none() {
                self.current_item_rule = None;
            }
            self.queue_baseline_index = None;
            self.queue_baseline_direct = false;
            self.restore_replace_fallback(&tag);
        }
    }
}

fn fail_addition(additions: &mut Option<QueueAdditions>, tag: &str) {
    if let Some(value) = additions {
        value.deltas.retain(|delta| delta.tag != tag);
        if value.deltas.is_empty() {
            *additions = None;
        }
    }
}

fn expire_additions(additions: &mut Option<QueueAdditions>) {
    if let Some(value) = additions {
        value.deltas.retain(|delta| !delta.expired());
        if value.deltas.is_empty() {
            *additions = None;
        }
    }
}

fn reconcile_additions(additions: &mut Option<QueueAdditions>, observed_total: Option<i32>) {
    expire_additions(additions);
    if let (Some(value), Some(actual)) = (additions.as_mut(), observed_total) {
        while value
            .deltas
            .first()
            .is_some_and(|delta| actual >= value.base_total.saturating_add(delta.value))
        {
            let first = value.deltas.remove(0);
            value.base_total = value.base_total.saturating_add(first.value);
        }
        if value.deltas.is_empty() {
            *additions = None;
        }
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

fn clear_queue_index(pending: &mut Option<Pending<i32>>, actual: Option<i32>) {
    if let Some(value) = pending.as_mut() {
        if actual.is_some_and(|index| index != value.value) {
            value.saw_different_value = true;
        }
        if value.expired()
            || (value.dispatched && value.saw_different_value && actual == Some(value.value))
        {
            *pending = None;
        }
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
            None,
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
    fn row_preview_survives_stale_frame_with_revision() {
        let mut observed = state();
        let playlist = observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap();
        playlist.content_revision = Some(10);
        playlist.items.push(PlaylistItem {
            index: 2,
            display_name: Some("Target".into()),
            ..Default::default()
        });
        let mut optimism = Optimism::default();
        optimism.apply(
            "row",
            "/V2/playlist/select",
            &json!({"index": 2}),
            None,
            None,
            &observed,
        );
        optimism.reconcile(&observed);
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Target")
        );
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(2);
        optimism.acknowledged("row");
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().current_item);
    }

    #[test]
    fn media_preview_waits_for_song_after_revision_changes() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(10);
        let mut optimism = Optimism::default();
        let preview = MediaItem {
            id: "new".into(),
            r#type: MediaItemType::Track as i32,
            title: Some("New Song".into()),
            ..Default::default()
        };
        optimism.apply(
            "media",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(preview),
            None,
            &observed,
        );
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(11);
        optimism.reconcile(&observed);
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("New Song")
        );
    }

    #[test]
    fn restarting_playing_row_confirms_after_ack() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .items
            .push(PlaylistItem {
                index: 1,
                display_name: Some("Old Song".into()),
                ..Default::default()
            });
        let mut optimism = Optimism::default();
        optimism.apply(
            "row",
            "/V2/playlist/select",
            &json!({"index":1}),
            None,
            None,
            &observed,
        );
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().queue_index);
        optimism.acknowledged("row");
        optimism.reconcile(&observed);
        let pending = optimism.snapshot(&observed).pending.unwrap();
        assert!(!pending.queue_index && !pending.current_item && !pending.timeline);
    }

    #[test]
    fn shuffle_skip_does_not_predict_a_sequential_row() {
        let observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "skip",
            "/V2/transport/skip_track",
            &json!({"skip_track":1,"shuffle":true}),
            None,
            None,
            &observed,
        );
        let snapshot = optimism.snapshot(&observed);
        assert!(!snapshot.pending.as_ref().unwrap().queue_index);
        assert_eq!(
            snapshot
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .current_index,
            Some(1)
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

    #[test]
    fn starting_browsed_album_shows_its_first_track() {
        let observed = state();
        let mut optimism = Optimism::default();
        let album = MediaItem {
            id: "album".into(),
            r#type: MediaItemType::Album as i32,
            name: Some("The Album".into()),
            child_count: Some(2),
            ..Default::default()
        };
        let first = MediaItem {
            id: "track".into(),
            r#type: MediaItemType::Track as i32,
            title: Some("First Track".into()),
            ..Default::default()
        };
        assert!(optimism.apply(
            "album-1",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(album),
            Some(first),
            &observed
        ));
        let playing = optimism.snapshot(&observed).now_playing.unwrap();
        assert_eq!(
            playing.current_item.as_ref().map(title),
            Some("First Track")
        );
        assert_eq!(playing.playlist.unwrap().total, Some(2));
    }

    #[test]
    fn folders_do_not_predict_an_album_count_as_a_track_count() {
        let observed = state();
        let mut optimism = Optimism::default();
        let folder = MediaItem {
            id: "folder".into(),
            r#type: MediaItemType::Container as i32,
            name: Some("Favourite Albums".into()),
            child_count: Some(10),
            ..Default::default()
        };
        optimism.apply(
            "folder-1",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(folder),
            None,
            &observed,
        );
        let playing = optimism.snapshot(&observed).now_playing.unwrap();
        assert_eq!(playing.current_item.as_ref().map(title), Some("Old Song"));
        assert_eq!(playing.playlist.unwrap().total, None);
    }

    #[test]
    fn failed_replace_does_not_undo_newer_replace() {
        let observed = state();
        let mut optimism = Optimism::default();
        for (tag, title) in [("old", "Song A"), ("new", "Song B")] {
            let preview = MediaItem {
                id: tag.into(),
                r#type: MediaItemType::Track as i32,
                title: Some(title.into()),
                ..Default::default()
            };
            let effective = optimism.snapshot(&observed);
            optimism.apply(
                tag,
                "/V2/media/select",
                &json!({"queue":"replace"}),
                Some(preview),
                None,
                &effective,
            );
        }
        optimism.fail("old");
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Song B")
        );
    }

    #[test]
    fn failed_replace_allows_later_playlist_selection_to_confirm() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(10);
        let mut optimism = Optimism::default();
        let preview = MediaItem {
            id: "missing-album".into(),
            r#type: MediaItemType::Album as i32,
            child_count: Some(4),
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(preview),
            None,
            &observed,
        );
        assert!(optimism.replace_revision.is_some());
        optimism.fail("replace");
        assert!(optimism.replace_revision.is_none());

        optimism.apply(
            "select",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(2);
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue);
    }

    #[test]
    fn tapping_playing_row_while_another_tap_is_in_flight_stays_pending() {
        let observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "first",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        let effective = optimism.snapshot(&observed);
        optimism.apply(
            "second",
            "/V2/playlist/select",
            &json!({"index":1}),
            None,
            None,
            &effective,
        );
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().queue);
        optimism.fail("first");
        let snapshot = optimism.snapshot(&observed);
        assert_eq!(
            snapshot
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .current_index,
            Some(1)
        );
        assert!(snapshot.pending.unwrap().queue);
    }

    #[test]
    fn restarting_playing_song_waits_for_replaced_queue_revision() {
        let mut observed = state();
        let playing = observed.now_playing.as_mut().unwrap();
        playing.playlist.as_mut().unwrap().content_revision = Some(10);
        let preview = MediaItem {
            id: "same".into(),
            r#type: MediaItemType::Track as i32,
            title: Some("Old Song".into()),
            ..Default::default()
        };
        let mut optimism = Optimism::default();
        optimism.apply(
            "restart",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(preview),
            None,
            &observed,
        );
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().playback);
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(11);
        optimism.reconcile(&observed);
        assert!(optimism.current_item.is_none());
    }

    #[test]
    fn returning_to_original_row_waits_for_device_to_leave_and_return() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "first",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        optimism.apply(
            "second",
            "/V2/playlist/select",
            &json!({"index":1}),
            None,
            None,
            &observed,
        );
        optimism.acknowledged("second");
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().queue_index);
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(2);
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().queue_index);
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(1);
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue_index);
    }

    #[test]
    fn another_row_without_metadata_clears_the_previous_preview() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .items
            .push(PlaylistItem {
                index: 2,
                display_name: Some("Previous preview".into()),
                ..Default::default()
            });
        let mut optimism = Optimism::default();
        optimism.apply(
            "first",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Previous preview")
        );
        optimism.apply(
            "second",
            "/V2/playlist/select",
            &json!({"index":0}),
            None,
            None,
            &observed,
        );
        let snapshot = optimism.snapshot(&observed);
        assert!(snapshot.now_playing.unwrap().current_item.is_none());
        assert!(snapshot.pending.unwrap().current_item);
    }

    #[test]
    fn select_after_replace_uses_new_queue_bounds_and_no_old_row_preview() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .items
            .push(PlaylistItem {
                index: 1,
                display_name: Some("Old queue song".into()),
                ..Default::default()
            });
        let mut optimism = Optimism::default();
        let album = MediaItem {
            r#type: MediaItemType::Album as i32,
            child_count: Some(2),
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(album),
            None,
            &observed,
        );
        optimism.apply(
            "next",
            "/V2/playlist/select",
            &json!({"index":1}),
            None,
            None,
            &observed,
        );
        let snapshot = optimism.snapshot(&observed);
        let playing = snapshot.now_playing.unwrap();
        assert_eq!(playing.playlist.unwrap().current_index, Some(1));
        assert!(playing.current_item.is_none());
        assert!(snapshot.pending.unwrap().current_item);
        optimism.apply(
            "out-of-bounds",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .current_index,
            Some(1)
        );
    }

    #[test]
    fn pending_additions_extend_bounds_and_roll_back_independently() {
        let observed = state();
        let mut optimism = Optimism::default();
        let track = MediaItem {
            r#type: MediaItemType::Track as i32,
            ..Default::default()
        };
        optimism.apply(
            "first",
            "/V2/media/select",
            &json!({"queue":"next"}),
            Some(track.clone()),
            None,
            &observed,
        );
        optimism.apply(
            "second",
            "/V2/media/select",
            &json!({"queue":"last"}),
            Some(track),
            None,
            &observed,
        );
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(5)
        );
        optimism.apply(
            "select",
            "/V2/playlist/select",
            &json!({"index":4}),
            None,
            None,
            &observed,
        );
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .current_index,
            Some(4)
        );
        assert!(optimism.fail("first"));
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(4)
        );
        assert!(optimism.fail("second"));
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(3)
        );
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue_index);
    }

    #[test]
    fn shuffle_hides_old_timeline_until_song_changes() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "shuffle",
            "/V2/transport/skip_track",
            &json!({"shuffle":true}),
            None,
            None,
            &observed,
        );
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().timeline);
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .display_name = Some("New song".into());
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .track = None;
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().timeline);
    }

    #[test]
    fn unversioned_media_releases_on_a_new_nonblank_song() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        let preview = MediaItem {
            r#type: MediaItemType::Track as i32,
            title: Some("Expected".into()),
            ..Default::default()
        };
        optimism.apply(
            "media",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(preview),
            None,
            &observed,
        );
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .display_name = Some("Unexpected".into());
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .track = None;
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().current_item);
    }

    #[test]
    fn new_revision_ignores_superseded_and_blank_titles() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(10);
        let mut optimism = Optimism::default();
        for (tag, song) in [("a", "Song A"), ("b", "Song B")] {
            let preview = MediaItem {
                r#type: MediaItemType::Track as i32,
                title: Some(song.into()),
                ..Default::default()
            };
            optimism.apply(
                tag,
                "/V2/media/select",
                &json!({"queue":"replace"}),
                Some(preview),
                None,
                &observed,
            );
        }
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(11);
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .display_name = Some("Song A".into());
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .track = None;
        optimism.reconcile(&observed);
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Song B")
        );
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .display_name = Some(String::new());
        optimism.reconcile(&observed);
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Song B")
        );
    }

    #[test]
    fn deferred_select_keeps_inherited_baseline_until_first_command_fails() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "first",
            "/V2/playlist/select",
            &json!({"index":0}),
            None,
            None,
            &observed,
        );
        optimism.apply_deferred_select("second", &json!({"index":2}), &observed);
        optimism.fail("second");
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(0);
        optimism.apply_deferred_select("third", &json!({"index":1}), &observed);
        assert_eq!(optimism.queue_baseline_index, Some(1));
        optimism.reconcile(&observed);
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(1);
        optimism.reconcile(&observed);
        assert!(optimism.snapshot(&observed).pending.unwrap().queue_index);
        optimism.fail("first");
        optimism.promote_surviving_select(Some(1));
        optimism.acknowledged("third");
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue_index);
    }

    #[test]
    fn plain_select_without_metadata_keeps_observed_song() {
        let observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "row",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        let snapshot = optimism.snapshot(&observed);
        assert_eq!(
            snapshot
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Old Song")
        );
        assert!(!snapshot.pending.unwrap().current_item);
    }

    #[test]
    fn previewless_replace_avoids_old_queue_predictions() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .items
            .push(PlaylistItem {
                index: 2,
                display_name: Some("Old Row".into()),
                ..Default::default()
            });
        let mut optimism = Optimism::default();
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            None,
            None,
            &observed,
        );
        assert!(optimism.replace_has_unknown_size());
        let snapshot = optimism.snapshot(&observed);
        let playlist = snapshot.now_playing.unwrap().playlist.unwrap();
        assert_eq!(playlist.total, None);
        assert_eq!(playlist.current_index, None);
        let track = MediaItem {
            r#type: MediaItemType::Track as i32,
            ..Default::default()
        };
        optimism.apply(
            "add",
            "/V2/media/select",
            &json!({"queue":"next"}),
            Some(track),
            None,
            &observed,
        );
        assert!(optimism.queue_additions.is_none());
        optimism.apply(
            "row",
            "/V2/playlist/select",
            &json!({"index":2}),
            None,
            None,
            &observed,
        );
        assert_ne!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("Old Row")
        );
        assert_eq!(optimism.queue_baseline_index, None);
    }

    #[test]
    fn failed_select_restores_pending_replace_prediction() {
        let observed = state();
        let mut optimism = Optimism::default();
        let album = MediaItem {
            r#type: MediaItemType::Album as i32,
            child_count: Some(2),
            ..Default::default()
        };
        let first_track = MediaItem {
            r#type: MediaItemType::Track as i32,
            title: Some("New Song".into()),
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(album),
            Some(first_track),
            &observed,
        );
        optimism.apply(
            "row",
            "/V2/playlist/select",
            &json!({"index":1}),
            None,
            None,
            &observed,
        );
        optimism.fail("row");
        let snapshot = optimism.snapshot(&observed);
        let playlist = snapshot
            .now_playing
            .as_ref()
            .unwrap()
            .playlist
            .as_ref()
            .unwrap();
        assert_eq!(playlist.current_index, Some(0));
        assert_eq!(playlist.total, Some(2));
        assert!(snapshot.pending.unwrap().queue_index);
        assert_eq!(
            snapshot
                .now_playing
                .unwrap()
                .current_item
                .as_ref()
                .map(title),
            Some("New Song")
        );
    }

    #[test]
    fn selecting_zero_during_replace_confirms_with_new_revision() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(10);
        let mut optimism = Optimism::default();
        let album = MediaItem {
            r#type: MediaItemType::Album as i32,
            child_count: Some(2),
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(album),
            None,
            &observed,
        );
        optimism.apply(
            "row",
            "/V2/playlist/select",
            &json!({"index":0}),
            None,
            None,
            &observed,
        );
        optimism.acknowledged("row");
        let playlist = observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap();
        playlist.content_revision = Some(11);
        playlist.total = Some(2);
        playlist.current_index = Some(0);
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue_index);
    }

    #[test]
    fn earlier_replace_revision_does_not_settle_newer_replace() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(10);
        let mut optimism = Optimism::default();
        for (tag, count) in [("first", 1), ("second", 2)] {
            let album = MediaItem {
                r#type: MediaItemType::Album as i32,
                child_count: Some(count),
                ..Default::default()
            };
            optimism.apply(
                tag,
                "/V2/media/select",
                &json!({"queue":"replace"}),
                Some(album),
                None,
                &observed,
            );
        }
        let playlist = observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap();
        playlist.content_revision = Some(11);
        playlist.total = Some(1);
        optimism.reconcile(&observed);
        assert_eq!(
            optimism
                .replace_revision
                .as_ref()
                .map(|pending| pending.tag.as_str()),
            Some("second")
        );
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(2)
        );
    }

    #[test]
    fn returning_to_a_superseded_title_can_confirm_without_revisions() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        for (tag, song) in [("a1", "Song A"), ("b", "Song B"), ("a2", "Song A")] {
            let preview = MediaItem {
                r#type: MediaItemType::Track as i32,
                title: Some(song.into()),
                ..Default::default()
            };
            optimism.apply(
                tag,
                "/V2/media/select",
                &json!({"queue":"replace"}),
                Some(preview),
                None,
                &observed,
            );
        }
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .track = None;
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .current_item
            .as_mut()
            .unwrap()
            .display_name = Some("Song A".into());
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().current_item);
    }

    #[test]
    fn failed_replace_rebases_later_addition_on_observed_queue() {
        let observed = state();
        let mut optimism = Optimism::default();
        let album = MediaItem {
            r#type: MediaItemType::Album as i32,
            child_count: Some(2),
            ..Default::default()
        };
        let track = MediaItem {
            r#type: MediaItemType::Track as i32,
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(album),
            None,
            &observed,
        );
        optimism.apply(
            "add",
            "/V2/media/select",
            &json!({"queue":"last"}),
            Some(track),
            None,
            &observed,
        );
        optimism.fail("replace");
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(4)
        );
        assert!(optimism.queue_additions.is_some());
    }

    #[test]
    fn cancelling_deferred_selection_restores_in_flight_prediction() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "first",
            "/V2/playlist/select",
            &json!({"index":0}),
            None,
            None,
            &observed,
        );
        optimism.apply_deferred_select("second", &json!({"index":2}), &observed);
        assert_eq!(
            optimism.queue_index.as_ref().map(|pending| pending.value),
            Some(2)
        );
        assert!(optimism.fail("second"));
        assert_eq!(
            optimism.queue_index.as_ref().map(|pending| pending.value),
            Some(0)
        );
        assert_eq!(optimism.queue_baseline_index, Some(1));
        assert!(optimism.queue_baseline_direct);
        optimism.acknowledged("first");
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(0);
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue_index);
    }

    #[test]
    fn repeating_pending_target_keeps_confirmation_baseline() {
        let mut observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "first",
            "/V2/playlist/select",
            &json!({"index":0}),
            None,
            None,
            &observed,
        );
        optimism.acknowledged("first");
        optimism.apply(
            "second",
            "/V2/playlist/select",
            &json!({"index":0}),
            None,
            None,
            &observed,
        );
        assert!(optimism.queue_baseline_direct);
        assert!(optimism.queue_index.as_ref().unwrap().saw_different_value);
        optimism.acknowledged("second");
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .current_index = Some(0);
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().queue_index);
    }

    #[test]
    fn unknown_replace_skip_does_not_use_old_queue_index() {
        let observed = state();
        let mut optimism = Optimism::default();
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            None,
            None,
            &observed,
        );
        let pending = optimism.snapshot(&observed).pending.unwrap();
        assert!(pending.queue && pending.queue_index && pending.queue_total);
        optimism.apply(
            "skip",
            "/V2/transport/skip_track",
            &json!({"skip_track":1}),
            None,
            None,
            &observed,
        );
        let snapshot = optimism.snapshot(&observed);
        assert_eq!(
            snapshot
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .current_index,
            None
        );
        assert!(snapshot.pending.unwrap().timeline);
        assert!(optimism.fail("replace"));
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(3)
        );
    }

    #[test]
    fn changed_revision_settles_replace_when_provider_count_was_wrong() {
        let mut observed = state();
        let playlist = observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap();
        playlist.content_revision = Some(10);
        let mut optimism = Optimism::default();
        let album = MediaItem {
            r#type: MediaItemType::Album as i32,
            child_count: Some(4),
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(album),
            None,
            &observed,
        );
        let playlist = observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap();
        playlist.content_revision = Some(11);
        playlist.total = Some(2);
        optimism.reconcile(&observed);
        assert!(optimism.replace_revision.is_none());
        assert_eq!(
            optimism
                .snapshot(&observed)
                .now_playing
                .unwrap()
                .playlist
                .unwrap()
                .total,
            Some(2)
        );
    }

    #[test]
    fn old_row_title_can_start_the_new_replaced_queue() {
        let mut observed = state();
        observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap()
            .content_revision = Some(10);
        let mut optimism = Optimism::default();
        let track = MediaItem {
            r#type: MediaItemType::Track as i32,
            title: Some("New Song".into()),
            ..Default::default()
        };
        optimism.apply(
            "replace",
            "/V2/media/select",
            &json!({"queue":"replace"}),
            Some(track),
            None,
            &observed,
        );
        optimism.add_superseded_titles(vec!["Old Row Song".into()]);
        let playing = observed.now_playing.as_mut().unwrap();
        playing.current_item.as_mut().unwrap().display_name = Some("Old Row Song".into());
        playing.current_item.as_mut().unwrap().track = None;
        let playlist = playing.playlist.as_mut().unwrap();
        playlist.content_revision = Some(11);
        playlist.total = Some(1);
        playlist.current_index = Some(0);
        playlist.items = vec![PlaylistItem {
            index: 0,
            display_name: Some("Old Row Song".into()),
            ..Default::default()
        }];
        optimism.reconcile(&observed);
        assert!(!optimism.snapshot(&observed).pending.unwrap().current_item);
    }
}
