use super::*;

fn registration(kind: i32) -> Registration {
    Registration {
        installation_id: "test-install".into(),
        kind,
        token: "aa".repeat(32),
        session_id: if kind == 2 {
            "http://louie-pi.local:50051|Linn".into()
        } else {
            String::new()
        },
        server_url: "http://louie-pi.local:50051".into(),
        environment: 1,
        registered_at: 100,
    }
}
fn snapshot() -> pb::StateSnapshot {
    pb::StateSnapshot {
        room: "Linn".into(),
        connection_status: pb::ConnectionStatus::Connected as i32,
        published_at: Some(prost_types::Timestamp {
            seconds: 100,
            nanos: 0,
        }),
        now_playing: Some(pb::NowPlayingState {
            transport_state: Some(pb::TransportState::Playing as i32),
            is_standby: Some(false),
            current_item: Some(pb::CurrentItem {
                id: "song-1".into(),
                display_name: Some("Song".into()),
                ..Default::default()
            }),
            playlist: Some(pb::Playlist {
                current_index: Some(1),
                total: Some(3),
                ..Default::default()
            }),
            timeline: Some(pb::Timeline {
                position_seconds: Some(20),
                duration_seconds: Some(180),
                is_seekable: Some(true),
                seek_lower_bound_seconds: Some(0),
                seek_upper_bound_seconds: Some(180),
                position_sampled_at: Some(prost_types::Timestamp {
                    seconds: 100,
                    nanos: 0,
                }),
            }),
            room_volume: Some(pb::RoomVolume {
                volume: Some(13),
                maximum_volume: 70,
                ..Default::default()
            }),
        }),
        ..Default::default()
    }
}

#[test]
fn start_update_pause_end_and_reconnect() {
    let start = registration(1);
    let update = registration(2);
    let mut state = snapshot();
    assert_eq!(
        plan(&state, &start, std::slice::from_ref(&start), None, 100).unwrap()["aps"]["event"],
        "start"
    );
    assert!(plan(&state, &start, &[start.clone(), update.clone()], None, 100).is_none());
    let initial = plan(&state, &update, std::slice::from_ref(&update), None, 100).unwrap();
    assert_eq!(initial["aps"]["event"], "update");
    assert!(plan(&state, &update, &[], Some(&initial), 101).is_none());
    state.now_playing.as_mut().unwrap().transport_state = Some(pb::TransportState::Paused as i32);
    assert_eq!(
        plan(&state, &update, &[], Some(&initial), 101).unwrap()["aps"]["attributes"]["playback"]["state"],
        "paused"
    );
    state.now_playing.as_mut().unwrap().is_standby = Some(true);
    let end = plan(&state, &update, &[], Some(&initial), 102).unwrap();
    assert_eq!(end["aps"]["event"], "end");
    assert_eq!(end["aps"]["attributes"], json!({"id": update.session_id}));
    assert!(plan(&state, &start, &[], None, 102).is_none());
    state = snapshot();
    state.connection_status = pb::ConnectionStatus::Disconnected as i32;
    assert_eq!(
        plan(&state, &update, &[], None, 103).unwrap()["aps"]["event"],
        "end"
    );
    state.connection_status = pb::ConnectionStatus::Connected as i32;
    assert_eq!(
        plan(&state, &start, &[], None, 104).unwrap()["aps"]["event"],
        "start"
    );
}

#[test]
fn normal_elapsed_ticks_are_suppressed_but_seek_and_metadata_changes_are_sent() {
    let registration = registration(2);
    let mut state = snapshot();
    let initial = plan(&state, &registration, &[], None, 100).unwrap();
    let timeline = state
        .now_playing
        .as_mut()
        .unwrap()
        .timeline
        .as_mut()
        .unwrap();
    timeline.position_seconds = Some(30);
    timeline.position_sampled_at.as_mut().unwrap().seconds = 110;
    assert!(plan(&state, &registration, &[], Some(&initial), 110).is_none());
    state
        .now_playing
        .as_mut()
        .unwrap()
        .timeline
        .as_mut()
        .unwrap()
        .position_seconds = Some(90);
    assert!(plan(&state, &registration, &[], Some(&initial), 110).is_some());
    state = snapshot();
    state
        .now_playing
        .as_mut()
        .unwrap()
        .current_item
        .as_mut()
        .unwrap()
        .display_name = Some("Next Song".into());
    assert!(plan(&state, &registration, &[], Some(&initial), 110).is_some());
    state = snapshot();
    state
        .now_playing
        .as_mut()
        .unwrap()
        .room_volume
        .as_mut()
        .unwrap()
        .volume = Some(20);
    assert!(plan(&state, &registration, &[], Some(&initial), 110).is_some());
}

#[test]
fn different_installations_and_environments_do_not_suppress_each_other() {
    let start = registration(1);
    let mut other = registration(2);
    other.installation_id = "other".into();
    assert!(plan(&snapshot(), &start, &[other.clone()], None, 100).is_some());
    other.installation_id = start.installation_id.clone();
    other.environment = 2;
    assert!(plan(&snapshot(), &start, &[other], None, 100).is_some());
}

#[test]
fn payload_matches_the_shared_swift_fixture() {
    let attrs = attributes(&snapshot(), &registration(2), 100);
    let expected: Value = serde_json::from_str(include_str!(
        "../../Packages/Linn/Tests/LinnNowPlayingTests/Fixtures/push-attributes.json"
    ))
    .unwrap();
    assert_eq!(attrs, expected);
}
