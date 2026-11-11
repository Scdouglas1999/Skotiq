use super::*;

/// Altitude in degrees above the horizon (-90 to +90) for a target at `ra_hours`
/// (hours, 0-24) / `dec_degrees` (degrees), seen from `latitude` / `longitude`
/// in degrees (north and east positive) at `time_unix_millis` (UTC epoch ms).
#[flutter_rust_bridge::frb(sync)]
pub fn api_calculate_altitude(
    ra_hours: f64,
    dec_degrees: f64,
    latitude: f64,
    longitude: f64,
    time_unix_millis: i64,
) -> f64 {
    use chrono::{TimeZone, Utc};

    // Convert Unix milliseconds to DateTime<Utc>
    let time = Utc
        .timestamp_millis_opt(time_unix_millis)
        .single()
        .unwrap_or_else(|| Utc::now());

    skotiq_sequencer::meridian::calculate_altitude(ra_hours, dec_degrees, latitude, longitude, time)
}

// LiveStacking broadcast API

/// Mirror of the active broadcast session exposed to Dart. Fields are
/// flattened so FRB does not have to bridge the Rust `BroadcastSession`
/// struct directly (the `chrono::DateTime` field would not bridge
/// cleanly).
#[derive(Debug, Clone)]
pub struct LiveStackingBroadcastSnapshot {
    /// Node id of the LiveStacking node that armed the broadcast.
    pub node_id: String,
    /// `broadcast_only` or `record_and_broadcast`.
    pub mode: String,
    /// `average`, `median_rej`, or `sigma`.
    pub stack_method: String,
    pub broadcast_enabled: bool,
    pub broadcast_port: u16,
    pub broadcast_path: String,
    /// Empty string when public (no token required). Non-empty when
    /// `?token=…` is required on every broadcast endpoint.
    pub auth_token: String,
    /// Empty string when no watermark configured. The Dart side does the
    /// variable-interpolation render against the live `${target}` /
    /// `${integration.hms}` context — Rust only carries the raw template.
    pub watermark_template: String,
    pub thumbnail_width: u32,
    pub thumbnail_height: u32,
    pub max_frames_to_stack: u32,
    /// Unix epoch milliseconds the broadcast was armed at.
    pub activated_at_unix_millis: i64,
}

impl From<&skotiq_sequencer::broadcast::BroadcastSession> for LiveStackingBroadcastSnapshot {
    fn from(s: &skotiq_sequencer::broadcast::BroadcastSession) -> Self {
        Self {
            node_id: s.node_id.clone(),
            mode: s.config.mode.as_str().to_string(),
            stack_method: s.config.stack_method.as_str().to_string(),
            broadcast_enabled: s.config.broadcast_enabled,
            broadcast_port: s.config.broadcast_port,
            broadcast_path: s.config.broadcast_path.clone(),
            auth_token: s.config.auth_token.clone().unwrap_or_default(),
            watermark_template: s.config.watermark_text.clone().unwrap_or_default(),
            thumbnail_width: s.config.thumbnail_width,
            thumbnail_height: s.config.thumbnail_height,
            max_frames_to_stack: s.config.max_frames_to_stack,
            activated_at_unix_millis: s.activated_at.timestamp_millis(),
        }
    }
}

/// Returns the currently-active LiveStacking broadcast session, or
/// `None` when no LiveStacking node has been executed in the current
/// sequence run.
///
/// consumed by the Dart `BroadcastService` to decide
/// whether `/api/broadcast/*` endpoints should answer 200 or 404.
#[flutter_rust_bridge::frb(sync)]
pub fn api_broadcast_get_active() -> Option<LiveStackingBroadcastSnapshot> {
    skotiq_sequencer::broadcast::current()
        .as_ref()
        .map(LiveStackingBroadcastSnapshot::from)
}

/// Force-deactivate the active broadcast session. Called by the Dart
/// side when the user toggles broadcast off mid-sequence, or by tests
/// that want a deterministic baseline. A no-op if no session is active.
#[flutter_rust_bridge::frb(sync)]
pub fn api_broadcast_deactivate() {
    if let Some(prev) = skotiq_sequencer::broadcast::deactivate() {
        tracing::info!(
            "LiveStacking broadcast force-deactivated (was node '{}', port {})",
            prev.node_id,
            prev.config.broadcast_port
        );
    }
}
