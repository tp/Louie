//! Exercise the real WebSocket worker, not only the pure scheduler transitions.
use super::*;
use tokio::{net::TcpListener, task::JoinHandle};
use tokio_tungstenite::accept_async;

fn playlist(index: i32, revision: i32) -> Value {
    let children: serde_json::Map<String, Value> = (0..4)
        .map(|i| {
            (
                i.to_string(),
                json!({"class":"track", "name":format!("Song {i}"), "selected":i == index}),
            )
        })
        .collect();
    json!({"requestPath":"/V2/playlist/subscribe", "data":{"total":4, "content_revision":revision, "children":children}})
}
fn metadata(index: i32) -> Value {
    json!({"requestPath":"/V2/metadata/status", "metadata":{"line_1":format!("Song {index}")}})
}
fn seek(position: i32) -> Value {
    json!({"requestPath":"/V2/seek/status", "data":{"elapsed":position,"duration":200,"seekable":true}})
}

struct Wire {
    gateway: Gateway,
    commands: mpsc::Receiver<Value>,
    updates: mpsc::Sender<Value>,
    server: JoinHandle<()>,
}
impl Drop for Wire {
    fn drop(&mut self) {
        self.server.abort();
    }
}
impl Wire {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (commands_tx, commands) = mpsc::channel(32);
        let (updates, mut updates_rx) = mpsc::channel::<Value>(32);
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = accept_async(stream).await.unwrap();
            loop {
                let reply = tokio::select! {
                    message = socket.next() => {
                        let Some(Ok(Message::Text(text))) = message else { break };
                        let request: Value = serde_json::from_str(&text).unwrap();
                        let path = request["requestPath"].as_str().unwrap();
                        if request["tag"].as_str().is_some_and(|t| t.starts_with("pi-") || t.starts_with("refresh-")) {
                            commands_tx.send(request).await.unwrap(); continue;
                        }
                        match path {
                            "/session/create" => json!({"requestPath":path,"session":"test"}),
                            "/V2/topology/status" => json!({"requestPath":path,"data":{"rooms":[{"name":"Linn"}]}}),
                            "/V2/product/status" => json!({"requestPath":path,"data":{"standby":false}}),
                            "/V2/playlist/subscribe" => playlist(0, 1),
                            "/V2/metadata/status" => metadata(0),
                            "/V2/seek/status" => seek(40),
                            "/V2/transport/status" => json!({"requestPath":path,"data":{"transport_state":"play"}}),
                            "/V2/volume/status" => json!({"requestPath":path,"data":{"volume":10,"mute":false}}),
                            _ => continue,
                        }
                    }
                    Some(update) = updates_rx.recv() => update,
                };
                if socket
                    .send(Message::Text(reply.to_string().into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });
        let gateway = Gateway::start(format!("ws://{address}"), "Linn".into(), 70);
        let wire = Self {
            gateway,
            commands,
            updates,
            server,
        };
        wire.wait(|s| {
            s.now_playing
                .as_ref()
                .and_then(|p| p.playlist.as_ref())
                .and_then(|q| q.total)
                == Some(4)
        })
        .await;
        wire
    }
    async fn next(&mut self) -> Value {
        tokio::time::timeout(Duration::from_secs(5), self.commands.recv())
            .await
            .unwrap()
            .unwrap()
    }
    async fn quiet(&mut self) {
        assert!(
            tokio::time::timeout(Duration::from_millis(80), self.commands.recv())
                .await
                .is_err()
        );
    }
    async fn update(&self, value: Value) {
        self.updates.send(value).await.unwrap();
    }
    async fn ack(&self, request: &Value) {
        self.update(json!({"tag":request["tag"]})).await;
    }
    async fn wait(&self, predicate: impl Fn(&StateSnapshot) -> bool) {
        let mut state = self.gateway.subscribe();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if predicate(&state.borrow_and_update()) {
                    break;
                }
                state.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
    }
    fn row(&self, index: i32) -> JoinHandle<Result<Value, tonic::Status>> {
        let gateway = self.gateway.clone();
        tokio::spawn(async move {
            gateway
                .request("/V2/playlist/select", json!({"room":"Linn","index":index}))
                .await
        })
    }
}

#[tokio::test]
async fn double_skip_waits_for_metadata_even_after_ack_and_index() {
    let mut wire = Wire::new().await;
    let gateway = wire.gateway.clone();
    let first = tokio::spawn(async move { gateway.skip(1).await });
    let request = wire.next().await;
    assert_eq!(request["index"], 1);
    let gateway = wire.gateway.clone();
    let second = tokio::spawn(async move { gateway.skip(1).await });
    wire.wait(|s| {
        s.now_playing
            .as_ref()
            .unwrap()
            .playlist
            .as_ref()
            .unwrap()
            .current_index
            == Some(2)
    })
    .await;
    wire.ack(&request).await;
    first.await.unwrap().unwrap();
    wire.quiet().await;
    wire.update(playlist(1, 2)).await;
    wire.update(seek(0)).await;
    wire.quiet().await;
    assert_eq!(
        wire.gateway
            .snapshot()
            .now_playing
            .unwrap()
            .current_item
            .unwrap()
            .display_name
            .as_deref(),
        Some("Song 2")
    );
    wire.update(metadata(1)).await;
    let request = wire.next().await;
    assert_eq!(request["index"], 2);
    wire.ack(&request).await;
    second.await.unwrap().unwrap();
    wire.update(playlist(2, 3)).await;
    wire.wait(|s| !s.pending.as_ref().unwrap().queue_index)
        .await;
    let snapshot = wire.gateway.snapshot();
    assert_eq!(
        snapshot
            .now_playing
            .unwrap()
            .current_item
            .unwrap()
            .display_name
            .as_deref(),
        Some("Song 2")
    );
    assert!(snapshot.pending.unwrap().current_item);
    wire.update(metadata(2)).await;
    wire.update(seek(0)).await;
    wire.wait(|s| s.pending == Some(PendingState::default()))
        .await;
}

#[tokio::test]
async fn a_b_a_cancels_b_but_does_not_restart_confirmed_a() {
    let mut wire = Wire::new().await;
    let first = wire.row(1);
    let request = wire.next().await;
    let second = wire.row(2);
    wire.wait(|s| {
        s.now_playing
            .as_ref()
            .unwrap()
            .playlist
            .as_ref()
            .unwrap()
            .current_index
            == Some(2)
    })
    .await;
    let third = wire.row(1);
    assert_eq!(
        second.await.unwrap().unwrap_err().code(),
        tonic::Code::Cancelled
    );
    wire.ack(&request).await;
    first.await.unwrap().unwrap();
    wire.update(playlist(1, 2)).await;
    wire.update(metadata(1)).await;
    wire.update(seek(0)).await;
    third.await.unwrap().unwrap();
    wire.quiet().await;
    wire.wait(|s| s.pending == Some(PendingState::default()))
        .await;
}

#[tokio::test]
async fn timeout_reads_back_without_unsubscribing_before_sending_waiting_command() {
    let mut wire = Wire::new().await;
    let first = wire.row(1);
    let request = wire.next().await;
    wire.ack(&request).await;
    first.await.unwrap().unwrap();
    let second = wire.row(2);
    let mut refreshes = Vec::new();
    for _ in 0..4 {
        let request = wire.next().await;
        assert!(request["tag"].as_str().unwrap().starts_with("refresh-"));
        assert!(
            request.get("update").is_none(),
            "update=0 would cancel the live subscription"
        );
        refreshes.push(request);
    }
    wire.quiet().await;
    for request in refreshes {
        let mut reply = match request["requestPath"].as_str().unwrap() {
            "/V2/transport/status" => json!({"data":{"transport_state":"play"}}),
            "/V2/seek/status" => seek(0),
            "/V2/metadata/status" => metadata(1),
            "/V2/playlist/subscribe" => playlist(1, 1),
            _ => unreachable!(),
        };
        reply.as_object_mut().unwrap().remove("requestPath");
        reply["tag"] = request["tag"].clone();
        wire.update(reply).await;
    }
    let request = wire.next().await;
    assert_eq!(request["index"], 2);
    wire.ack(&request).await;
    second.await.unwrap().unwrap();
    wire.update(playlist(2, 3)).await;
    wire.update(metadata(2)).await;
    wire.update(seek(0)).await;
    wire.wait(|s| s.pending == Some(PendingState::default()))
        .await;
}

#[tokio::test]
async fn disconnect_clears_predictions_and_does_not_replay_waiting_controls() {
    let mut wire = Wire::new().await;
    let first = wire.row(1);
    let request = wire.next().await;
    wire.ack(&request).await;
    first.await.unwrap().unwrap();
    let second = wire.row(2);
    wire.wait(|s| {
        s.now_playing
            .as_ref()
            .unwrap()
            .playlist
            .as_ref()
            .unwrap()
            .current_index
            == Some(2)
    })
    .await;
    wire.update(json!({"requestPath":"/V2/topology/status","data":{"rooms":[]}}))
        .await;
    assert_eq!(
        second.await.unwrap().unwrap_err().code(),
        tonic::Code::FailedPrecondition
    );
    wire.wait(|s| s.connection_status == ConnectionStatus::Disconnected as i32)
        .await;
    assert_eq!(
        wire.gateway.snapshot().pending,
        Some(PendingState::default())
    );
}

#[test]
fn partial_status_frames_are_valid_readbacks_but_not_evidence_for_missing_fields() {
    assert_eq!(
        evidence_paths("/V2/seek/status", &json!({"data":{"seekable":false}})),
        Some(vec![])
    );
    assert_eq!(
        evidence_paths("/V2/volume/status", &json!({"data":{"mute":true}})),
        Some(vec!["mute"])
    );
    assert_eq!(
        evidence_paths("/V2/volume/status", &json!({"data":{"volume":"invalid"}})),
        None
    );
    assert_eq!(
        evidence_paths(
            "/V2/metadata/status",
            &json!({"metadata":{"line_2":"Artist"}})
        ),
        Some(vec![])
    );
}
