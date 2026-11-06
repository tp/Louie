//! APNs HTTP/2 transport. Tokens, private keys and authorization headers are never logged.
use std::{env, fs, time::Duration};

use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::{Client, Request, StatusCode};
use serde::Serialize;
use serde_json::Value;

pub type Error = Box<dyn std::error::Error + Send + Sync>;

pub struct Provider {
    client: Client,
    team: String,
    topic: String,
    sandbox: Option<Key>,
    production: Option<Key>,
}

struct Key {
    id: String,
    signing: EncodingKey,
    jwt: Option<(u64, String)>,
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Accepted,
    InvalidToken,
    Retry,
    Rejected,
}

impl Provider {
    pub fn from_env() -> Result<Option<Self>, Error> {
        let sandbox = Key::from_env("SANDBOX")?;
        let production = Key::from_env("PRODUCTION")?;
        if sandbox.is_none() && production.is_none() {
            return Ok(None);
        }
        let team = env::var("APNS_TEAM_ID").map_err(|_| "APNS_TEAM_ID is required")?;
        let bundle = env::var("APNS_BUNDLE_ID").map_err(|_| "APNS_BUNDLE_ID is required")?;
        if team.is_empty() || bundle.is_empty() || bundle.contains(char::is_whitespace) {
            return Err("APNS_TEAM_ID and APNS_BUNDLE_ID must be nonempty identifiers".into());
        }
        Ok(Some(Self {
            client: Client::builder()
                .https_only(true)
                .http2_prior_knowledge()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(5))
                .timeout(Duration::from_secs(10))
                .build()?,
            team,
            topic: format!("{bundle}.push-type.nowplaying"),
            sandbox,
            production,
        }))
    }

    pub fn supports(&self, environment: i32) -> bool {
        match environment {
            1 => self.sandbox.is_some(),
            2 => self.production.is_some(),
            _ => false,
        }
    }

    fn request(
        &mut self,
        environment: i32,
        token: &str,
        payload: &Value,
        now: u64,
    ) -> Result<Request, Error> {
        let (host, key) = match environment {
            1 => ("api.sandbox.push.apple.com", self.sandbox.as_mut()),
            2 => ("api.push.apple.com", self.production.as_mut()),
            _ => return Err("invalid APNs environment".into()),
        };
        let key = key.ok_or("APNs environment is not configured")?;
        let jwt = key.jwt(&self.team, now)?;
        let body = serde_json::to_vec(payload)?;
        if body.len() > 4096 {
            return Err("Now Playing payload exceeds APNs limit".into());
        }
        Ok(self
            .client
            .post(format!("https://{host}/3/device/{token}"))
            .version(reqwest::Version::HTTP_2)
            .bearer_auth(jwt)
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "nowplaying")
            .header("apns-expiration", "0") // Never deliver queued, stale playback later.
            .header(
                "apns-priority",
                if payload["aps"]["event"] == "update" {
                    "5"
                } else {
                    "10"
                },
            )
            .header("apns-collapse-id", "louie-nowplaying")
            .header("content-type", "application/json")
            .body(body)
            .build()?)
    }

    pub async fn send(
        &mut self,
        environment: i32,
        token: &str,
        payload: &Value,
        now: u64,
    ) -> Outcome {
        let request = match self.request(environment, token, payload, now) {
            Ok(request) => request,
            Err(_) => {
                tracing::warn!(
                    "Cannot construct Now Playing push; check APNs configuration/payload size"
                );
                return Outcome::Rejected;
            }
        };
        // reqwest errors can include the URL, whose path contains the device token.
        let Ok(response) = self.client.execute(request).await else {
            return Outcome::Retry;
        };
        let status = response.status();
        let reason = response
            .json::<Value>()
            .await
            .ok()
            .and_then(|v| v["reason"].as_str().map(str::to_owned))
            .unwrap_or_default();
        if reason == "ExpiredProviderToken" {
            let key = if environment == 1 {
                &mut self.sandbox
            } else {
                &mut self.production
            };
            if let Some(key) = key {
                key.jwt = None;
            }
        }
        let outcome = classify(status, &reason);
        if outcome == Outcome::Rejected {
            tracing::warn!(
                status = status.as_u16(),
                "APNs rejected Now Playing push; verify key, topic and entitlement configuration"
            );
        }
        outcome
    }
}

fn classify(status: StatusCode, reason: &str) -> Outcome {
    if status.is_success() {
        Outcome::Accepted
    } else if status == StatusCode::GONE && reason == "Unregistered"
        || status == StatusCode::BAD_REQUEST
            && matches!(reason, "BadDeviceToken" | "DeviceTokenNotForTopic")
    {
        Outcome::InvalidToken
    } else if status == StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
        || reason == "ExpiredProviderToken"
    {
        Outcome::Retry
    } else {
        Outcome::Rejected
    }
}

impl Key {
    fn from_env(environment: &str) -> Result<Option<Self>, Error> {
        let id = env::var(format!("APNS_{environment}_KEY_ID")).ok();
        let path = env::var(format!("APNS_{environment}_KEY_PATH")).ok();
        match (id, path) {
            (None, None) => Ok(None),
            (Some(id), Some(path)) => Ok(Some(Self {
                id,
                signing: EncodingKey::from_ec_pem(&fs::read(path)?)?,
                jwt: None,
            })),
            _ => Err(format!(
                "APNS_{environment}_KEY_ID and APNS_{environment}_KEY_PATH must be set together"
            )
            .into()),
        }
    }

    fn jwt(&mut self, team: &str, now: u64) -> Result<&str, Error> {
        if self
            .jwt
            .as_ref()
            .is_none_or(|(issued, _)| now < *issued || now - issued >= 1800)
        {
            #[derive(Serialize)]
            struct Claims<'a> {
                iss: &'a str,
                iat: u64,
            }
            let mut header = Header::new(Algorithm::ES256);
            header.kid = Some(self.id.clone());
            self.jwt = Some((
                now,
                encode(
                    &header,
                    &Claims {
                        iss: team,
                        iat: now,
                    },
                    &self.signing,
                )?,
            ));
        }
        Ok(&self.jwt.as_ref().expect("JWT populated").1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requests_use_nowplaying_topic_environment_and_cached_es256_signature() {
        use jsonwebtoken::{DecodingKey, Validation, decode};
        use serde::Deserialize;
        // Public test fixture, never a production APNs credential.
        let key = || Key {
            id: "TESTKEY".into(),
            signing: EncodingKey::from_ec_pem(include_bytes!("../tests/fixtures/apns-test-key.p8"))
                .unwrap(),
            jwt: None,
        };
        let mut provider = Provider {
            client: Client::new(),
            team: "TESTTEAM".into(),
            topic: "xyz.preetz.Louie.push-type.nowplaying".into(),
            sandbox: Some(key()),
            production: Some(key()),
        };
        let payload = serde_json::json!({"aps":{"event":"update","timestamp":100,"attributes":{"id":"session"}}});
        let request = provider.request(1, "abcdef", &payload, 100).unwrap();
        assert_eq!(request.url().host_str(), Some("api.sandbox.push.apple.com"));
        assert_eq!(request.version(), reqwest::Version::HTTP_2);
        assert_eq!(
            request.headers()["apns-topic"],
            "xyz.preetz.Louie.push-type.nowplaying"
        );
        assert_eq!(request.headers()["apns-push-type"], "nowplaying");
        assert_eq!(request.headers()["apns-expiration"], "0");
        let authorization = request.headers()["authorization"].to_str().unwrap();
        let jwt = authorization.strip_prefix("Bearer ").unwrap();
        #[derive(Deserialize, Clone)]
        struct Claims {
            iss: String,
            iat: u64,
        }
        let mut validation = Validation::new(Algorithm::ES256);
        validation.required_spec_claims.clear();
        validation.validate_exp = false;
        let decoded = decode::<Claims>(
            jwt,
            &DecodingKey::from_ec_pem(include_bytes!("../tests/fixtures/apns-test-public.pem"))
                .unwrap(),
            &validation,
        )
        .unwrap();
        assert_eq!(decoded.header.kid.as_deref(), Some("TESTKEY"));
        assert_eq!(decoded.claims.iss, "TESTTEAM");
        assert_eq!(decoded.claims.iat, 100);
        assert_eq!(
            provider
                .request(1, "abcdef", &payload, 200)
                .unwrap()
                .headers()["authorization"],
            authorization
        );
        assert_ne!(
            provider
                .request(1, "abcdef", &payload, 1900)
                .unwrap()
                .headers()["authorization"],
            authorization
        );
        assert_eq!(
            provider
                .request(2, "abcdef", &payload, 100)
                .unwrap()
                .url()
                .host_str(),
            Some("api.push.apple.com")
        );
    }

    #[test]
    fn apns_errors_distinguish_token_expiry_from_configuration_and_retry() {
        assert_eq!(classify(StatusCode::OK, ""), Outcome::Accepted);
        assert_eq!(
            classify(StatusCode::GONE, "Unregistered"),
            Outcome::InvalidToken
        );
        assert_eq!(
            classify(StatusCode::BAD_REQUEST, "BadDeviceToken"),
            Outcome::InvalidToken
        );
        assert_eq!(
            classify(StatusCode::FORBIDDEN, "InvalidProviderToken"),
            Outcome::Rejected
        );
        assert_eq!(
            classify(StatusCode::FORBIDDEN, "ExpiredProviderToken"),
            Outcome::Retry
        );
        assert_eq!(
            classify(StatusCode::TOO_MANY_REQUESTS, "TooManyRequests"),
            Outcome::Retry
        );
        assert_eq!(
            classify(StatusCode::SERVICE_UNAVAILABLE, "Shutdown"),
            Outcome::Retry
        );
    }
}
