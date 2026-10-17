// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::*;

/// Stream of events from the native side
/// The Dart side should listen to this stream for UI updates
///
/// # Overflow Handling
///
/// If the Dart side falls behind in consuming events (e.g., during heavy UI work),
/// the event stream will skip lagged events and send an `EventsDropped` notification
/// so the Dart side knows to refresh its state. The total number of dropped events
/// is tracked for diagnostics.
pub async fn api_event_stream(
    sink: crate::frb_generated::StreamSink<SkotiqEvent>,
) -> anyhow::Result<()> {
    tracing::info!(
        "[API_EVENT_STREAM] Starting event stream function (buffer size: {})",
        crate::event::DEFAULT_EVENT_BUFFER_SIZE
    );

    let mut rx = get_state().event_bus.subscribe();
    tracing::info!("[API_EVENT_STREAM] Subscribed to event bus");

    // Send a ready signal so Dart knows the subscription is active
    // This prevents race conditions where events are published before we're subscribed
    if let Err(err) = sink.add(create_event_auto_id(
        EventSeverity::Info,
        EventCategory::System,
        EventPayload::System(SystemEvent::Notification {
            title: "EventStreamReady".to_string(),
            message: "Event stream subscription is active".to_string(),
            level: "debug".to_string(),
            explicit_transports: None,
        }),
    )) {
        tracing::warn!("[API_EVENT_STREAM] Failed to send ready signal: {}", err);
        return Ok(());
    }
    tracing::info!("[API_EVENT_STREAM] Sent ready signal to Dart");

    loop {
        match rx.recv().await {
            Ok(event) => {
                tracing::debug!(
                    "[API_EVENT_STREAM] Forwarding event to Dart: {:?}",
                    std::mem::discriminant(&event.payload)
                );
                if let Err(err) = sink.add(event) {
                    tracing::warn!("[API_EVENT_STREAM] Failed to send event to Dart: {}", err);
                    break;
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                // Update the global dropped event counter
                let previous_total = TOTAL_DROPPED_EVENTS.fetch_add(n, Ordering::Relaxed);
                let new_total = previous_total + n;

                tracing::warn!(
                    "[API_EVENT_STREAM] Event stream lagged! Skipped {} events (total dropped: {}). \
                    Consider increasing DEFAULT_EVENT_BUFFER_SIZE or optimizing Dart event handling.",
                    n, new_total
                );

                // Send a notification to Dart so it knows events were dropped
                // This allows the UI to refresh its state from the source of truth
                if let Err(err) = sink.add(create_event_auto_id(
                    EventSeverity::Warning,
                    EventCategory::System,
                    EventPayload::System(SystemEvent::EventsDropped {
                        dropped_count: n,
                        total_dropped: new_total,
                    }),
                )) {
                    tracing::warn!(
                        "[API_EVENT_STREAM] Failed to send dropped-events notice: {}",
                        err
                    );
                    break;
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                tracing::info!("[API_EVENT_STREAM] Event bus closed, stopping stream");
                break;
            }
        }
    }

    Ok(())
}

/// Get the total number of events dropped since app start.
/// Useful for diagnostics and monitoring event stream health.
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_dropped_event_count() -> u64 {
    TOTAL_DROPPED_EVENTS.load(Ordering::Relaxed)
}
