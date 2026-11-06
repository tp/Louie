use super::*;
use crate::pb::{
    CurrentItem, NowPlayingState, Playlist, PlaylistItem, RoomVolume, Timeline, Track,
    TransportState,
};

struct Script {
    scheduler: Scheduler<&'static str>,
    observed: StateSnapshot,
    now: Instant,
}
fn song(index: i32) -> CurrentItem {
    let name = format!("Song {index}");
    CurrentItem {
        id: name.clone(),
        display_name: Some(name.clone()),
        track: Some(Track {
            title: Some(name),
            ..Track::default()
        }),
        ..CurrentItem::default()
    }
}
impl Script {
    fn new() -> Self {
        Self {
            scheduler: Scheduler::default(),
            now: Instant::now(),
            observed: StateSnapshot {
                now_playing: Some(NowPlayingState {
                    current_item: Some(song(0)),
                    transport_state: Some(TransportState::Playing as i32),
                    playlist: Some(Playlist {
                        current_index: Some(0),
                        total: Some(4),
                        content_revision: Some(1),
                        items: (0..4)
                            .map(|index| PlaylistItem {
                                index,
                                display_name: song(index).display_name,
                                ..PlaylistItem::default()
                            })
                            .collect(),
                    }),
                    timeline: Some(Timeline {
                        position_seconds: Some(40),
                        duration_seconds: Some(200),
                        is_seekable: Some(true),
                        ..Timeline::default()
                    }),
                    room_volume: Some(RoomVolume {
                        volume: Some(10),
                        is_muted: Some(false),
                        maximum_volume: 70,
                    }),
                    ..NowPlayingState::default()
                }),
                ..StateSnapshot::default()
            },
        }
    }
    fn enqueue(&mut self, tag: &'static str, command: Command) {
        self.scheduler
            .enqueue(tag.into(), command, tag, &self.observed, self.now);
    }
    fn send(&mut self) -> Vec<&'static str> {
        self.scheduler
            .dispatch(&self.observed, self.now)
            .into_iter()
            .map(|(_, tag)| tag)
            .collect()
    }
    fn ack(&mut self, tag: &str) {
        self.scheduler.acknowledge(tag, self.now);
    }
    fn view(&self) -> StateSnapshot {
        self.scheduler.snapshot(&self.observed)
    }
    fn playlist(&mut self, index: i32, revision: i64, total: i32) {
        let q = self
            .observed
            .now_playing
            .as_mut()
            .unwrap()
            .playlist
            .as_mut()
            .unwrap();
        q.current_index = Some(index);
        q.content_revision = Some(revision);
        q.total = Some(total);
        self.scheduler
            .observe("/V2/playlist/subscribe", &self.observed);
    }
    fn metadata(&mut self, index: i32) {
        self.observed.now_playing.as_mut().unwrap().current_item = Some(song(index));
        self.scheduler
            .observe("/V2/metadata/status", &self.observed);
    }
    fn position(&mut self, position: i32) {
        self.observed
            .now_playing
            .as_mut()
            .unwrap()
            .timeline
            .as_mut()
            .unwrap()
            .position_seconds = Some(position);
        self.scheduler.observe("/V2/seek/status", &self.observed);
    }
    fn transport(&mut self, value: i32) {
        self.observed.now_playing.as_mut().unwrap().transport_state = Some(value);
        self.scheduler
            .observe("/V2/transport/status", &self.observed);
    }
    fn settle_row(&mut self, tag: &str, index: i32) {
        self.ack(tag);
        self.playlist(index, 1, 4);
        self.metadata(index);
        self.position(0);
    }
}
fn album(name: i32, count: Option<i32>) -> Command {
    Command::Media {
        placement: "replace".into(),
        count,
        preview: Some(song(name)),
    }
}
fn addition(placement: &str, count: Option<i32>) -> Command {
    Command::Media {
        placement: placement.into(),
        count,
        preview: None,
    }
}

#[test]
fn row_and_double_skip_wait_for_each_fields_own_evidence() {
    let mut s = Script::new();
    s.enqueue("first", Command::Select(1));
    assert_eq!(s.send(), ["first"]);
    s.enqueue("next", Command::Select(2));
    s.ack("first");
    assert!(s.send().is_empty());
    s.playlist(1, 1, 4);
    assert_eq!(
        s.view()
            .now_playing
            .unwrap()
            .current_item
            .unwrap()
            .display_name,
        song(2).display_name
    );
    assert!(s.send().is_empty());
    s.metadata(1);
    s.position(0);
    assert_eq!(s.send(), ["next"]);
    s.ack("next");
    s.playlist(2, 1, 4);
    let view = s.view();
    assert_eq!(
        view.now_playing.unwrap().current_item.unwrap().display_name,
        song(2).display_name
    );
    assert!(!view.pending.as_ref().unwrap().queue_index);
    assert!(view.pending.unwrap().current_item);
    s.metadata(2);
    s.position(0);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn unrelated_events_never_confirm_cached_metadata_and_evidence_can_precede_ack() {
    let mut s = Script::new();
    s.enqueue("a", Command::Select(1));
    s.send();
    s.playlist(1, 1, 4);
    s.position(0);
    assert!(s.view().pending.unwrap().current_item);
    s.metadata(1);
    s.position(0);
    s.enqueue("b", Command::Select(2));
    assert!(s.send().is_empty());
    s.ack("a");
    assert_eq!(s.send(), ["b"]);
}

#[test]
fn a_b_a_sends_a_once_and_cancels_b() {
    let mut s = Script::new();
    s.enqueue("a", Command::Select(1));
    s.send();
    s.enqueue("b", Command::Select(2));
    s.enqueue("a-again", Command::Select(1));
    let done = s.scheduler.take_completed();
    assert_eq!(done[0].0, "b");
    assert_eq!(
        done[0].1.as_ref().unwrap_err().code(),
        tonic::Code::Cancelled
    );
    s.settle_row("a", 1);
    assert!(s.send().is_empty());
    assert_eq!(s.scheduler.take_completed()[0].0, "a-again");
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn additions_are_preserved_and_latest_transport_does_not_discard_album() {
    let mut s = Script::new();
    s.enqueue("album", album(10, Some(10)));
    s.send();
    s.enqueue("next", addition("next", Some(3)));
    s.enqueue("last", addition("last", Some(5)));
    s.enqueue("play", Command::Transport(TransportState::Playing as i32));
    s.enqueue("pause", Command::Transport(TransportState::Paused as i32));
    assert_eq!(
        s.view().now_playing.unwrap().playlist.unwrap().total,
        Some(18)
    );
    assert_eq!(s.scheduler.take_completed()[0].0, "play");
    s.ack("album");
    s.playlist(0, 2, 10);
    s.metadata(10);
    s.transport(TransportState::Playing as i32);
    s.position(0);
    assert_eq!(s.send(), ["next"]);
    s.ack("next");
    s.playlist(0, 3, 13);
    assert_eq!(s.send(), ["last"]);
    s.ack("last");
    s.playlist(0, 4, 18);
    assert_eq!(s.send(), ["pause"]);
    s.ack("pause");
    s.transport(TransportState::Paused as i32);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn replace_during_replace_and_row_selection_use_dispatch_baseline() {
    let mut s = Script::new();
    s.enqueue("a", album(10, Some(10)));
    s.send();
    s.enqueue("b", album(20, Some(8)));
    s.enqueue("c", album(30, Some(6)));
    s.enqueue("row", Command::Select(2));
    assert_eq!(s.scheduler.take_completed()[0].0, "b");
    // A pending replacement must never borrow row metadata from the old queue.
    assert!(s.view().now_playing.unwrap().current_item.is_none());
    s.ack("a");
    s.playlist(0, 2, 10);
    s.metadata(10);
    s.transport(TransportState::Playing as i32);
    s.position(0);
    assert_eq!(s.send(), ["c"]);
    // Old A status cannot settle C's queue change against its dispatch baseline.
    s.ack("c");
    s.playlist(0, 2, 10);
    assert!(s.send().is_empty());
    s.playlist(0, 3, 6);
    s.metadata(30);
    s.transport(TransportState::Playing as i32);
    s.position(0);
    assert_eq!(s.send(), ["row"]);
}

#[test]
fn wrong_or_missing_child_count_yields_to_actual_queue() {
    for count in [None, Some(99)] {
        let mut s = Script::new();
        s.enqueue("album", album(10, count));
        s.send();
        s.ack("album");
        s.playlist(0, 2, 7);
        s.metadata(10);
        s.transport(TransportState::Playing as i32);
        s.position(0);
        assert_eq!(
            s.view().now_playing.unwrap().playlist.unwrap().total,
            Some(7)
        );
        if count == Some(99) {
            assert!(s.view().pending.unwrap().queue);
            s.now += Duration::from_secs(7);
            assert!(s.scheduler.tick(s.now));
        }
        assert_eq!(s.view().pending, Some(PendingState::default()));
    }
}

#[test]
fn seek_is_bound_to_selected_track_and_waiting_seeks_coalesce() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    s.enqueue("seek1", Command::Seek(20));
    s.enqueue("seek2", Command::Seek(50));
    assert_eq!(s.scheduler.take_completed()[0].0, "seek1");
    s.settle_row("row", 1);
    assert_eq!(s.send(), ["seek2"]);
    s.ack("seek2");
    s.position(10);
    assert!(s.view().pending.unwrap().timeline);
    s.position(49);
    assert!(!s.view().pending.unwrap().timeline);
}

#[test]
fn failure_cancels_dependent_seek_and_never_restores_an_expired_prediction() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    s.enqueue("seek", Command::Seek(20));
    s.scheduler.reject("row");
    assert_eq!(s.scheduler.take_completed()[0].0, "seek");
    assert!(s.send().is_empty());
    assert_eq!(s.view().now_playing, s.observed.now_playing);
    s.now += Duration::from_secs(30);
    s.scheduler.tick(s.now);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn timeout_refreshes_before_dispatch_and_late_frames_remain_observed_truth() {
    let mut s = Script::new();
    s.enqueue("a", Command::Select(1));
    s.send();
    s.ack("a");
    s.enqueue("b", Command::Select(2));
    s.now += Duration::from_secs(4);
    assert!(s.scheduler.tick(s.now));
    assert!(s.send().is_empty());
    s.playlist(1, 1, 4);
    s.metadata(1); // A completed late during read-back.
    s.scheduler.refreshed();
    assert_eq!(s.send(), ["b"]);
    s.ack("b");
    s.playlist(1, 1, 4);
    s.metadata(1); // baseline from dispatch
    assert!(s.view().pending.unwrap().current_item);
    s.now += Duration::from_secs(4);
    assert!(s.scheduler.tick(s.now));
    assert_eq!(s.view().now_playing, s.observed.now_playing);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn volume_and_mute_do_not_wait_for_playback_and_only_latest_volume_is_sent() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.enqueue("v1", Command::Volume(20, false));
    assert_eq!(s.send(), ["row", "v1"]);
    s.enqueue("v2", Command::Volume(30, false));
    s.enqueue("v3", Command::Volume(40, false));
    s.enqueue("mute", Command::Mute(true, false));
    assert_eq!(s.send(), ["mute"]);
    s.ack("v1");
    assert_eq!(s.send(), ["v3"]);
    let done = s.scheduler.take_completed();
    assert_eq!(done[0].0, "v2");
    s.observed
        .now_playing
        .as_mut()
        .unwrap()
        .room_volume
        .as_mut()
        .unwrap()
        .volume = Some(40);
    s.scheduler.observe("mute", &s.observed);
    assert!(s.view().pending.unwrap().volume);
    s.scheduler.observe("volume", &s.observed);
    assert!(!s.view().pending.unwrap().volume);
}

#[test]
fn queue_bound_wait_deadline_and_standby_clear_pending_work() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    for _ in 0..MAX_WAITING {
        s.enqueue("add", addition("last", Some(1)));
    }
    s.enqueue("overflow", addition("last", Some(1)));
    assert_eq!(
        s.scheduler.take_completed()[0]
            .1
            .as_ref()
            .unwrap_err()
            .code(),
        tonic::Code::ResourceExhausted
    );
    s.now += WAIT_LIMIT;
    s.scheduler.tick(s.now);
    assert_eq!(s.scheduler.take_completed().len(), MAX_WAITING);
    s.enqueue("pause", Command::Transport(TransportState::Paused as i32));
    s.scheduler.clear();
    assert_eq!(s.scheduler.take_completed()[0].0, "pause");
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn changed_queue_invalidates_waiting_row_and_seek_targets() {
    let mut s = Script::new();
    s.enqueue("pause", Command::Transport(TransportState::Paused as i32));
    s.send();
    s.enqueue("row", Command::Select(2));
    s.playlist(0, 2, 1);
    s.ack("pause");
    s.transport(TransportState::Paused as i32);
    assert!(s.send().is_empty());
    assert!(s.scheduler.take_completed()[0].1.is_err());
}

#[test]
fn shuffle_and_missing_revision_eventually_expire_without_inventing_a_song() {
    let mut s = Script::new();
    s.enqueue("shuffle", Command::Skip);
    s.send();
    s.ack("shuffle");
    assert!(s.view().now_playing.unwrap().current_item.is_none());
    s.playlist(3, 1, 4);
    s.metadata(3);
    s.position(0);
    assert_eq!(s.view().pending, Some(PendingState::default()));
    s.observed
        .now_playing
        .as_mut()
        .unwrap()
        .playlist
        .as_mut()
        .unwrap()
        .content_revision = None;
    s.enqueue("album", album(10, None));
    s.send();
    s.ack("album");
    s.now += Duration::from_secs(7);
    assert!(s.scheduler.tick(s.now));
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn failed_replacement_cancels_dependencies_across_pause_and_additions() {
    let mut s = Script::new();
    s.enqueue("album", album(10, Some(10)));
    s.send();
    s.enqueue("pause", Command::Transport(TransportState::Paused as i32));
    s.enqueue("add", addition("last", Some(2)));
    s.enqueue("row", Command::Select(2));
    s.enqueue("seek", Command::Seek(20));
    s.scheduler.reject("album");
    let done: Vec<_> = s
        .scheduler
        .take_completed()
        .into_iter()
        .map(|(tag, _)| tag)
        .collect();
    assert_eq!(done, ["row", "seek"]);
    assert_eq!(s.send(), ["pause"]);
}

#[test]
fn invalidated_row_also_cancels_its_seek() {
    let mut s = Script::new();
    s.enqueue("pause", Command::Transport(TransportState::Paused as i32));
    s.send();
    s.enqueue("row", Command::Select(3));
    s.enqueue("seek", Command::Seek(100));
    s.ack("pause");
    s.playlist(0, 2, 2);
    s.transport(TransportState::Paused as i32);
    assert!(s.send().is_empty());
    let done: Vec<_> = s
        .scheduler
        .take_completed()
        .into_iter()
        .map(|(tag, _)| tag)
        .collect();
    assert_eq!(done, ["row", "seek"]);
}

#[test]
fn seek_evidence_can_arrive_before_metadata_without_blocking_the_lane() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    s.ack("row");
    s.position(0);
    s.playlist(1, 1, 4);
    s.metadata(1);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn album_start_holds_playing_through_old_transport_and_loading_frames() {
    let mut s = Script::new();
    s.enqueue("album", album(10, Some(10)));
    s.send();
    s.ack("album");
    s.transport(TransportState::Playing as i32); // Still the old song.
    s.transport(TransportState::Stopped as i32);
    assert_eq!(
        s.view().now_playing.unwrap().transport_state,
        Some(TransportState::Playing as i32)
    );
    s.playlist(0, 2, 10);
    s.metadata(10);
    s.position(0);
    assert!(s.view().pending.unwrap().transport);
    s.transport(TransportState::Playing as i32);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn old_song_position_tick_is_not_seek_evidence_for_the_new_song() {
    for command in [
        Command::Select(1),
        album(1, Some(4)),
        Command::Media {
            placement: "now".into(),
            count: Some(1),
            preview: Some(song(1)),
        },
    ] {
        let mut s = Script::new();
        s.enqueue("change", command);
        assert_eq!(s.send(), ["change"]);
        s.position(41);
        s.ack("change");
        s.playlist(1, 2, 5);
        s.metadata(1);
        let view = s.view();
        assert!(
            view.pending.unwrap().timeline,
            "old song progress must not settle the new song"
        );
        assert!(view.now_playing.unwrap().timeline.is_none());
    }
}

#[test]
fn old_tick_after_reset_does_not_reuse_stale_seek_evidence() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    s.position(0);
    s.position(41);
    s.ack("row");
    s.playlist(1, 2, 4);
    s.metadata(1);
    assert!(s.view().pending.unwrap().timeline);
    s.position(0);
    assert!(!s.view().pending.unwrap().timeline);
}
