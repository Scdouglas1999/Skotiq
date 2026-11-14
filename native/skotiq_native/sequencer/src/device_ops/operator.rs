//! What a run tells the operator.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait OperatorNotifyOps: Send + Sync {
    /// Send a notification.
    ///
    /// `explicit_transports`, when `Some`, carries
    /// per-NotificationNode override transport names (NotificationTransportKind
    /// from the Dart side, serialised as strings). Bridge implementations emit
    /// this field on the user-visible event so `NotificationRouter` can route
    /// to the user-picked transports instead of the matrix's `custom` rule.
    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()>;

    async fn polar_align_update(
        &self,
        result: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()>;
}
