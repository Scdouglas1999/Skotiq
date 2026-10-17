//! Global Event Bus for cross-component communication
//!
//! Events are published by various components and can be subscribed to
//! by the Dart side to update UI and trigger reactions.
//!
//! # Features
//!
//! - **Sequence Numbers**: Each event has a unique, monotonically increasing ID
//! - **Causality Tracking**: Events can reference the event that caused them
//! - **Category-based Filtering**: Subscribe to specific event categories
//! - **Overflow Handling**: Graceful handling when event buffer is full with diagnostics
//!
//! # Buffer Size
//!
//! The default buffer size is 4096 events (`DEFAULT_EVENT_BUFFER_SIZE`). This is sized
//! to handle burst scenarios like rapid autofocus loops or high-frequency guiding updates
//! without dropping events. If the buffer fills up (slow consumer), events are logged
//! and counted for diagnostics.
//!
//! # Example
//!
//! ```rust
//! let bus = EventBus::new(DEFAULT_EVENT_BUFFER_SIZE);
//!
//! // Publish an event
//! let event_id = bus.publish_with_tracking(
//!     EventSeverity::Info,
//!     EventCategory::Equipment,
//!     EventPayload::Equipment(EquipmentEvent::Connected { .. }),
//!     None, // No causal parent
//! );
//!
//! // Publish a follow-up event with causality
//! bus.publish_with_tracking(
//!     EventSeverity::Info,
//!     EventCategory::Imaging,
//!     EventPayload::Imaging(ImagingEvent::ExposureStarted { .. }),
//!     Some(event_id), // This was caused by the connection event
//! );
//! ```

use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

pub mod bus;
pub use bus::*;
pub mod depthlock_events;
pub use depthlock_events::*;
mod correlation;
pub use correlation::*;
pub mod equipment;
pub use equipment::*;
pub mod guiding;
pub use guiding::*;
pub mod imaging;
pub use imaging::*;
pub mod sequencer;
pub use sequencer::*;
pub mod system;
pub use system::*;
