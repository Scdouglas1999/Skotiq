//! DepthLock's "taken the same way" answers: which lights pool with a goal
//! and which masters calibrate it, with the sentence the operator reads for
//! each refusal.

use skotiq_imaging::depthlock::input::{
    check_compatible, light_settings, validate_master, AcquisitionSettings, CompatibilityPolicy,
    MasterKind, ReferenceGeometry,
};
use skotiq_imaging::{FitsHeader, ImageData, ProductCards, SipWcs};

fn light_header() -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "Light");
    h.set_string("INSTRUME", "ZWO ASI2600MM Pro");
    h.set_string("FILTER", "L");
    h.set_float("EXPTIME", 120.0);
    h.set_int("GAIN", 100);
    h.set_int("OFFSET", 50);
    h.set_int("XBINNING", 1);
    h.set_int("YBINNING", 1);
    h.set_float("CCD-TEMP", -10.2);
    h.set_string("DATE-OBS", "2026-09-11T03:14:15.926");
    h
}

fn goal() -> AcquisitionSettings {
    light_settings(&light_header()).unwrap()
}

type Change = fn(&mut AcquisitionSettings);

#[test]
fn which_lights_pool_with_the_goal() {
    let none: Change = |_| {};
    let table: Vec<(&str, Change, Change, Result<(), &str>)> = vec![
        ("same acquisition", none, none, Ok(())),
        (
            "camera name in another case",
            none,
            |l| l.instrument = "zwo asi2600mm pro".into(),
            Ok(()),
        ),
        (
            "another camera",
            none,
            |l| l.instrument = "ZWO ASI294MM".into(),
            Err("Camera differs: goal was defined for \"ZWO ASI2600MM Pro\", light is from \"ZWO ASI294MM\""),
        ),
        ("filter in another case", none, |l| l.filter = "l".into(), Ok(())),
        (
            "another filter",
            none,
            |l| l.filter = "Ha".into(),
            Err("Filter differs: goal is for \"L\", light was taken through \"Ha\""),
        ),
        (
            "filter name that only contains the goal's",
            none,
            |l| l.filter = "L 3nm".into(),
            Err("Filter differs: goal is for \"L\", light was taken through \"L 3nm\""),
        ),
        ("exposure within 0.1 %", none, |l| l.exposure_secs = 120.11, Ok(())),
        (
            "exposure beyond 0.1 %",
            none,
            |l| l.exposure_secs = 120.13,
            Err("Exposure differs: goal and its master dark are for 120.000 s, light is 120.130 s (DepthLock does not scale darks)"),
        ),
        (
            "exposure of the opposite sign",
            |g| g.exposure_secs = -120.0,
            none,
            Err("Exposure differs: goal and its master dark are for -120.000 s, light is 120.000 s (DepthLock does not scale darks)"),
        ),
        (
            "binned 2x2",
            none,
            |l| {
                l.bin_x = 2;
                l.bin_y = 2;
            },
            Err("Binning differs: goal is 1x1, light is 2x2"),
        ),
        (
            "binned in Y only",
            none,
            |l| l.bin_y = 2,
            Err("Binning differs: goal is 1x1, light is 1x2"),
        ),
        (
            "another gain",
            none,
            |l| l.gain = Some(101),
            Err("Gain differs: goal is 100, light is 101"),
        ),
        (
            "light silent on gain",
            none,
            |l| l.gain = None,
            Err("Gain differs: goal is 100, light is unstated"),
        ),
        (
            "another offset",
            none,
            |l| l.offset = Some(51),
            Err("Offset differs: goal is 50, light is 51"),
        ),
        (
            "light silent on offset",
            none,
            |l| l.offset = None,
            Err("Offset differs: goal is 50, light is unstated"),
        ),
        (
            "goal silent on gain and offset",
            |g| {
                g.gain = None;
                g.offset = None;
            },
            |l| {
                l.gain = Some(300);
                l.offset = None;
            },
            Ok(()),
        ),
        (
            "sensor 0.9 °C warmer",
            none,
            |l| l.ccd_temp_c = Some(-9.3),
            Ok(()),
        ),
        (
            "sensor 1.1 °C colder",
            none,
            |l| l.ccd_temp_c = Some(-11.3),
            Err("Sensor temperature differs by more than 1.0 °C: goal -10.2 °C, light -11.3 °C"),
        ),
        (
            "light silent on sensor temperature",
            none,
            |l| l.ccd_temp_c = None,
            Ok(()),
        ),
        (
            "goal silent on sensor temperature",
            |g| g.ccd_temp_c = None,
            |l| l.ccd_temp_c = Some(20.0),
            Ok(()),
        ),
        (
            "another filter and exposure",
            none,
            |l| {
                l.filter = "Ha".into();
                l.exposure_secs = 300.0;
            },
            Err("Filter differs: goal is for \"L\", light was taken through \"Ha\""),
        ),
        (
            "another gain and binning",
            none,
            |l| {
                l.gain = Some(200);
                l.bin_x = 2;
            },
            Err("Binning differs: goal is 1x1, light is 2x1"),
        ),
        (
            "another offset and sensor temperature",
            none,
            |l| {
                l.offset = Some(10);
                l.ccd_temp_c = Some(5.0);
            },
            Err("Offset differs: goal is 50, light is 10"),
        ),
        (
            "binning and sensor temperature",
            none,
            |l| {
                l.bin_y = 3;
                l.ccd_temp_c = Some(5.0);
            },
            Err("Binning differs: goal is 1x1, light is 1x3"),
        ),
        (
            "exposure and binning",
            none,
            |l| {
                l.exposure_secs = 60.0;
                l.bin_x = 2;
            },
            Err("Exposure differs: goal and its master dark are for 120.000 s, light is 60.000 s (DepthLock does not scale darks)"),
        ),
    ];
    let policy = CompatibilityPolicy::default();
    for (case, change_goal, change_light, expected) in table {
        let mut goal = goal();
        change_goal(&mut goal);
        let mut light = self::goal();
        change_light(&mut light);
        assert_eq!(
            check_compatible(&goal, &light, &policy),
            expected.map_err(str::to_string),
            "{case}"
        );
    }
}

#[test]
fn the_temperature_tolerance_is_the_policys() {
    let goal = goal();
    let mut light = self::goal();
    light.ccd_temp_c = Some(-10.9);
    let tight = CompatibilityPolicy {
        temperature_tolerance_c: 0.5,
    };
    assert_eq!(
        check_compatible(&goal, &light, &tight),
        Err("Sensor temperature differs by more than 0.5 °C: goal -10.2 °C, light -10.9 °C".into())
    );
    assert_eq!(
        check_compatible(&goal, &light, &CompatibilityPolicy::default()),
        Ok(())
    );
}

fn reference() -> SipWcs {
    let s = 1.5 / 3600.0;
    SipWcs::tan_only(83.8221, -5.3911, 32.5, 24.5, -s, 0.0, 0.0, s)
}

fn master_header(kind: &str) -> FitsHeader {
    let mut h = FitsHeader::new();
    ProductCards::master(kind, &format!("Skotiq master {kind}"))
        .with_frames(20)
        .write_to(&mut h);
    h
}

type CardChange = fn(&mut FitsHeader);

#[test]
fn which_masters_calibrate_the_goal() {
    let none: CardChange = |_| {};
    let table: Vec<(&str, MasterKind, CardChange, Result<(), &str>)> =
        vec![
        ("dark without acquisition cards", MasterKind::Dark, none, Ok(())),
        ("flat without acquisition cards", MasterKind::Flat, none, Ok(())),
        (
            "camera name padded and in another case",
            MasterKind::Dark,
            |h| h.set_string("INSTRUME", " zwo asi2600mm pro "),
            Ok(()),
        ),
        (
            "another camera",
            MasterKind::Flat,
            |h| h.set_string("INSTRUME", "ZWO ASI294MM"),
            Err("Master flat is from camera \"ZWO ASI294MM\", goal is for \"ZWO ASI2600MM Pro\""),
        ),
        (
            "dark exposure within 0.1 %",
            MasterKind::Dark,
            |h| h.set_float("EXPTIME", 120.11),
            Ok(()),
        ),
        (
            "dark exposure beyond 0.1 %",
            MasterKind::Dark,
            |h| h.set_float("EXPTIME", 120.13),
            Err("Master dark exposure 120.130 s does not match the goal's 120.000 s"),
        ),
        (
            "dark exposure under EXPOSURE only",
            MasterKind::Dark,
            |h| h.set_float("EXPOSURE", 300.0),
            Ok(()),
        ),
        (
            "flat exposure is not compared",
            MasterKind::Flat,
            |h| h.set_float("EXPTIME", 2.5),
            Ok(()),
        ),
        (
            "flat filter in another case",
            MasterKind::Flat,
            |h| h.set_string("FILTER", " l "),
            Ok(()),
        ),
        (
            "flat through another filter",
            MasterKind::Flat,
            |h| h.set_string("FILTER", "Ha"),
            Err("Master flat is for filter \"Ha\", goal is for \"L\""),
        ),
        (
            "dark filter is not compared",
            MasterKind::Dark,
            |h| h.set_string("FILTER", "Ha"),
            Ok(()),
        ),
        (
            "another gain",
            MasterKind::Dark,
            |h| h.set_int("GAIN", 101),
            Err("Master dark GAIN is 101, goal is 100"),
        ),
        (
            "fractional gain read whole",
            MasterKind::Dark,
            |h| h.set_float("GAIN", 100.7),
            Ok(()),
        ),
        (
            "another offset",
            MasterKind::Flat,
            |h| h.set_int("OFFSET", 49),
            Err("Master flat OFFSET is 49, goal is 50"),
        ),
        (
            "binned in X",
            MasterKind::Flat,
            |h| h.set_int("XBINNING", 2),
            Err("Master flat XBINNING is 2, goal is 1"),
        ),
        (
            "binned in Y",
            MasterKind::Dark,
            |h| h.set_int("YBINNING", 2),
            Err("Master dark YBINNING is 2, goal is 1"),
        ),
        (
            "sensor temperature is not compared",
            MasterKind::Dark,
            |h| h.set_float("CCD-TEMP", 20.0),
            Ok(()),
        ),
        (
            "read mode is not compared",
            MasterKind::Dark,
            |h| h.set_string("READOUTM", "High Gain"),
            Ok(()),
        ),
        (
            "another camera and gain",
            MasterKind::Dark,
            |h| {
                h.set_string("INSTRUME", "Other");
                h.set_int("GAIN", 0);
            },
            Err("Master dark is from camera \"Other\", goal is for \"ZWO ASI2600MM Pro\""),
        ),
        (
            "another exposure and gain",
            MasterKind::Dark,
            |h| {
                h.set_float("EXPTIME", 60.0);
                h.set_int("GAIN", 0);
            },
            Err("Master dark exposure 60.000 s does not match the goal's 120.000 s"),
        ),
        (
            "another filter and binning",
            MasterKind::Flat,
            |h| {
                h.set_string("FILTER", "R");
                h.set_int("XBINNING", 2);
            },
            Err("Master flat is for filter \"R\", goal is for \"L\""),
        ),
        (
            "another offset and binning",
            MasterKind::Flat,
            |h| {
                h.set_int("OFFSET", 0);
                h.set_int("YBINNING", 2);
            },
            Err("Master flat OFFSET is 0, goal is 50"),
        ),
        (
            "binned in X and Y",
            MasterKind::Dark,
            |h| {
                h.set_int("XBINNING", 2);
                h.set_int("YBINNING", 2);
            },
            Err("Master dark XBINNING is 2, goal is 1"),
        ),
    ];
    let geometry = ReferenceGeometry::from_wcs(&reference(), 64, 48).unwrap();
    for (case, kind, change, expected) in table {
        let (card, image) = match kind {
            MasterKind::Dark => ("DARK", ImageData::from_f32(64, 48, 1, &[1_000.0; 64 * 48])),
            MasterKind::Flat => ("FLAT", ImageData::from_f32(64, 48, 1, &[1.0; 64 * 48])),
        };
        let mut header = master_header(card);
        change(&mut header);
        assert_eq!(
            validate_master(kind, &header, &image, &goal(), &geometry),
            expected.map_err(str::to_string),
            "{case}"
        );
    }
}

#[test]
fn a_goal_silent_on_gain_takes_any_master_gain() {
    let mut goal = goal();
    goal.gain = None;
    let geometry = ReferenceGeometry::from_wcs(&reference(), 64, 48).unwrap();
    let mut header = master_header("DARK");
    header.set_int("GAIN", 300);
    let image = ImageData::from_f32(64, 48, 1, &[1_000.0; 64 * 48]);
    assert_eq!(
        validate_master(MasterKind::Dark, &header, &image, &goal, &geometry),
        Ok(())
    );
}
