/// Alpaca API version
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiVersion {
    V1,
}

impl ApiVersion {
    pub fn as_str(&self) -> &'static str {
        match self {
            ApiVersion::V1 => "v1",
        }
    }

    /// Choose the best API version supported by both client and server.
    pub fn negotiate(versions: &[u32]) -> Option<Self> {
        if versions.contains(&1) {
            Some(ApiVersion::V1)
        } else {
            None
        }
    }
}
