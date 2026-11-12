use super::*;

impl SiteOps for UnifiedDeviceOps {
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        match self.app_state.get_observer_location() {
            Ok(Some(location)) => {
                tracing::debug!(
                    "Observer location retrieved: lat={}, lon={}",
                    location.latitude,
                    location.longitude
                );
                Some((location.latitude, location.longitude))
            }

            Ok(None) => {
                tracing::debug!("Observer location not set in settings, will retry");
                None
            }

            Err(e) => {
                tracing::warn!("Failed to get observer location: {}", e);
                None
            }
        }
    }
}
