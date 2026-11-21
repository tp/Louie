use crate::{apns::Error, pb};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;
use tonic::Status;

const MAX_TOKENS: usize = 128;

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct Registration {
    pub installation_id: String,
    pub kind: i32,
    pub token: String,
    pub session_id: String,
    pub server_url: String,
    pub environment: i32,
    pub registered_at: u64,
}

impl Registration {
    pub fn key(&self) -> String {
        format!(
            "{}|{}|{}|{}",
            self.installation_id, self.environment, self.kind, self.session_id
        )
    }

    pub fn from_request(
        request: pb::RegisterNowPlayingTokenRequest,
        now: u64,
    ) -> Result<Self, Status> {
        if request.installation_id.is_empty()
            || request.installation_id.len() > 128
            || !request
                .installation_id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err(Status::invalid_argument("invalid installation_id"));
        }
        if !(1..=2).contains(&request.environment)
            || !(1..=2).contains(&request.kind)
            || request.token.is_empty()
            || request.token.len() > 256
        {
            return Err(Status::invalid_argument(
                "invalid APNs token, kind or environment",
            ));
        }
        let url = reqwest::Url::parse(&request.server_url)
            .map_err(|_| Status::invalid_argument("invalid server_url"))?;
        if request.server_url.len() > 512
            || url.scheme() != "http"
            || url.host_str().is_none()
            || url.port().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.path() != "/"
        {
            return Err(Status::invalid_argument(
                "server_url must be a local HTTP gRPC endpoint with port",
            ));
        }
        if request.session_id.len() > 768 || (request.kind == 1) != request.session_id.is_empty() {
            return Err(Status::invalid_argument(
                "session_id is required only for a session update token",
            ));
        }
        Ok(Self {
            installation_id: request.installation_id,
            kind: request.kind,
            token: hex(&request.token),
            session_id: request.session_id,
            server_url: request.server_url,
            environment: request.environment,
            registered_at: now,
        })
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Clone)]
pub struct Registry {
    path: PathBuf,
    entries: Arc<Mutex<Vec<Registration>>>,
}

impl Registry {
    pub fn open(path: PathBuf) -> Result<Self, Error> {
        let entries: Vec<Registration> = match std::fs::read(&path) {
            Ok(bytes) if bytes.len() <= 1024 * 1024 => serde_json::from_slice(&bytes)?,
            Ok(_) => return Err("APNs registry is too large".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        if entries.len() > MAX_TOKENS {
            return Err("APNs registry exceeds token limit".into());
        }
        Ok(Self {
            path,
            entries: Arc::new(Mutex::new(entries)),
        })
    }

    pub async fn entries(&self) -> Vec<Registration> {
        self.entries.lock().await.clone()
    }

    pub async fn register(&self, entry: Registration) -> Result<(), Status> {
        let mut entries = self.entries.lock().await;
        let mut next = entries.clone();
        // A changed endpoint also invalidates the old session's control address.
        if entry.kind == 1
            && next.iter().any(|old| {
                old.installation_id == entry.installation_id
                    && old.environment == entry.environment
                    && old.kind == 1
                    && old.server_url != entry.server_url
            })
        {
            next.retain(|old| {
                !(old.installation_id == entry.installation_id
                    && old.environment == entry.environment)
            });
        }
        // One start and one current session token per installation/environment.
        next.retain(|old| {
            !(old.installation_id == entry.installation_id
                && old.environment == entry.environment
                && old.kind == entry.kind)
        });
        if next.len() >= MAX_TOKENS {
            return Err(Status::resource_exhausted("APNs token limit reached"));
        }
        next.push(entry);
        self.save(next.clone()).await?;
        *entries = next;
        Ok(())
    }

    pub async fn remove(&self, request: &pb::RemoveNowPlayingTokenRequest) -> Result<(), Status> {
        if request.token.is_empty()
            || !(1..=2).contains(&request.environment)
            || !(1..=2).contains(&request.kind)
        {
            return Err(Status::invalid_argument(
                "removal requires token, kind and environment",
            ));
        }
        let mut entries = self.entries.lock().await;
        let token = hex(&request.token);
        let next: Vec<_> = entries
            .iter()
            .filter(|old| {
                !(old.installation_id == request.installation_id
                    && old.kind == request.kind
                    && old.session_id == request.session_id
                    && old.environment == request.environment
                    && old.token == token)
            })
            .cloned()
            .collect();
        self.save(next.clone()).await?;
        *entries = next;
        Ok(())
    }

    pub async fn retire(&self, registration: &Registration) -> Result<(), Status> {
        let mut entries = self.entries.lock().await;
        let next: Vec<_> = entries
            .iter()
            .filter(|old| *old != registration)
            .cloned()
            .collect();
        self.save(next.clone()).await?;
        *entries = next;
        Ok(())
    }

    async fn save(&self, entries: Vec<Registration>) -> Result<(), Status> {
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || persist(&path, &entries))
            .await
            .map_err(|_| Status::internal("APNs registry writer failed"))?
            .map_err(|_| Status::internal("Could not persist APNs registry"))
    }
}

fn persist(path: &Path, entries: &[Registration]) -> Result<(), Error> {
    use std::io::Write;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or("registry needs a parent directory")?;
    std::fs::create_dir_all(parent)?;
    // NamedTempFile is created with mode 0600. Rename is atomic on the same filesystem.
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(&serde_json::to_vec(entries)?)?;
    file.as_file().sync_all()?;
    file.persist(path)?;
    std::fs::File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(token: u8) -> Registration {
        Registration::from_request(
            pb::RegisterNowPlayingTokenRequest {
                installation_id: "test-install".into(),
                kind: 1,
                token: vec![token; 32],
                server_url: "http://louie-pi.local:50051".into(),
                environment: 1,
                ..Default::default()
            },
            100,
        )
        .unwrap()
    }
    #[tokio::test]
    async fn rotation_persists_and_old_responses_cannot_remove_new_token() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tokens.json");
        let registry = Registry::open(path.clone()).unwrap();
        registry.register(entry(1)).await.unwrap();
        registry.register(entry(2)).await.unwrap();
        registry.retire(&entry(1)).await.unwrap();
        assert_eq!(registry.entries().await.len(), 1);
        assert!(registry.entries().await[0] == entry(2));
        let restored = Registry::open(path).unwrap();
        assert!(restored.entries().await[0] == entry(2));
        restored
            .remove(&pb::RemoveNowPlayingTokenRequest {
                installation_id: "test-install".into(),
                kind: 1,
                token: vec![1; 32],
                environment: 1,
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(restored.entries().await.len(), 1);
        restored.retire(&entry(2)).await.unwrap();
        assert!(restored.entries().await.is_empty());
    }
    #[test]
    fn rejects_unknown_environment_and_empty_tokens() {
        let request = pb::RegisterNowPlayingTokenRequest::default();
        assert!(Registration::from_request(request, 0).is_err());
    }
}
