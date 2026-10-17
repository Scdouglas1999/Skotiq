//! Atik Camera SDK Bindings
//!
//! Native driver for Atik cameras using their official Artemis SDK.
//! Supports Atik Horizon, ACIS, APX, and older series cameras.

use crate::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ImageMetadata, ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use crate::sync::atik_mutex;
use crate::traits::{NativeCamera, NativeDevice, NativeError, NativeFilterWheel};
use crate::NativeVendor;
use async_trait::async_trait;
use std::collections::HashMap;
use std::ffi::{c_char, c_float, c_int, c_void, CStr};
use std::sync::{Mutex, OnceLock};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod filter_wheel;
mod sdk;

pub use camera::*;
pub use discovery::*;
use ffi::*;
pub use filter_wheel::*;
use sdk::*;

#[cfg(test)]
mod sdk_loader_tests {
    use super::*;

    #[test]
    fn efw_entry_points_stay_optional() {
        // Every Atik SDK build older than the EFW API exports none of these.
        // Promoting one to the required table would make such a build fail to
        // load entirely, so no Atik camera would be visible either.
        let required = AtikSdk::required_symbol_names();
        assert!(
            !required.iter().any(|name| name.starts_with("efw_")),
            "an EFW entry point became mandatory: {:?}",
            required
        );
        assert!(!required.contains(&"refresh_devices_count"));
        assert!(required.contains(&"device_count"));
        assert_eq!(required.len(), 28);
    }
}

#[cfg(test)]
mod colour_classification_tests {
    use super::*;

    /// ARTEMISCOLOURTYPE 0 is UNKNOWN — "either the device is not a camera or
    /// the colour cannot be determined" (AtikDefs.h:56) — and it is also the
    /// value `connect`'s out-parameter keeps when ArtemisColourProperties
    /// fails. It must never resolve to a sensor description: publishing mono
    /// for an undetermined sensor strips BAYERPAT from every frame of the
    /// session, so a one-shot-colour camera images all night undebayered.
    #[test]
    fn unknown_colour_type_is_not_a_sensor_description() {
        assert_eq!(atik_sensor_colour(ARTEMIS_COLOUR_UNKNOWN), None);
        // The seed the connect path initialises the out-parameter with is
        // exactly that value, so a swallowed SDK failure cannot masquerade as
        // an answer.
        assert_eq!(ARTEMIS_COLOUR_UNKNOWN, 0);
    }

    /// Monochrome is a value the SDK reports explicitly; only that value may
    /// publish a mono sensor.
    #[test]
    fn none_colour_type_is_mono_with_no_bayer_pattern() {
        let colour = atik_sensor_colour(ARTEMIS_COLOUR_NONE).expect("mono is determinate");
        assert_eq!(colour, AtikSensorColour::Mono);
        assert!(!colour.is_color());
        assert_eq!(colour.bayer_pattern(), None);
    }

    #[test]
    fn rggb_colour_type_publishes_the_rggb_bayer_pattern() {
        let colour = atik_sensor_colour(ARTEMIS_COLOUR_RGGB).expect("RGGB is determinate");
        assert_eq!(colour, AtikSensorColour::Rggb);
        assert!(colour.is_color());
        assert_eq!(colour.bayer_pattern(), Some(BayerPattern::Rggb));
    }

    /// A colour type a future SDK adds is as undetermined as UNKNOWN for this
    /// build: we know it is not the RGGB we can debayer, and we do not know it
    /// is mono either.
    #[test]
    fn unrecognised_colour_types_are_undetermined_not_mono() {
        for colour_type in [-1, 3, 4, 99] {
            assert_eq!(
                atik_sensor_colour(colour_type),
                None,
                "colour type {colour_type} was resolved to a sensor description"
            );
        }
    }

    /// A named sensor is published as named.
    #[test]
    fn a_named_colour_type_is_published() {
        assert_eq!(
            atik_colour_decision(ArtemisError::Ok, ARTEMIS_COLOUR_RGGB),
            AtikColourDecision::Publish(AtikSensorColour::Rggb)
        );
        assert_eq!(
            atik_colour_decision(ArtemisError::Ok, ARTEMIS_COLOUR_NONE),
            AtikColourDecision::Publish(AtikSensorColour::Mono)
        );
    }

    /// A body whose driver has no colour property still images.
    ///
    /// Older mono bodies and older AtikCameras builds answer NotImplemented, and
    /// refusing that answer made them impossible to connect — a camera that
    /// imaged fine in 6.2.0 became unusable. Mono is not a guess here: a camera
    /// with no colour property is not a CFA sensor, and `bayer_pattern: None` is
    /// already the "do not debayer" state.
    #[test]
    fn a_driver_without_the_colour_property_connects_as_mono() {
        for outcome in [ArtemisError::NotImplemented, ArtemisError::InvalidFunction] {
            match atik_colour_decision(outcome, ARTEMIS_COLOUR_UNKNOWN) {
                AtikColourDecision::ConnectAsMono(reason) => {
                    assert!(
                        reason.contains("ArtemisColourProperties"),
                        "the warning names the call that had no answer: {reason}"
                    );
                }
                other => panic!("{outcome:?} must not block the connect: {other:?}"),
            }
        }
    }

    /// UNKNOWN is the SDK declining to determine the array, not a failure to
    /// reach the camera: connect as mono and say so.
    #[test]
    fn an_undetermined_colour_type_connects_as_mono() {
        match atik_colour_decision(ArtemisError::Ok, ARTEMIS_COLOUR_UNKNOWN) {
            AtikColourDecision::ConnectAsMono(reason) => {
                assert!(reason.contains("ARTEMIS_COLOUR_UNKNOWN"), "{reason}");
            }
            other => panic!("UNKNOWN must not block the connect: {other:?}"),
        }
    }

    /// A CFA the SDK names and this build cannot map is still refused — that is
    /// a real colour filter array whose layout we would be guessing at.
    #[test]
    fn an_unmappable_colour_filter_array_is_still_refused() {
        for colour_type in [3, 4, 99] {
            match atik_colour_decision(ArtemisError::Ok, colour_type) {
                AtikColourDecision::Refuse(reason) => {
                    assert!(reason.contains(&colour_type.to_string()), "{reason}");
                }
                other => panic!("colour type {colour_type} must be refused: {other:?}"),
            }
        }
    }

    /// A call that reached the camera and failed is a transport failure, and
    /// those still refuse: the sensor description is unknown for a reason that
    /// says the link itself is bad.
    #[test]
    fn a_transport_failure_still_refuses_the_connect() {
        for outcome in [
            ArtemisError::NotConnected,
            ArtemisError::NoResponse,
            ArtemisError::OperationFailed,
            ArtemisError::InvalidParameter,
        ] {
            assert!(
                matches!(
                    atik_colour_decision(outcome, ARTEMIS_COLOUR_UNKNOWN),
                    AtikColourDecision::Refuse(_)
                ),
                "{outcome:?} is a transport failure and must refuse"
            );
        }
    }
}
