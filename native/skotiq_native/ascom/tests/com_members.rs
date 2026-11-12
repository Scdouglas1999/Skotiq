//! The COM call behind every ASCOM device wrapper method.
//!
//! COM itself only exists on Windows, but the wrappers reach a driver through
//! `ComDispatch` alone. This test puts a recording stand-in behind each
//! wrapper, calls every method with fixed arguments, and writes one line per
//! method: the member name the driver is asked for, how it is dispatched, the
//! VARIANT type and value of each argument in positional order, the type of
//! the reply, and the text the caller gets when the driver refuses the call
//! or answers with the wrong type. The lines are compared with
//! `tests/golden/com_members.txt`, which was first generated from the
//! hand-written wrappers, so a changed member name, argument order, VARIANT
//! type or error text is a test failure on any host.
//!
//! Regenerate with `SKOTIQ_COM_GOLDEN=update cargo test -p skotiq_ascom --test
//! com_members` and review the diff: real drivers are sensitive to every
//! column.

use skotiq_ascom::com::{ComArg, ComCall, ComDispatch, ComKind, ComValue, Dispatch};
use skotiq_ascom::{
    AscomResult, Camera, ConnectionHealth, CoverCalibrator, Dome, FilterWheel, Focuser, Mount,
    ObservingConditions, Rotator, SafetyMonitor, Switch,
};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

#[derive(Clone, Copy, PartialEq)]
enum Reply {
    Value,
    Refuse,
    WrongType,
}

struct State {
    reply: Reply,
    log: Vec<String>,
    last_returns: ComKind,
}

/// Stands in for a driver: records each call and answers as told.
#[derive(Clone)]
struct Recorder(Rc<RefCell<State>>);

impl Recorder {
    fn new() -> Self {
        Recorder(Rc::new(RefCell::new(State {
            reply: Reply::Value,
            log: Vec::new(),
            last_returns: ComKind::Void,
        })))
    }

    fn note(&self, line: &str) {
        self.0.borrow_mut().log.push(line.to_string());
    }
}

fn kind_name(kind: ComKind) -> &'static str {
    match kind {
        ComKind::Void => "void",
        ComKind::Bool => "BOOL",
        ComKind::I4 => "I4",
        ComKind::R8 => "R8",
        ComKind::Date => "DATE",
        ComKind::Bstr => "BSTR",
        ComKind::BstrArray => "SAFEARRAY(BSTR)",
        ComKind::I4Array => "SAFEARRAY(I4)",
    }
}

fn arg_text(arg: &ComArg<'_>) -> String {
    match arg {
        ComArg::Bool(v) => format!("BOOL {v}"),
        ComArg::I4(v) => format!("I4 {v}"),
        ComArg::R8(v) => format!("R8 {v:?}"),
        ComArg::Date(v) => format!("DATE {v:?}"),
        ComArg::Bstr(v) => format!("BSTR {v:?}"),
    }
}

impl ComDispatch for Recorder {
    fn invoke(&self, call: &ComCall<'_>) -> AscomResult<ComValue> {
        let dispatch = match call.dispatch {
            Dispatch::Get => "get",
            Dispatch::Put => "put",
            Dispatch::Method => "method",
        };
        let args: Vec<String> = call.args.iter().map(arg_text).collect();
        let mut state = self.0.borrow_mut();
        state.log.push(format!(
            "{dispatch} {}({}) -> {}",
            call.member,
            args.join(", "),
            kind_name(call.returns)
        ));
        state.last_returns = call.returns;
        match state.reply {
            Reply::Refuse => Err(call.invoke_error("{cause}".to_string(), None)),
            Reply::WrongType => Err(call.type_error(99, Some("{detail}".to_string()))),
            Reply::Value => Ok(match call.returns {
                ComKind::Void => ComValue::Empty,
                ComKind::Bool => ComValue::Bool(true),
                ComKind::I4 => ComValue::I4(7),
                ComKind::R8 => ComValue::R8(1.25),
                ComKind::Date => ComValue::Date(45_000.5),
                ComKind::Bstr => ComValue::Bstr("text".to_string()),
                ComKind::BstrArray => ComValue::BstrArray(vec!["a".to_string(), "b".to_string()]),
                ComKind::I4Array => ComValue::I4Array {
                    data: vec![1, 2, 3, 4],
                    dim1: 2,
                    dim2: 2,
                },
            }),
        }
    }

    fn connect(&mut self) -> AscomResult<()> {
        self.note("connection.connect");
        Ok(())
    }

    fn disconnect(&mut self) -> AscomResult<()> {
        self.note("connection.disconnect");
        Ok(())
    }

    fn heartbeat(&self) -> AscomResult<()> {
        self.note("connection.heartbeat");
        Ok(())
    }

    fn health(&self) -> ConnectionHealth {
        self.note("connection.get_health");
        ConnectionHealth::Healthy
    }
}

/// Run one wrapper call against the recorder and describe it in one line.
fn describe(
    recorder: &Recorder,
    label: &str,
    mut call: impl FnMut() -> Result<(), String>,
) -> String {
    let set = |reply| {
        let mut state = recorder.0.borrow_mut();
        state.reply = reply;
        state.log.clear();
    };

    set(Reply::Value);
    if let Err(e) = call() {
        panic!("{label} failed against an agreeable driver: {e}");
    }
    let log = recorder.0.borrow().log.clone();
    assert_eq!(
        log.len(),
        1,
        "{label} should make exactly one call: {log:?}"
    );
    let entry = &log[0];
    if entry.starts_with("connection.") {
        return format!("{label} | {entry}");
    }

    set(Reply::Refuse);
    let refused = call().expect_err("a refused call must fail");
    let wrong_type = if recorder.0.borrow().last_returns == ComKind::Void {
        "-".to_string()
    } else {
        set(Reply::WrongType);
        call()
            .expect_err("a wrongly typed reply must fail")
            .replace("VARIANT type=99", "VARIANT type={vt}")
    };
    format!("{label} | {entry} | {refused} | {wrong_type}")
}

/// `row!("call text", d.call(args))`: `d` is the wrapper under test.
macro_rules! rows {
    ($lines:ident, $name:literal, $wrapper:ident; $( row!($label:literal, d.$($call:tt)+); )*) => {{
        let recorder = Recorder::new();
        #[allow(unused_mut)]
        let mut d = $wrapper::over(recorder.clone());
        $(
            $lines.push(describe(&recorder, concat!($name, "::", $label), || {
                let _ = d.$($call)+.map_err(|e| e.to_string())?;
                Ok(())
            }));
        )*
    }};
}

fn member_lines() -> Vec<String> {
    let mut lines = Vec::new();
    rows! { lines, "AscomCamera", Camera;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("setup_dialog()", d.setup_dialog());
        row!("name()", d.name());
        row!("description()", d.description());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("camera_x_size()", d.camera_x_size());
        row!("camera_y_size()", d.camera_y_size());
        row!("pixel_size_x()", d.pixel_size_x());
        row!("pixel_size_y()", d.pixel_size_y());
        row!("max_bin_x()", d.max_bin_x());
        row!("max_bin_y()", d.max_bin_y());
        row!("bin_x()", d.bin_x());
        row!("bin_y()", d.bin_y());
        row!("set_bin_x(1)", d.set_bin_x(1));
        row!("set_bin_y(1)", d.set_bin_y(1));
        row!("can_set_ccd_temperature()", d.can_set_ccd_temperature());
        row!("ccd_temperature()", d.ccd_temperature());
        row!("ccd_temperature_setpoint()", d.ccd_temperature_setpoint());
        row!("set_ccd_temperature(1.5)", d.set_ccd_temperature(1.5));
        row!("cooler_on()", d.cooler_on());
        row!("set_cooler_on(true)", d.set_cooler_on(true));
        row!("cooler_power()", d.cooler_power());
        row!("gain()", d.gain());
        row!("set_gain(1)", d.set_gain(1));
        row!("offset()", d.offset());
        row!("set_offset(1)", d.set_offset(1));
        row!("gains()", d.gains());
        row!("offsets()", d.offsets());
        row!("exposure_min()", d.exposure_min());
        row!("exposure_max()", d.exposure_max());
        row!("camera_state()", d.camera_state());
        row!("image_ready()", d.image_ready());
        row!("percent_completed()", d.percent_completed());
        row!("start_exposure(1.5, true)", d.start_exposure(1.5, true));
        row!("start_exposure(0.0, false)", d.start_exposure(0.0, false));
        row!("abort_exposure()", d.abort_exposure());
        row!("stop_exposure()", d.stop_exposure());
        row!("image_array()", d.image_array());
        row!("readout_modes()", d.readout_modes());
        row!("set_readout_mode(1)", d.set_readout_mode(1));
        row!("sensor_type()", d.sensor_type());
        row!("bayer_offset_x()", d.bayer_offset_x());
        row!("bayer_offset_y()", d.bayer_offset_y());
        row!("start_x()", d.start_x());
        row!("start_y()", d.start_y());
        row!("num_x()", d.num_x());
        row!("num_y()", d.num_y());
        row!("set_start_x(1)", d.set_start_x(1));
        row!("set_start_y(1)", d.set_start_y(1));
        row!("set_num_x(1)", d.set_num_x(1));
        row!("set_num_y(1)", d.set_num_y(1));
        row!("can_abort_exposure()", d.can_abort_exposure());
        row!("can_stop_exposure()", d.can_stop_exposure());
        row!("has_shutter()", d.has_shutter());
        row!("sensor_name()", d.sensor_name());
        row!("max_adu()", d.max_adu());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomCoverCalibrator", CoverCalibrator;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("cover_state()", d.cover_state());
        row!("calibrator_state()", d.calibrator_state());
        row!("brightness()", d.brightness());
        row!("set_brightness(1)", d.set_brightness(1));
        row!("max_brightness()", d.max_brightness());
        row!("open_cover()", d.open_cover());
        row!("close_cover()", d.close_cover());
        row!("halt_cover()", d.halt_cover());
        row!("calibrator_on(1)", d.calibrator_on(1));
        row!("calibrator_off()", d.calibrator_off());
        row!("cover_moving()", d.cover_moving());
        row!("calibrator_changing()", d.calibrator_changing());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomDome", Dome;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("open_shutter()", d.open_shutter());
        row!("close_shutter()", d.close_shutter());
        row!("park()", d.park());
        row!("shutter_status()", d.shutter_status());
        row!("at_park()", d.at_park());
        row!("slewing()", d.slewing());
        row!("azimuth()", d.azimuth());
        row!("slew_to_azimuth(1.5)", d.slew_to_azimuth(1.5));
        row!("abort_slew()", d.abort_slew());
        row!("find_home()", d.find_home());
        row!("set_slaved(true)", d.set_slaved(true));
        row!("altitude()", d.altitude());
        row!("at_home()", d.at_home());
        row!("slaved()", d.slaved());
        row!("can_find_home()", d.can_find_home());
        row!("can_park()", d.can_park());
        row!("can_set_altitude()", d.can_set_altitude());
        row!("can_set_azimuth()", d.can_set_azimuth());
        row!("can_set_shutter()", d.can_set_shutter());
        row!("can_slave()", d.can_slave());
        row!("can_sync_azimuth()", d.can_sync_azimuth());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomFilterWheel", FilterWheel;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("position()", d.position());
        row!("set_position(1)", d.set_position(1));
        row!("names()", d.names());
        row!("focus_offsets()", d.focus_offsets());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomFocuser", Focuser;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("position()", d.position());
        row!("max_step()", d.max_step());
        row!("max_increment()", d.max_increment());
        row!("step_size()", d.step_size());
        row!("is_moving()", d.is_moving());
        row!("absolute()", d.absolute());
        row!("temp_comp()", d.temp_comp());
        row!("set_temp_comp(true)", d.set_temp_comp(true));
        row!("temp_comp_available()", d.temp_comp_available());
        row!("temperature()", d.temperature());
        row!("move_to(1)", d.move_to(1));
        row!("halt()", d.halt());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomMount", Mount;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("right_ascension()", d.right_ascension());
        row!("target_right_ascension()", d.target_right_ascension());
        row!("set_target_right_ascension(1.5)", d.set_target_right_ascension(1.5));
        row!("declination()", d.declination());
        row!("target_declination()", d.target_declination());
        row!("set_target_declination(1.5)", d.set_target_declination(1.5));
        row!("altitude()", d.altitude());
        row!("azimuth()", d.azimuth());
        row!("side_of_pier()", d.side_of_pier());
        row!("sidereal_time()", d.sidereal_time());
        row!("site_latitude()", d.site_latitude());
        row!("set_site_latitude(1.5)", d.set_site_latitude(1.5));
        row!("site_longitude()", d.site_longitude());
        row!("set_site_longitude(1.5)", d.set_site_longitude(1.5));
        row!("site_elevation()", d.site_elevation());
        row!("set_site_elevation(1.5)", d.set_site_elevation(1.5));
        row!("utc_date()", d.utc_date());
        row!("set_utc_date(1.5)", d.set_utc_date(1.5));
        row!("does_refraction()", d.does_refraction());
        row!("set_does_refraction(true)", d.set_does_refraction(true));
        row!("tracking()", d.tracking());
        row!("set_tracking(true)", d.set_tracking(true));
        row!("slewing()", d.slewing());
        row!("at_park()", d.at_park());
        row!("at_home()", d.at_home());
        row!("can_park()", d.can_park());
        row!("can_find_home()", d.can_find_home());
        row!("can_set_park()", d.can_set_park());
        row!("alignment_mode()", d.alignment_mode());
        row!("can_unpark()", d.can_unpark());
        row!("can_slew()", d.can_slew());
        row!("can_slew_async()", d.can_slew_async());
        row!("can_sync()", d.can_sync());
        row!("can_set_tracking()", d.can_set_tracking());
        row!("park()", d.park());
        row!("unpark()", d.unpark());
        row!("abort_slew()", d.abort_slew());
        row!("find_home()", d.find_home());
        row!("set_park()", d.set_park());
        row!("slew_to_coordinates_async(1.5, 2.5)", d.slew_to_coordinates_async(1.5, 2.5));
        row!("slew_to_coordinates(1.5, 2.5)", d.slew_to_coordinates(1.5, 2.5));
        row!("sync_to_coordinates(1.5, 2.5)", d.sync_to_coordinates(1.5, 2.5));
        row!("slew_to_alt_az_async(1.5, 2.5)", d.slew_to_alt_az_async(1.5, 2.5));
        row!("can_pulse_guide()", d.can_pulse_guide());
        row!("is_pulse_guiding()", d.is_pulse_guiding());
        row!("pulse_guide(1, 2)", d.pulse_guide(1, 2));
        row!("guide_rate_right_ascension()", d.guide_rate_right_ascension());
        row!("guide_rate_declination()", d.guide_rate_declination());
        row!("set_guide_rate_right_ascension(1.5)", d.set_guide_rate_right_ascension(1.5));
        row!("set_guide_rate_declination(1.5)", d.set_guide_rate_declination(1.5));
        row!("tracking_rate()", d.tracking_rate());
        row!("set_tracking_rate(1)", d.set_tracking_rate(1));
        row!("can_move_axis(1)", d.can_move_axis(1));
        row!("move_axis(1, 2.5)", d.move_axis(1, 2.5));
        row!("equatorial_system()", d.equatorial_system());
        row!("can_set_pier_side()", d.can_set_pier_side());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomObservingConditions", ObservingConditions;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("cloud_cover()", d.cloud_cover());
        row!("dew_point()", d.dew_point());
        row!("humidity()", d.humidity());
        row!("pressure()", d.pressure());
        row!("rain_rate()", d.rain_rate());
        row!("sky_brightness()", d.sky_brightness());
        row!("sky_quality()", d.sky_quality());
        row!("sky_temperature()", d.sky_temperature());
        row!("star_fwhm()", d.star_fwhm());
        row!("temperature()", d.temperature());
        row!("wind_direction()", d.wind_direction());
        row!("wind_gust()", d.wind_gust());
        row!("wind_speed()", d.wind_speed());
        row!("refresh()", d.refresh());
        row!("average_period()", d.average_period());
        row!("set_average_period(1.5)", d.set_average_period(1.5));
        row!("time_since_last_update(\"arg1\")", d.time_since_last_update("arg1"));
        row!("sensor_description(\"arg1\")", d.sensor_description("arg1"));
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomRotator", Rotator;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("position()", d.position());
        row!("mechanical_position()", d.mechanical_position());
        row!("is_moving()", d.is_moving());
        row!("can_reverse()", d.can_reverse());
        row!("reverse()", d.reverse());
        row!("set_reverse(true)", d.set_reverse(true));
        row!("target_position()", d.target_position());
        row!("step_size()", d.step_size());
        row!("move_relative(1.5)", d.move_relative(1.5));
        row!("move_absolute(1.5)", d.move_absolute(1.5));
        row!("halt()", d.halt());
        row!("sync(1.5)", d.sync(1.5));
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomSafetyMonitor", SafetyMonitor;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("is_safe()", d.is_safe());
        row!("heartbeat()", d.heartbeat());
    }
    rows! { lines, "AscomSwitch", Switch;
        row!("connect()", d.connect());
        row!("disconnect()", d.disconnect());
        row!("is_connected()", d.is_connected());
        row!("name()", d.name());
        row!("interface_version()", d.interface_version());
        row!("driver_version()", d.driver_version());
        row!("driver_info()", d.driver_info());
        row!("supported_actions()", d.supported_actions());
        row!("max_switch()", d.max_switch());
        row!("get_switch(1)", d.get_switch(1));
        row!("set_switch(1, true)", d.set_switch(1, true));
        row!("get_switch_name(1)", d.get_switch_name(1));
        row!("get_switch_description(1)", d.get_switch_description(1));
        row!("get_switch_value(1)", d.get_switch_value(1));
        row!("set_switch_value(1, 2.5)", d.set_switch_value(1, 2.5));
        row!("min_switch_value(1)", d.min_switch_value(1));
        row!("max_switch_value(1)", d.max_switch_value(1));
        row!("switch_step(1)", d.switch_step(1));
        row!("can_write(1)", d.can_write(1));
        row!("can_async(1)", d.can_async(1));
        row!("set_async(1, true)", d.set_async(1, true));
        row!("set_async_value(1, 2.5)", d.set_async_value(1, 2.5));
        row!("state_change_complete(1)", d.state_change_complete(1));
        row!("cancel_async(1)", d.cancel_async(1));
        row!("heartbeat()", d.heartbeat());
    }
    lines
}

#[test]
fn com_calls_match_the_golden_list() {
    let actual = member_lines().join("\n") + "\n";
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/com_members.txt");
    if std::env::var("SKOTIQ_COM_GOLDEN").as_deref() == Ok("update") {
        std::fs::write(&path, &actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    if expected == actual {
        return;
    }
    let actual_path = std::env::temp_dir().join("skotiq-ascom-com-members.actual.txt");
    std::fs::write(&actual_path, &actual).unwrap();
    let first = expected
        .lines()
        .zip(actual.lines())
        .position(|(e, a)| e != a)
        .unwrap_or_else(|| expected.lines().count().min(actual.lines().count()));
    panic!(
        "COM member list differs from {} at line {}:\n  golden: {}\n  actual: {}\nfull actual list: {}",
        path.display(),
        first + 1,
        expected.lines().nth(first).unwrap_or("<end>"),
        actual.lines().nth(first).unwrap_or("<end>"),
        actual_path.display(),
    );
}
