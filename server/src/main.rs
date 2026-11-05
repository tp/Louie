mod gateway;
mod optimism;
mod service;

pub mod pb {
    tonic::include_proto!("louie.linn.v1");
}

use std::{env, net::SocketAddr};

use pb::linn_server::LinnServer;
use tonic::transport::Server;
use tracing::info;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "louie_server=info".into()),
        )
        .init();

    let gateway_url =
        env::var("LINN_CI_GATEWAY_WS_URL").map_err(|_| "LINN_CI_GATEWAY_WS_URL is required")?;
    let room = env::var("LINN_ROOM").unwrap_or_else(|_| "Linn".into());
    let maximum_volume: i32 = env::var("LINN_MAX_VOLUME")
        .unwrap_or_else(|_| "70".into())
        .parse()?;
    if !(0..=70).contains(&maximum_volume) {
        return Err("LINN_MAX_VOLUME must be 0..70".into());
    }
    let bind: SocketAddr = env::var("LOUIE_GRPC_BIND")
        .unwrap_or_else(|_| "127.0.0.1:50051".into())
        .parse()?;

    let gateway = gateway::Gateway::start(gateway_url, room, maximum_volume);
    info!("Serving Linn gRPC on {bind}");
    Server::builder()
        .add_service(LinnServer::new(service::LinnService::new(gateway)))
        .serve(bind)
        .await?;
    Ok(())
}
