use tonic::{Status, metadata::MetadataValue};

pub const REASON_HEADER: &str = "louie-error-reason";

pub fn failed_precondition(reason: &'static str, message: impl Into<String>) -> Status {
    let mut status = Status::failed_precondition(message);
    status
        .metadata_mut()
        .insert(REASON_HEADER, MetadataValue::from_static(reason));
    status
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reason_is_sent_as_grpc_metadata() {
        let status = failed_precondition("linn-disconnected", "gateway offline");
        assert_eq!(status.code(), tonic::Code::FailedPrecondition);
        assert_eq!(
            status.metadata().get(REASON_HEADER).unwrap(),
            "linn-disconnected"
        );
    }
}
