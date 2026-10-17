use super::*;

/// Result structure for mosaic panel calculations (FFI-safe)
#[derive(Debug, Clone)]
pub struct MosaicPanelResult {
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub panel_index: u32,
    pub row: u32,
    pub col: u32,
}

impl From<MosaicPanel> for MosaicPanelResult {
    fn from(panel: MosaicPanel) -> Self {
        Self {
            ra_hours: panel.ra_hours,
            dec_degrees: panel.dec_degrees,
            panel_index: panel.panel_index,
            row: panel.row,
            col: panel.col,
        }
    }
}

/// Calculate the RA/Dec of every mosaic panel around a centre. `center_ra` is in
/// hours (0-24) and `center_dec` in degrees (-90 to +90); panel size is in
/// arcminutes, `overlap_percent` in 0-50, `rotation` in degrees.
#[flutter_rust_bridge::frb(sync)]
pub fn api_calculate_mosaic_panels(
    center_ra: f64,
    center_dec: f64,
    panel_width_arcmin: f64,
    panel_height_arcmin: f64,
    overlap_percent: f64,
    rotation: f64,
    panels_horizontal: u32,
    panels_vertical: u32,
) -> Vec<MosaicPanelResult> {
    let config = MosaicConfig {
        center_ra,
        center_dec,
        panel_width_arcmin,
        panel_height_arcmin,
        overlap_percent,
        rotation,
        panels_horizontal,
        panels_vertical,
        ..MosaicConfig::default()
    };

    calculate_mosaic_panels(&config)
        .into_iter()
        .map(MosaicPanelResult::from)
        .collect()
}

/// Calculate total mosaic coverage area in square degrees
#[flutter_rust_bridge::frb(sync)]
pub fn api_calculate_mosaic_area(
    panel_width_arcmin: f64,
    panel_height_arcmin: f64,
    panels_horizontal: u32,
    panels_vertical: u32,
) -> f64 {
    // Why: u32 → f64 widening, exact (f64 mantissa covers
    // all u32 values).
    let total_width_arcmin = panel_width_arcmin * f64::from(panels_horizontal);
    let total_height_arcmin = panel_height_arcmin * f64::from(panels_vertical);
    // Return in square degrees
    (total_width_arcmin / 60.0) * (total_height_arcmin / 60.0)
}

/// Estimate total imaging time for mosaic in seconds
///
/// # Arguments
/// * `total_panels` - Total number of panels
/// * `exposure_secs` - Exposure time per frame
/// * `exposures_per_panel` - Number of exposures per panel
/// * `overhead_per_panel_secs` - Overhead per panel (slew, center, settle) - defaults to 60s if 0
#[flutter_rust_bridge::frb(sync)]
pub fn api_estimate_mosaic_time(
    total_panels: u32,
    exposure_secs: f64,
    exposures_per_panel: u32,
    overhead_per_panel_secs: f64,
) -> f64 {
    let overhead = if overhead_per_panel_secs <= 0.0 {
        60.0
    } else {
        overhead_per_panel_secs
    };
    // Why: u32 → f64 widening, exact.
    let time_per_panel = exposure_secs * f64::from(exposures_per_panel) + overhead;
    f64::from(total_panels) * time_per_panel
}

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

    skotiq_sequencer::meridian::calculate_altitude(
        ra_hours,
        dec_degrees,
        latitude,
        longitude,
        time,
    )
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
