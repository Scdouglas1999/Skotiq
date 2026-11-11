//! Where the observer is.

pub trait SiteOps: Send + Sync {
    /// Get observer location
    fn get_observer_location(&self) -> Option<(f64, f64)>;
}
