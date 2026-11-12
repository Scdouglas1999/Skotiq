//! Forwarding a capability trait to a wrapped device layer.

#[doc(hidden)]
pub use async_trait::async_trait;

/// Implement capability traits for a wrapper by forwarding every method,
/// defaulted ones included, to one of its fields.
///
/// A wrapper that changes one capability writes that trait by hand and
/// forwards the rest:
///
/// ```ignore
/// forward_device_ops!(RecordingOps => inner: MountOps, FocuserOps, SiteOps);
/// ```
#[macro_export]
macro_rules! forward_device_ops {
    ($ty:ty => $field:ident: $($capability:ident),+ $(,)?) => {
        $( $crate::forward_device_ops!(@$capability $ty, $field); )+
    };
    (@MountOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::MountOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::MountOps for $ty {
                async fn mount_slew_to_coordinates(&self, mount_id: &str, ra_hours: f64, dec_degrees: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_slew_to_coordinates(mount_id, ra_hours, dec_degrees).await
                }
                async fn mount_abort_slew(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_abort_slew(mount_id).await
                }
                async fn mount_get_coordinates(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<(f64, f64)> {
                    self.$field.mount_get_coordinates(mount_id).await
                }
                async fn mount_readback_frame(&self, mount_id: &str, ra_hours: f64, dec_degrees: f64) -> $crate::device_ops::DeviceResult<(f64, f64)> {
                    self.$field.mount_readback_frame(mount_id, ra_hours, dec_degrees).await
                }
                async fn mount_readback_to_j2000(&self, mount_id: &str, ra_hours: f64, dec_degrees: f64) -> $crate::device_ops::DeviceResult<(f64, f64)> {
                    self.$field.mount_readback_to_j2000(mount_id, ra_hours, dec_degrees).await
                }
                async fn mount_sync(&self, mount_id: &str, ra_hours: f64, dec_degrees: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_sync(mount_id, ra_hours, dec_degrees).await
                }
                async fn mount_park(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_park(mount_id).await
                }
                async fn mount_unpark(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_unpark(mount_id).await
                }
                async fn mount_find_home(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_find_home(mount_id).await
                }
                async fn mount_is_at_home(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.mount_is_at_home(mount_id).await
                }
                async fn mount_is_slewing(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.mount_is_slewing(mount_id).await
                }
                async fn mount_slew_state(&self, mount_id: &str) -> $crate::slew_arrival::SlewSample {
                    self.$field.mount_slew_state(mount_id).await
                }
                async fn mount_is_parked(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.mount_is_parked(mount_id).await
                }
                async fn mount_can_flip(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.mount_can_flip(mount_id).await
                }
                async fn mount_side_of_pier(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<$crate::meridian::PierSide> {
                    self.$field.mount_side_of_pier(mount_id).await
                }
                async fn mount_is_tracking(&self, mount_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.mount_is_tracking(mount_id).await
                }
                async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_set_tracking(mount_id, enabled).await
                }
                async fn mount_move_axis(&self, mount_id: &str, axis: i32, rate_deg_per_sec: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.mount_move_axis(mount_id, axis, rate_deg_per_sec).await
                }
                async fn request_mount_fault_hold(&self, mount_id: &str, message: &str) {
                    self.$field.request_mount_fault_hold(mount_id, message).await
                }
            }
        };
    };
    (@CameraOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::CameraOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::CameraOps for $ty {
                async fn camera_start_exposure(&self, request: $crate::device_ops::ExposureRequest<'_>) -> $crate::device_ops::DeviceResult<$crate::device_ops::ImageData> {
                    self.$field.camera_start_exposure(request).await
                }
                async fn camera_abort_exposure(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.camera_abort_exposure(camera_id).await
                }
                async fn camera_set_cooler(&self, camera_id: &str, enabled: bool, target_temp: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.camera_set_cooler(camera_id, enabled, target_temp).await
                }
                async fn camera_get_temperature(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<f64> {
                    self.$field.camera_get_temperature(camera_id).await
                }
                async fn camera_get_cooler_power(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<f64> {
                    self.$field.camera_get_cooler_power(camera_id).await
                }
                async fn camera_get_cooler_on(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<Option<bool>> {
                    self.$field.camera_get_cooler_on(camera_id).await
                }
                async fn camera_get_cooler_setpoint(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<Option<f64>> {
                    self.$field.camera_get_cooler_setpoint(camera_id).await
                }
                async fn camera_get_pixel_size_um(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<Option<(f64, f64)>> {
                    self.$field.camera_get_pixel_size_um(camera_id).await
                }
                async fn camera_get_model(&self, camera_id: &str) -> $crate::device_ops::DeviceResult<Option<String>> {
                    self.$field.camera_get_model(camera_id).await
                }
            }
        };
    };
    (@FocuserOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::FocuserOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::FocuserOps for $ty {
                async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.focuser_move_to(focuser_id, position).await
                }
                async fn focuser_get_position(&self, focuser_id: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.focuser_get_position(focuser_id).await
                }
                async fn focuser_is_moving(&self, focuser_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.focuser_is_moving(focuser_id).await
                }
                async fn focuser_get_temperature(&self, focuser_id: &str) -> $crate::device_ops::DeviceResult<Option<f64>> {
                    self.$field.focuser_get_temperature(focuser_id).await
                }
                async fn focuser_halt(&self, focuser_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.focuser_halt(focuser_id).await
                }
            }
        };
    };
    (@FilterWheelOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::FilterWheelOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::FilterWheelOps for $ty {
                async fn filterwheel_set_position(&self, fw_id: &str, position: i32) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.filterwheel_set_position(fw_id, position).await
                }
                async fn filterwheel_get_position(&self, fw_id: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.filterwheel_get_position(fw_id).await
                }
                async fn filterwheel_get_names(&self, fw_id: &str) -> $crate::device_ops::DeviceResult<Vec<String>> {
                    self.$field.filterwheel_get_names(fw_id).await
                }
                async fn filterwheel_set_filter_by_name(&self, fw_id: &str, name: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.filterwheel_set_filter_by_name(fw_id, name).await
                }
            }
        };
    };
    (@RotatorOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::RotatorOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::RotatorOps for $ty {
                async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.rotator_move_to(rotator_id, angle).await
                }
                async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.rotator_move_relative(rotator_id, delta).await
                }
                async fn rotator_get_angle(&self, rotator_id: &str) -> $crate::device_ops::DeviceResult<f64> {
                    self.$field.rotator_get_angle(rotator_id).await
                }
                async fn rotator_halt(&self, rotator_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.rotator_halt(rotator_id).await
                }
            }
        };
    };
    (@GuiderOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::GuiderOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::GuiderOps for $ty {
                async fn guider_dither(&self, pixels: f64, settle_pixels: f64, settle_time: f64, settle_timeout: f64, ra_only: bool) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.guider_dither(pixels, settle_pixels, settle_time, settle_timeout, ra_only).await
                }
                async fn guider_get_status(&self) -> $crate::device_ops::DeviceResult<$crate::device_ops::GuidingStatus> {
                    self.$field.guider_get_status().await
                }
                async fn guider_is_active(&self) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.guider_is_active().await
                }
                async fn guider_get_calibration(&self) -> $crate::device_ops::DeviceResult<$crate::device_ops::GuidingCalibration> {
                    self.$field.guider_get_calibration().await
                }
                async fn guider_start(&self, settle_pixels: f64, settle_time: f64, settle_timeout: f64) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.guider_start(settle_pixels, settle_time, settle_timeout).await
                }
                async fn guider_select_fresh_star(&self) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.guider_select_fresh_star().await
                }
                async fn guider_select_fresh_star_above(&self, floor: $crate::device_ops::GuideStarFloor) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.guider_select_fresh_star_above(floor).await
                }
                async fn guider_star_quality(&self) -> $crate::device_ops::DeviceResult<Option<$crate::device_ops::GuideStarQuality>> {
                    self.$field.guider_star_quality().await
                }
                async fn guider_stop(&self) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.guider_stop().await
                }
                async fn guider_note_stop_reason(&self, reason: Option<$crate::GuidingStopReason>) {
                    self.$field.guider_note_stop_reason(reason).await
                }
            }
        };
    };
    (@DomeOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::DomeOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::DomeOps for $ty {
                async fn active_dome_id(&self) -> Option<String> {
                    self.$field.active_dome_id().await
                }
                async fn dome_open(&self, dome_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.dome_open(dome_id).await
                }
                async fn dome_close(&self, dome_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.dome_close(dome_id).await
                }
                async fn dome_park(&self, dome_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.dome_park(dome_id).await
                }
                async fn dome_get_shutter_status(&self, dome_id: &str) -> $crate::device_ops::DeviceResult<String> {
                    self.$field.dome_get_shutter_status(dome_id).await
                }
            }
        };
    };
    (@CoverCalibratorOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::CoverCalibratorOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::CoverCalibratorOps for $ty {
                async fn active_cover_calibrator_id(&self) -> Option<String> {
                    self.$field.active_cover_calibrator_id().await
                }
                async fn cover_calibrator_open_cover(&self, device_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.cover_calibrator_open_cover(device_id).await
                }
                async fn cover_calibrator_close_cover(&self, device_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.cover_calibrator_close_cover(device_id).await
                }
                async fn cover_calibrator_halt_cover(&self, device_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.cover_calibrator_halt_cover(device_id).await
                }
                async fn cover_calibrator_calibrator_on(&self, device_id: &str, brightness: i32) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.cover_calibrator_calibrator_on(device_id, brightness).await
                }
                async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.cover_calibrator_calibrator_off(device_id).await
                }
                async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.cover_calibrator_get_cover_state(device_id).await
                }
                async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.cover_calibrator_get_calibrator_state(device_id).await
                }
                async fn cover_calibrator_get_brightness(&self, device_id: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.cover_calibrator_get_brightness(device_id).await
                }
                async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> $crate::device_ops::DeviceResult<i32> {
                    self.$field.cover_calibrator_get_max_brightness(device_id).await
                }
            }
        };
    };
    (@SafetyOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::SafetyOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::SafetyOps for $ty {
                async fn safety_is_safe(&self, safety_id: Option<&str>) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.safety_is_safe(safety_id).await
                }
                async fn weather_get_humidity(&self, weather_id: Option<&str>) -> $crate::device_ops::DeviceResult<Option<f64>> {
                    self.$field.weather_get_humidity(weather_id).await
                }
            }
        };
    };
    (@PlateSolveOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::PlateSolveOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::PlateSolveOps for $ty {
                async fn plate_solve(&self, image_data: &$crate::device_ops::ImageData, hint_ra: Option<f64>, hint_dec: Option<f64>, hint_scale: Option<f64>) -> $crate::device_ops::DeviceResult<$crate::device_ops::PlateSolveResult> {
                    self.$field.plate_solve(image_data, hint_ra, hint_dec, hint_scale).await
                }
            }
        };
    };
    (@FrameStoreOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::FrameStoreOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::FrameStoreOps for $ty {
                async fn save_fits(&self, image_data: &$crate::device_ops::ImageData, file_path: &str, frame_ctx: &$crate::scheduling::FrameContext) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.save_fits(image_data, file_path, frame_ctx).await
                }
                async fn measure_light_frame(&self, image_data: &$crate::device_ops::ImageData) -> $crate::device_ops::DeviceResult<$crate::device_ops::LightFrameMeasurement> {
                    self.$field.measure_light_frame(image_data).await
                }
            }
        };
    };
    (@OperatorNotifyOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::OperatorNotifyOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::OperatorNotifyOps for $ty {
                async fn send_notification(&self, level: &str, title: &str, message: &str, explicit_transports: Option<&[String]>) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.send_notification(level, title, message, explicit_transports).await
                }
                async fn polar_align_update(&self, result: &$crate::PolarAlignResult) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.polar_align_update(result).await
                }
            }
        };
    };
    (@ConnectionOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::ConnectionOps as _;
            #[$crate::device_ops::forward::async_trait]
            impl $crate::device_ops::ConnectionOps for $ty {
                async fn device_is_connected(&self, device_id: &str) -> $crate::device_ops::DeviceResult<bool> {
                    self.$field.device_is_connected(device_id).await
                }
                async fn connect_device(&self, device_id: &str) -> $crate::device_ops::DeviceResult<()> {
                    self.$field.connect_device(device_id).await
                }
            }
        };
    };
    (@SiteOps $ty:ty, $field:ident) => {
        const _: () = {
            #[allow(unused_imports)]
            use $crate::device_ops::SiteOps as _;
            impl $crate::device_ops::SiteOps for $ty {
                fn get_observer_location(&self) -> Option<(f64, f64)> {
                    self.$field.get_observer_location()
                }
            }
        };
    };
}
