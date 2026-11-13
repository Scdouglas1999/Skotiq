use super::UnifiedDeviceOps;
use crate::event::bus::EventPayload;
use crate::event::correlation::create_event_auto_id;
use crate::event::equipment::{EventCategory, EventSeverity};
use crate::event::imaging::PolarAlignmentEvent;
use crate::event::system::SystemEvent;
use async_trait::async_trait;
use skotiq_sequencer::{DeviceResult, OperatorNotifyOps, PolarAlignResult};

#[async_trait]
impl OperatorNotifyOps for UnifiedDeviceOps {
    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()> {
        tracing::info!(
            "[NOTIFICATION][{}] {}: {}",
            level.to_uppercase(),
            title,
            message
        );

        // Publish as event to the event bus
        let severity = match level {
            "error" => EventSeverity::Error,
            "warning" => EventSeverity::Warning,
            _ => EventSeverity::Info,
        };

        self.app_state.publish_event(create_event_auto_id(
            severity,
            EventCategory::System,
            EventPayload::System(SystemEvent::Notification {
                title: title.to_string(),
                message: message.to_string(),
                level: level.to_string(),
                explicit_transports: explicit_transports.map(|s| s.to_vec()),
            }),
        ));

        Ok(())
    }

    async fn polar_align_update(&self, result: &PolarAlignResult) -> DeviceResult<()> {
        tracing::info!(
            "Polar Align Update: Alt {:.1}', Az {:.1}'",
            result.altitude_error,
            result.azimuth_error
        );

        let event = PolarAlignmentEvent {
            azimuth_error: result.azimuth_error,
            altitude_error: result.altitude_error,
            total_error: result.total_error,
            current_ra: result.current_ra,
            current_dec: result.current_dec,
            target_ra: result.target_ra,
            target_dec: result.target_dec,
        };

        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::PolarAlignment,
            EventPayload::PolarAlignment(event),
        ));

        Ok(())
    }
}
