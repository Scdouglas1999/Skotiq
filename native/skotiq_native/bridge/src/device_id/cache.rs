use super::ParsedDeviceId;
use crate::error::SkotiqError;
use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::{Mutex, OnceLock};

/// A rig has 5-10 devices; 64 holds several sessions' worth of ids.
const CAPACITY: NonZeroUsize = NonZeroUsize::new(64).unwrap();

static DEVICE_ID_CACHE: OnceLock<Mutex<LruCache<String, ParsedDeviceId>>> = OnceLock::new();

/// Parse a device ID, reusing an earlier parse of the same id.
///
/// A poisoned lock is recovered: the cache only saves work around
/// `ParsedDeviceId::parse`, and a stored entry is a complete parse.
pub fn parse_device_id_cached(device_id: &str) -> Result<ParsedDeviceId, SkotiqError> {
    let cache = DEVICE_ID_CACHE.get_or_init(|| Mutex::new(LruCache::new(CAPACITY)));

    if let Some(cached) = cache
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(device_id)
    {
        return Ok(cached.clone());
    }

    let parsed = ParsedDeviceId::parse(device_id)?;
    cache
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .put(device_id.to_string(), parsed.clone());
    Ok(parsed)
}
