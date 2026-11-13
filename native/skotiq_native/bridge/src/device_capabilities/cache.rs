use crate::device_capabilities::types::DeviceCapabilities;
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

pub(crate) const CAPABILITY_CACHE_TTL: Duration = Duration::from_secs(300);

#[derive(Debug, Clone)]
pub(crate) struct CapabilityCacheEntry {
    pub(crate) capabilities: DeviceCapabilities,
    pub(crate) timestamp: Instant,
}

pub(crate) static CAPABILITY_CACHE: OnceLock<Mutex<HashMap<String, CapabilityCacheEntry>>> =
    OnceLock::new();

pub(crate) fn capability_cache() -> &'static Mutex<HashMap<String, CapabilityCacheEntry>> {
    CAPABILITY_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) async fn invalidate_capability_cache_for_device(device_id: &str) {
    if let Some(cache) = CAPABILITY_CACHE.get() {
        cache.lock().await.remove(device_id);
    }
}
