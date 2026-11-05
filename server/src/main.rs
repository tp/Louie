mod gateway;
mod optimism;
mod service;

pub mod pb {
    tonic::include_proto!("louie.linn.v1");
}

use std::{env, net::SocketAddr};

use pb::linn_server::LinnServer;
use sentry::integrations::tracing::{ErrorLayer, LogLayer};
use tonic::transport::Server;
use tracing::info;
use tracing_subscriber::{filter::LevelFilter, prelude::*};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut sentry_options = sentry::ClientOptions::default();
    sentry_options.release = sentry::release_name!();
    let _sentry_guard = sentry::init(sentry_options);
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "louie_server=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .with(LogLayer::new().with_filter(LevelFilter::WARN))
        .with(ErrorLayer::new().with_filter(LevelFilter::ERROR))
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
