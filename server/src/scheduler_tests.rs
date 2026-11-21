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
        duration: None,
    }
}
fn addition(placement: &str, count: Option<i32>) -> Command {
    Command::Media {
        placement: placement.into(),
        count,
        preview: None,
        duration: None,
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
    s.now += Duration::from_secs(6);
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
    s.now += Duration::from_secs(6);
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
            duration: None,
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
    s.position(42); // Continuing old-song progress must not re-anchor evidence.
    s.ack("row");
    s.playlist(1, 2, 4);
    s.metadata(1);
    assert!(s.view().pending.unwrap().timeline);
    s.position(0);
    assert!(!s.view().pending.unwrap().timeline);
}

#[test]
fn delayed_playlist_confirmation_does_not_trigger_read_back() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    s.ack("row");
    s.metadata(1);
    s.position(2);
    s.now += Duration::from_millis(3250);
    assert!(!s.scheduler.tick(s.now));
    assert!(s.view().pending.unwrap().queue_index);
    s.playlist(1, 2, 4);
    assert_eq!(s.view().pending, Some(PendingState::default()));
    s.enqueue("next", Command::Select(2));
    assert_eq!(s.send(), ["next"]);
}

#[test]
fn review_delayed_playlist_retains_continuous_new_song_progress() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    s.send();
    s.ack("row");
    s.transport(TransportState::Playing as i32);
    s.metadata(1);
    s.position(2);
    s.now += Duration::from_millis(1000);
    s.position(3);
    s.now += Duration::from_millis(2250);
    s.playlist(1, 2, 4);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn review_seek_after_row_survives_delayed_playlist() {
    let mut s = Script::new();
    s.enqueue("row", Command::Select(1));
    assert_eq!(s.send(), ["row"]);
    s.enqueue("seek", Command::Seek(60));
    s.ack("row");
    s.transport(TransportState::Playing as i32);
    s.metadata(1);
    for position in 0..=3 {
        s.position(position);
        s.now += Duration::from_secs(1);
    }
    s.playlist(1, 2, 4);
    s.position(4);
    s.now += Duration::from_secs(1);
    assert!(!s.scheduler.tick(s.now));
    assert!(s.scheduler.take_completed().is_empty());
    assert_eq!(s.send(), ["seek"]);
}

#[test]
fn paused_track_changes_predict_playing_until_transport_confirms() {
    for command in [Command::Select(1), Command::Skip] {
        let mut s = Script::new();
        s.transport(TransportState::Paused as i32);
        s.enqueue("next", command);
        assert_eq!(
            s.view().now_playing.unwrap().transport_state,
            Some(TransportState::Playing as i32)
        );
        assert_eq!(s.send(), ["next"]);
        s.ack("next");
        for state in [
            TransportState::Paused,
            TransportState::Stopped,
            TransportState::Buffering,
        ] {
            s.transport(state as i32);
            assert_eq!(
                s.view().now_playing.unwrap().transport_state,
                Some(TransportState::Playing as i32)
            );
        }
        s.playlist(1, 2, 4);
        s.metadata(1);
        s.position(0);
        assert!(s.view().pending.unwrap().transport);
        s.transport(TransportState::Playing as i32);
        assert_eq!(s.view().pending, Some(PendingState::default()));
    }
}

#[test]
fn rejected_paused_track_change_restores_observed_transport() {
    let mut s = Script::new();
    s.transport(TransportState::Paused as i32);
    s.enqueue("next", Command::Select(1));
    s.send();
    assert_eq!(
        s.view().now_playing.unwrap().transport_state,
        Some(TransportState::Playing as i32)
    );
    s.scheduler.reject("next");
    assert_eq!(s.view().now_playing, s.observed.now_playing);
    assert_eq!(s.view().pending, Some(PendingState::default()));
}

#[test]
fn review_row_tap_while_playing_settles_without_a_repeated_play_frame() {
    let mut s = Script::new(); // Linn is already playing Song 0.
    s.enqueue("row", Command::Select(1));
    assert_eq!(s.send(), ["row"]);
    s.enqueue("seek", Command::Seek(60));
    s.ack("row");
    // Transport never left "play", so Linn has no transport change to push.
    s.playlist(1, 2, 4);
    s.metadata(1);
    s.position(0);
    assert!(
        !s.view().pending.unwrap().transport,
        "row tap while playing is still waiting for a transport frame"
    );
    s.now += Duration::from_secs(5);
    assert!(
        !s.scheduler.tick(s.now),
        "confirmed row tap timed out into a read-back"
    );
    let failed: Vec<_> = s
        .scheduler
        .take_completed()
        .into_iter()
        .map(|(tag, result)| (tag, result.err().map(|e| e.message().to_owned())))
        .collect();
    assert!(failed.is_empty(), "seek was failed: {failed:?}");
    assert_eq!(s.send(), ["seek"]);
}
#[test]
fn review_double_skip_while_playing_dispatches_second_skip_on_track_evidence() {
    let mut s = Script::new(); // Linn is already playing Song 0.
    s.enqueue("first", Command::Select(1));
    assert_eq!(s.send(), ["first"]);
    s.enqueue("second", Command::Select(2));
    s.ack("first");
    s.playlist(1, 2, 4);
    s.metadata(1);
    s.position(0);
    assert_eq!(
        s.send(),
        ["second"],
        "second skip is held behind a transport frame Linn does not send"
    );
}

#[test]
fn review_double_skip_does_not_show_previous_songs_progress_for_next_song() {
    // Double skip, and two row taps in quick succession.
    for (first, second) in [
        (Command::Skip, Command::Skip),
        (Command::Select(1), Command::Select(2)),
    ] {
        let mut s = Script::new();
        s.enqueue("first", first);
        assert_eq!(s.send(), ["first"]);
        s.enqueue("second", second);
        // Song 1 starts and settles the first change at its reset sample.
        s.ack("first");
        s.transport(TransportState::Playing as i32);
        s.playlist(1, 1, 4);
        s.metadata(1);
        s.position(0);
        assert_eq!(s.send(), ["second"]);
        s.ack("second");
        // Linn takes ~3 s to change track; song 1 keeps ticking meanwhile.
        for position in 1..=3 {
            s.position(position);
        }
        s.transport(TransportState::Playing as i32);
        s.playlist(2, 1, 4);
        s.metadata(2);
        // Song 2 is confirmed, but no song-2 seek sample has arrived yet.
        let view = s.view();
        assert!(
            view.pending.unwrap().timeline,
            "song 1's progress (0:03) must not be published as song 2's timeline"
        );
        assert!(view.now_playing.unwrap().timeline.is_none());
    }
}

// A pending track change shows the destination's known length, never a position.
fn timed_rows(s: &mut Script) {
    let queue = s.observed.now_playing.as_mut().unwrap().playlist.as_mut();
    for row in &mut queue.unwrap().items {
        row.duration_seconds = Some(200 + row.index * 15);
    }
}
fn shown_timeline(s: &Script) -> Option<Timeline> {
    s.view().now_playing.unwrap().timeline
}
fn length_only(seconds: i32) -> Option<Timeline> {
    Some(Timeline {
        duration_seconds: Some(seconds),
        ..Timeline::default()
    })
}

#[test]
fn pending_row_shows_its_known_duration_without_a_position() {
    for (command, expected) in [
        (Command::Select(1), length_only(215)),
        (Command::Skip, None),
    ] {
        let mut s = Script::new();
        timed_rows(&mut s);
        s.enqueue("change", command);
        assert_eq!(s.send(), ["change"]);
        let view = s.view();
        assert!(view.pending.unwrap().timeline);
        // A shuffle/unknown skip has no known destination, so no length either.
        assert_eq!(
            view.now_playing.unwrap().timeline,
            expected,
            "the pending row must show its length without the old song's position"
        );
    }
}

#[test]
fn linn_duration_and_position_replace_the_rows_duration_on_release() {
    let mut s = Script::new();
    timed_rows(&mut s);
    s.enqueue("row", Command::Select(1));
    s.send();
    s.ack("row");
    s.metadata(1);
    // Linn's own length for the new song differs from the queue row's.
    let linn = Some(Timeline {
        position_seconds: Some(0),
        duration_seconds: Some(214),
        is_seekable: Some(true),
        seek_lower_bound_seconds: Some(0),
        seek_upper_bound_seconds: Some(214),
        ..Timeline::default()
    });
    s.observed.now_playing.as_mut().unwrap().timeline = linn;
    s.scheduler.observe("/V2/seek/status", &s.observed);
    assert_eq!(
        shown_timeline(&s),
        length_only(215),
        "the row's length is shown until the queue index confirms"
    );
    s.playlist(1, 2, 4);
    let view = s.view();
    assert!(!view.pending.unwrap().timeline);
    assert_eq!(view.now_playing.unwrap().timeline, linn);
}

#[test]
fn expired_track_change_drops_the_predicted_duration() {
    let mut s = Script::new();
    timed_rows(&mut s);
    s.enqueue("row", Command::Select(1));
    s.send();
    s.ack("row");
    assert_eq!(shown_timeline(&s), length_only(215));
    s.now += TRACK_SETTLE_LIMIT;
    assert!(s.scheduler.tick(s.now));
    let view = s.view();
    assert_eq!(view.pending, Some(PendingState::default()));
    assert_eq!(
        view.now_playing.unwrap().timeline,
        s.observed.now_playing.unwrap().timeline
    );
}

#[test]
fn waiting_row_projects_its_own_duration() {
    let mut s = Script::new();
    timed_rows(&mut s);
    s.enqueue("one", Command::Select(1));
    s.send();
    s.enqueue("two", Command::Select(2));
    let playing = s.view().now_playing.unwrap();
    assert_eq!(
        playing.current_item.unwrap().display_name,
        song(2).display_name
    );
    assert_eq!(playing.timeline, length_only(230));
}

#[test]
fn immediate_media_projects_the_first_tracks_duration() {
    use crate::pb::{MediaItem, MediaItemType};
    let track = MediaItem {
        id: "t1".into(),
        r#type: MediaItemType::Track as i32,
        title: Some("Opening".into()),
        duration_seconds: Some(181),
        ..MediaItem::default()
    };
    let album = MediaItem {
        id: "a1".into(),
        r#type: MediaItemType::Album as i32,
        title: Some("Album".into()),
        child_count: Some(10),
        ..MediaItem::default()
    };
    // Album replacement with its browsed first track, and a track played now.
    for (queue, preview, first) in [("replace", &album, Some(&track)), ("now", &track, None)] {
        let command = Command::from_request(
            "/V2/media/select",
            &serde_json::json!({"queue": queue}),
            Some(preview),
            first,
        )
        .unwrap();
        let mut s = Script::new();
        s.enqueue("media", command);
        assert_eq!(s.send(), ["media"]);
        let playing = s.view().now_playing.unwrap();
        assert_eq!(
            playing.current_item.unwrap().display_name.as_deref(),
            Some("Opening")
        );
        assert_eq!(playing.timeline, length_only(181), "{queue}");
    }
}

#[test]
fn unexpected_song_does_not_inherit_the_predicted_rows_duration() {
    let mut s = Script::new();
    timed_rows(&mut s);
    s.enqueue("row", Command::Select(1));
    s.send();
    s.ack("row");
    // Linn may repeat the expected song's metadata; it keeps the length.
    s.metadata(1);
    s.metadata(1);
    assert_eq!(shown_timeline(&s), length_only(215));
    // Another controller reordered the queue: Linn starts Song 3 for row 1.
    s.metadata(3);
    let view = s.view();
    assert!(view.pending.unwrap().timeline);
    let playing = view.now_playing.unwrap();
    assert_eq!(
        playing.current_item.unwrap().display_name,
        song(3).display_name
    );
    assert_eq!(
        playing.timeline, None,
        "Song 3 is shown with row 1's length"
    );
}

#[test]
fn seek_waiting_behind_a_pending_row_shows_its_position_with_the_rows_duration() {
    let mut s = Script::new();
    timed_rows(&mut s);
    s.enqueue("row", Command::Select(1));
    assert_eq!(s.send(), ["row"]);
    // The seek applies to the new song once the row settles.
    s.enqueue("seek", Command::Seek(60));
    let view = s.view();
    assert!(view.pending.unwrap().timeline);
    let timeline = view.now_playing.unwrap().timeline.unwrap();
    assert_eq!(
        (timeline.position_seconds, timeline.duration_seconds),
        (Some(60), Some(215)),
        "the requested position is shown without the new song's length"
    );
}

// Linn reports each applied volume/mute value about a second late, in order.
fn report_volume(s: &mut Script, value: i32) {
    let room = s
        .observed
        .now_playing
        .as_mut()
        .unwrap()
        .room_volume
        .as_mut();
    room.unwrap().volume = Some(value);
    s.scheduler.observe("volume", &s.observed);
}
fn report_mute(s: &mut Script, value: bool) {
    let room = s
        .observed
        .now_playing
        .as_mut()
        .unwrap()
        .room_volume
        .as_mut();
    room.unwrap().is_muted = Some(value);
    s.scheduler.observe("mute", &s.observed);
}
fn shown_volume(s: &Script) -> (Option<i32>, bool) {
    let view = s.view();
    let volume = view.now_playing.unwrap().room_volume.unwrap().volume;
    (volume, view.pending.unwrap().volume)
}
fn shown_mute(s: &Script) -> (Option<bool>, bool) {
    let view = s.view();
    let muted = view.now_playing.unwrap().room_volume.unwrap().is_muted;
    (muted, view.pending.unwrap().mute)
}
fn send_acked(s: &mut Script, tag: &'static str, command: Command) {
    s.enqueue(tag, command);
    assert_eq!(s.send(), [tag]);
    s.ack(tag);
}

#[test]
fn late_volume_frame_does_not_confirm_the_latest_a_b_a_value() {
    let mut s = Script::new(); // volume 10
    send_acked(&mut s, "v20", Command::Volume(20, false));
    send_acked(&mut s, "v30", Command::Volume(30, false));
    send_acked(&mut s, "v20-again", Command::Volume(20, false));
    report_volume(&mut s, 20); // belongs to the first command
    assert_eq!(
        shown_volume(&s),
        (Some(20), true),
        "the first 20's late frame confirmed the final 20"
    );
    report_volume(&mut s, 30); // belongs to the second command
    assert_eq!(
        shown_volume(&s),
        (Some(20), true),
        "the superseded 30 was published after the user chose 20"
    );
    report_volume(&mut s, 20);
    assert_eq!(shown_volume(&s), (Some(20), false));
}

#[test]
fn late_volume_frames_are_matched_oldest_first() {
    let mut s = Script::new(); // volume 10
    for (tag, value) in [("a", 20), ("b", 30), ("a-again", 20), ("b-again", 30)] {
        send_acked(&mut s, tag, Command::Volume(value, false));
    }
    // Each late frame belongs to the oldest unreported command with its value.
    for late in [20, 30, 20] {
        report_volume(&mut s, late);
        assert_eq!(
            shown_volume(&s),
            (Some(30), true),
            "the late frame for {late} confirmed or replaced the final 30"
        );
    }
    report_volume(&mut s, 30);
    assert_eq!(shown_volume(&s), (Some(30), false));
}

#[test]
fn late_mute_frame_does_not_confirm_the_latest_a_b_a_value() {
    let mut s = Script::new(); // unmuted
    send_acked(&mut s, "mute", Command::Mute(true, false));
    send_acked(&mut s, "unmute", Command::Mute(false, false));
    send_acked(&mut s, "mute-again", Command::Mute(true, false));
    report_mute(&mut s, true);
    assert_eq!(shown_mute(&s), (Some(true), true));
    report_mute(&mut s, false);
    assert_eq!(
        shown_mute(&s),
        (Some(true), true),
        "the superseded unmute was published after the user muted"
    );
    report_mute(&mut s, true);
    assert_eq!(shown_mute(&s), (Some(true), false));
}

#[test]
fn volume_confirms_when_linn_skips_intermediate_reports() {
    let mut s = Script::new(); // volume 10
    send_acked(&mut s, "v20", Command::Volume(20, false));
    send_acked(&mut s, "v30", Command::Volume(30, false));
    send_acked(&mut s, "v40", Command::Volume(40, false));
    report_volume(&mut s, 40);
    assert_eq!(shown_volume(&s), (Some(40), false));
    // Drain rule for A→B→A with 60 never reported: the first 50 frame belongs
    // to the first 50 and does not confirm. Whether Linn pushes a second 50
    // after 50→60→50 is unmeasured; without one the lane shows 50, pending,
    // until SETTLE_LIMIT.
    send_acked(&mut s, "v50", Command::Volume(50, false));
    send_acked(&mut s, "v60", Command::Volume(60, false));
    send_acked(&mut s, "v50-again", Command::Volume(50, false));
    report_volume(&mut s, 50);
    assert_eq!(shown_volume(&s), (Some(50), true));
    report_volume(&mut s, 50);
    assert_eq!(shown_volume(&s), (Some(50), false));
}

#[test]
fn same_volume_and_mute_settle_on_ack_unless_an_older_value_is_unreported() {
    // Linn does not push an unchanged value (PlayerBar re-sends the current
    // volume when its popover closes).
    let mut s = Script::new(); // volume 10, unmuted, already reported by Linn
    send_acked(&mut s, "same-volume", Command::Volume(10, false));
    send_acked(&mut s, "same-mute", Command::Mute(false, false));
    let pending = s.view().pending.unwrap();
    assert!(
        !pending.volume && !pending.mute,
        "a same-value command stays pending until its 3 s timeout"
    );
    // Returning to the reported value while 20 is still unreported does wait.
    send_acked(&mut s, "v20", Command::Volume(20, false));
    send_acked(&mut s, "v10", Command::Volume(10, false));
    assert_eq!(shown_volume(&s), (Some(10), true));
    report_volume(&mut s, 20);
    assert_eq!(shown_volume(&s), (Some(10), true));
    report_volume(&mut s, 10);
    assert_eq!(shown_volume(&s), (Some(10), false));
}

#[test]
fn repeated_volume_confirms_on_its_single_frame() {
    let mut s = Script::new(); // volume 10
    send_acked(&mut s, "v30", Command::Volume(30, false));
    // The Lock Screen slider rounds several levels to the same step, so the
    // same value can be sent again before Linn reports the first one.
    send_acked(&mut s, "v30-again", Command::Volume(30, false));
    // Linn applied 30 twice but pushes the unchanged value only once.
    report_volume(&mut s, 30);
    assert_eq!(
        shown_volume(&s),
        (Some(30), false),
        "a repeated value waits for a frame Linn never sends"
    );
    // Another controller turns the volume within the settle window.
    report_volume(&mut s, 45);
    assert_eq!(
        shown_volume(&s),
        (Some(45), false),
        "another controller's change is hidden"
    );
}

#[test]
fn repeated_mute_confirms_on_its_single_frame() {
    let mut s = Script::new(); // unmuted
    send_acked(&mut s, "mute", Command::Mute(true, false));
    send_acked(&mut s, "mute-again", Command::Mute(true, false));
    report_mute(&mut s, true);
    assert_eq!(
        shown_mute(&s),
        (Some(true), false),
        "a repeated mute waits for a frame Linn never sends"
    );
}

#[test]
fn coalesced_a_b_a_volume_burst_confirms_on_linns_single_frame() {
    // The volume analog of pause→play→pause: 30 is in flight, the knob goes
    // to 31 and back to 30, the waiting 31 is superseded and 30 is sent twice.
    let mut s = Script::new(); // volume 10
    s.enqueue("v30", Command::Volume(30, false));
    assert_eq!(s.send(), ["v30"]);
    s.enqueue("v31", Command::Volume(31, false));
    s.enqueue("v30-again", Command::Volume(30, false));
    s.ack("v30");
    assert_eq!(s.send(), ["v30-again"]);
    s.ack("v30-again");
    report_volume(&mut s, 30);
    assert_eq!(
        shown_volume(&s),
        (Some(30), false),
        "Linn's only frame for 30 left the lane pending until the 3 s expiry"
    );
}

#[test]
fn a_b_a_drag_ending_on_a_repeated_value_confirms_on_its_single_frame() {
    let mut s = Script::new(); // volume 10
    // The knob goes 20→30→20 and the slider sends the final step twice.
    for (tag, value) in [("a", 20), ("b", 30), ("a-again", 20), ("a-repeat", 20)] {
        send_acked(&mut s, tag, Command::Volume(value, false));
    }
    // Linn reports 20, 30 and the final 20 once: the repeat is unchanged.
    for late in [20, 30] {
        report_volume(&mut s, late);
        assert_eq!(
            shown_volume(&s),
            (Some(20), true),
            "the late frame for {late} confirmed or replaced the final 20"
        );
    }
    report_volume(&mut s, 20);
    assert_eq!(
        shown_volume(&s),
        (Some(20), false),
        "the drag's final value stays pending until the 3 s expiry"
    );
}

#[test]
fn redundant_pause_after_pause_play_pause_settles_on_ack() {
    let mut s = Script::new(); // Linn is playing.
    s.enqueue("pause", Command::Transport(TransportState::Paused as i32));
    assert_eq!(s.send(), ["pause"]);
    s.enqueue("play", Command::Transport(TransportState::Playing as i32));
    s.enqueue(
        "pause-again",
        Command::Transport(TransportState::Paused as i32),
    );
    s.ack("pause");
    s.transport(TransportState::Paused as i32);
    // Linn is now paused and does not push an unchanged transport state.
    assert_eq!(s.send(), ["pause-again"]);
    s.ack("pause-again");
    assert_eq!(s.view().pending, Some(PendingState::default()));
    s.now += SETTLE_LIMIT;
    assert!(
        !s.scheduler.tick(s.now),
        "the redundant pause blocked the playback lane into a read-back"
    );
}
