//! Post-session FFI surface: integration, masters and their delivery.
//!
//! The pipeline is [`skotiq_processing::post_session`]. Every entry point is
//! `String -> Result<String, String>` with the request and the reply as JSON,
//! so a setting added to the pipeline needs no binding regeneration. The calls
//! are synchronous and CPU-bound; Dart runs them off the UI isolate.

use crate::event::equipment::EventSeverity;
use crate::event::imaging::ImagingEvent;
use crate::state::get_state;
use skotiq_processing::post_session::report::{report_to, PassReport};

pub mod entrypoints;

/// Puts what a running pass reports on the event bus, where Dart reads it as
/// `IntegrationProgress` and `IntegrationTelemetry`.
fn publish_pass_reports() {
    report_to(publish);
}

fn publish(report: PassReport) {
    let event = match report {
        PassReport::Progress {
            phase,
            fraction,
            frames_done,
            frames_total,
        } => ImagingEvent::IntegrationProgress {
            phase,
            fraction,
            frames_done,
            frames_total,
        },
        PassReport::Telemetry {
            run_id,
            kind,
            detail_json,
        } => ImagingEvent::IntegrationTelemetry {
            run_id,
            kind,
            detail_json,
        },
    };
    get_state().publish_imaging_event(event, EventSeverity::Info);
}

#[cfg(test)]
mod tests {
    use super::{publish, PassReport};
    use crate::event::bus::EventPayload;
    use crate::event::imaging::ImagingEvent;
    use crate::state::get_state;

    #[test]
    fn a_pass_report_reaches_the_event_bus_unchanged() {
        let mut events = get_state().event_bus.subscribe();
        publish(PassReport::Telemetry {
            run_id: "bus-wiring".to_string(),
            kind: "registered".to_string(),
            detail_json: r#"{"index":3}"#.to_string(),
        });
        publish(PassReport::Progress {
            phase: "bus-wiring".to_string(),
            fraction: 0.25,
            frames_done: Some(1),
            frames_total: Some(4),
        });

        let mut telemetry = None;
        let mut progress = None;
        while let Ok(event) = events.try_recv() {
            match event.payload {
                EventPayload::Imaging(ImagingEvent::IntegrationTelemetry {
                    run_id,
                    kind,
                    detail_json,
                }) if run_id == "bus-wiring" => telemetry = Some((kind, detail_json)),
                EventPayload::Imaging(ImagingEvent::IntegrationProgress {
                    phase,
                    fraction,
                    frames_done,
                    frames_total,
                }) if phase == "bus-wiring" => {
                    progress = Some((fraction, frames_done, frames_total))
                }
                _ => {}
            }
        }
        assert_eq!(
            telemetry,
            Some(("registered".to_string(), r#"{"index":3}"#.to_string()))
        );
        assert_eq!(progress, Some((0.25, Some(1), Some(4))));
    }
}
