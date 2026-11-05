pub mod pb {
    tonic::include_proto!("louie.linn.v1");
}

use std::{env, time::Duration};

use pb::{ConnectionStatus, linn_client::LinnClient};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let endpoint = env::args()
        .nth(1)
        .unwrap_or_else(|| "http://127.0.0.1:50051".into());
    let mut client = LinnClient::connect(endpoint).await?;

    let snapshot = tokio::time::timeout(Duration::from_secs(5), client.get_state(()))
        .await??
        .into_inner();
    let connection = ConnectionStatus::try_from(snapshot.connection_status)?;
    println!("room={} connection={connection:?}", snapshot.room);
    if connection != ConnectionStatus::Connected {
        return Err(format!(
            "Linn gateway is not connected: {:?}",
            snapshot.connection_error
        )
        .into());
    }

    let maximum_volume = snapshot
        .now_playing
        .as_ref()
        .and_then(|state| state.room_volume.as_ref())
        .map(|volume| volume.maximum_volume)
        .ok_or("missing room volume")?;
    println!("maximum_volume={maximum_volume}");
    if maximum_volume > 70 {
        return Err("volume ceiling exceeds 70".into());
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
    Ok(())
}
