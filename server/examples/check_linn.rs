pub mod pb {
    tonic::include_proto!("louie.linn.v1");
}

use std::{env, time::Duration};

use pb::{ConnectionStatus, SetVolumeRequest, VolumeScope, linn_client::LinnClient};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut endpoint = None;
    let mut probe_ack = false;
    let mut probe_volume = false;
    let mut require_connected = false;
    for arg in env::args().skip(1) {
        match arg.as_str() {
            "--probe-ack" => probe_ack = true,
            "--probe-volume" => probe_volume = true,
            "--require-connected" => require_connected = true,
            _ if arg.starts_with('-') => return Err(format!("unknown option: {arg}").into()),
            _ if endpoint.is_none() => endpoint = Some(arg),
            _ => return Err(format!("unexpected argument: {arg}").into()),
        }
    }
    let endpoint = endpoint.unwrap_or_else(|| "http://127.0.0.1:50051".into());
    let mut client = LinnClient::connect(endpoint).await?;

    let snapshot = tokio::time::timeout(Duration::from_secs(5), client.get_state(()))
        .await??
        .into_inner();
    let connection = ConnectionStatus::try_from(snapshot.connection_status)?;
    println!("room={} connection={connection:?}", snapshot.room);
    println!(
        "standby={:?}",
        snapshot
            .now_playing
            .as_ref()
            .and_then(|state| state.is_standby)
    );
    if snapshot.room.trim().is_empty() {
        return Err("Linn room is empty".into());
    }
    if connection != ConnectionStatus::Connected {
        if probe_ack || require_connected {
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
    if probe_volume {
        if connection != ConnectionStatus::Connected {
            return Err("volume probe requires a connected Linn".into());
        }
        let room_volume = snapshot
            .now_playing
            .as_ref()
            .and_then(|state| state.room_volume.as_ref())
            .ok_or("room volume is unavailable")?;
        let original = room_volume.volume.ok_or("current volume is unavailable")?;
        let test_volume = if original < maximum_volume.unwrap_or(70).min(70) {
            original + 1
        } else if original > 0 {
            original - 1
        } else {
            return Err("no safe volume probe step is available".into());
        };
        println!("Probing room volume {original} -> {test_volume} -> {original}");
        let probe_result = async {
            set_room_volume(&mut client, test_volume).await?;
            wait_for_observed_volume(&mut client, test_volume).await
        }
        .await;
        let restore_result = async {
            set_room_volume(&mut client, original).await?;
            wait_for_observed_volume(&mut client, original).await
        }
        .await;
        restore_result?;
        probe_result?;
        println!("Room volume changed and restored on the Linn");
    }
    Ok(())
}

async fn set_room_volume(
    client: &mut LinnClient<tonic::transport::Channel>,
    volume: i32,
) -> Result<(), Box<dyn std::error::Error>> {
    tokio::time::timeout(
        Duration::from_secs(6),
        client.set_volume(SetVolumeRequest {
            volume,
            scope: VolumeScope::Room as i32,
        }),
    )
    .await??;
    Ok(())
}

async fn wait_for_observed_volume(
    client: &mut LinnClient<tonic::transport::Channel>,
    expected: i32,
) -> Result<(), Box<dyn std::error::Error>> {
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            let snapshot = client.get_state(()).await?.into_inner();
            let current = snapshot
                .now_playing
                .as_ref()
                .and_then(|state| state.room_volume.as_ref())
                .and_then(|volume| volume.volume);
            let pending = snapshot.pending.as_ref().is_some_and(|state| state.volume);
            if current == Some(expected) && !pending {
                return Ok::<(), tonic::Status>(());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await??;
    Ok(())
}
