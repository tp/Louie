pub mod pb {
    tonic::include_proto!("louie.linn.v1");
}

use std::{env, time::Duration};

use pb::{ConnectionStatus, linn_client::LinnClient};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    let endpoint = args
        .next()
        .unwrap_or_else(|| "http://127.0.0.1:50051".into());
    let probe_ack = args.next().as_deref() == Some("--probe-ack");
    let mut client = LinnClient::connect(endpoint).await?;

    let snapshot = tokio::time::timeout(Duration::from_secs(5), client.get_state(()))
        .await??
        .into_inner();
    let connection = ConnectionStatus::try_from(snapshot.connection_status)?;
    println!("room={} connection={connection:?}", snapshot.room);
    if snapshot.room.trim().is_empty() {
        return Err("Linn room is empty".into());
    }
    if connection != ConnectionStatus::Connected {
        if probe_ack || env::args().any(|arg| arg == "--require-connected") {
            return Err(format!(
                "Linn gateway is not connected: {:?}",
                snapshot.connection_error
            )
            .into());
        }
        eprintln!(
            "warning: Linn gateway is not connected: {:?}",
            snapshot.connection_error
        );
    }

    let maximum_volume = snapshot
        .now_playing
        .as_ref()
        .and_then(|state| state.room_volume.as_ref())
        .map(|volume| volume.maximum_volume);
    if let Some(maximum_volume) = maximum_volume {
        println!("maximum_volume={maximum_volume}");
        if maximum_volume > 70 {
            return Err("volume ceiling exceeds 70".into());
        }
    }

    let mut updates = tokio::time::timeout(Duration::from_secs(5), client.watch_state(()))
        .await??
        .into_inner();
    let first = tokio::time::timeout(Duration::from_secs(5), updates.message())
        .await??
        .ok_or("WatchState ended without an initial snapshot")?;
    if first.room != snapshot.room {
        return Err("WatchState room differs from GetState room".into());
    }
    println!("WatchState delivered initial snapshot");
    if probe_ack {
        tokio::time::timeout(Duration::from_secs(6), client.list_media_services(())).await??;
        println!("ListMediaServices acknowledged");
    }
    Ok(())
}
