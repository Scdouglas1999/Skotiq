use crate::event::bus::{EventPayload, SkotiqEvent};
use crate::event::correlation::create_event_auto_id;
use crate::event::equipment::{EventCategory, EventSeverity};
use crate::event::system::SystemEvent;
use crate::state::get_state;
use std::sync::atomic::{AtomicU64, Ordering};

/// Events dropped across all event streams, counted when a receiver falls
/// behind and the bus skips events for it.
static TOTAL_DROPPED_EVENTS: AtomicU64 = AtomicU64::new(0);

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
        crate::event::bus::DEFAULT_EVENT_BUFFER_SIZE
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
