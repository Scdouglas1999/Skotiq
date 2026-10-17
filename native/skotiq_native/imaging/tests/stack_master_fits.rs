//! The live stack's data product is a FITS master.
//!
//! The live stacker is fed pixels, not headers: an in-memory frame arrives as a
//! raw `u16` buffer with no `EXPTIME` and no `DATE-OBS` to copy. These tests pin
//! the contract that made the master save-able as FITS at all — both keywords
//! are synthesized from the stack's own provenance, and what they are based on
//! is disclosed in the card comment rather than guessed at.

use std::collections::HashMap;

use chrono::{TimeZone, Utc};
use skotiq_imaging::stack_master::{write_stack_master, FrameProvenance, StackProvenance};
use skotiq_imaging::{read_fits, ImageData};

fn gradient_frame(width: u32, height: u32) -> ImageData {
    let pixels: Vec<u16> = (0..(width as usize * height as usize))
        .map(|i| (i % 4096) as u16)
        .collect();
    ImageData::from_u16(width, height, 1, &pixels)
}

#[test]
fn headerless_stack_still_writes_exptime_and_date_obs() {
    let started = Utc.with_ymd_and_hms(2026, 8, 14, 3, 21, 9).unwrap();
    let mut provenance = StackProvenance::started_at(started);
    for _ in 0..3 {
        provenance.fold(&FrameProvenance::unknown());
    }

    let dir = std::env::temp_dir().join("sk-stack-master-headerless");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("master.fits");
    write_stack_master(&path, &gradient_frame(16, 12), &provenance).unwrap();

    let (image, header) = read_fits(&path).unwrap();
    assert_eq!(image.width, 16);
    assert_eq!(image.height, 12);

    // Present and readable — a stack with no per-frame headers is still a FITS
    // master, not a PNG.
    assert_eq!(header.get_float("EXPTIME"), Some(0.0));
    assert_eq!(
        header.get_string("DATE-OBS"),
        Some("2026-08-14T03:21:09.000")
    );
    assert_eq!(header.get_int("NFRAMES"), Some(3));

    // ...and the header says why the integration is zero instead of letting a
    // stacking tool read 0 s as a measurement.
    let exptime_comment = header.get_comment("EXPTIME").unwrap();
    assert!(
        exptime_comment.contains("no stacked frame reported EXPTIME"),
        "EXPTIME comment must disclose the unknown integration, got: {exptime_comment}"
    );
    let date_comment = header.get_comment("DATE-OBS").unwrap();
    assert!(
        date_comment.contains("live stack started"),
        "DATE-OBS comment must disclose the synthesized stamp, got: {date_comment}"
    );

    std::fs::remove_file(&path).ok();
}

#[test]
fn frame_headers_sum_into_total_integration_and_earliest_date_obs() {
    let mut provenance =
        StackProvenance::started_at(Utc.with_ymd_and_hms(2026, 8, 14, 3, 21, 9).unwrap());
    // Deliberately out of order: the earliest frame owns DATE-OBS, not the first
    // one handed to the stacker.
    for date_obs in [
        "2026-08-14T03:25:00.000",
        "2026-08-14T03:22:30.000",
        "2026-08-14T03:27:30.000",
    ] {
        provenance.fold(&FrameProvenance {
            exposure_secs: Some(120.0),
            date_obs: Some(date_obs.to_string()),
        });
    }

    let dir = std::env::temp_dir().join("sk-stack-master-headers");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("master.fits");
    write_stack_master(&path, &gradient_frame(8, 8), &provenance).unwrap();

    let (_, header) = read_fits(&path).unwrap();
    assert_eq!(header.get_float("EXPTIME"), Some(360.0));
    assert_eq!(
        header.get_string("DATE-OBS"),
        Some("2026-08-14T03:22:30.000")
    );
    assert!(header
        .get_comment("EXPTIME")
        .unwrap()
        .contains("total integration of 3 stacked frames"));

    std::fs::remove_file(&path).ok();
}

#[test]
fn partial_frame_headers_report_how_many_frames_were_counted() {
    let mut provenance =
        StackProvenance::started_at(Utc.with_ymd_and_hms(2026, 8, 14, 3, 21, 9).unwrap());
    provenance.fold(&FrameProvenance {
        exposure_secs: Some(60.0),
        date_obs: Some("2026-08-14T03:22:30".to_string()),
    });
    provenance.fold(&FrameProvenance::unknown());

    assert_eq!(provenance.total_integration_secs(), 60.0);
    let header = provenance.to_fits_header();
    let comment = header.get_comment("EXPTIME").unwrap();
    assert!(
        comment.contains("1 of 2 stacked frames"),
        "a partially-headered stack must say how many frames it counted, got: {comment}"
    );
    // A second-precision DATE-OBS is still a real observation stamp.
    assert_eq!(
        header.get_string("DATE-OBS"),
        Some("2026-08-14T03:22:30.000")
    );
}

#[test]
fn frame_provenance_reads_the_keywords_a_read_image_header_carries() {
    let mut header = HashMap::new();
    header.insert("EXPTIME".to_string(), "180.0".to_string());
    header.insert(
        "DATE-OBS".to_string(),
        "2026-08-14T03:22:30.500".to_string(),
    );

    let provenance = FrameProvenance::from_header_map(&header);
    assert_eq!(provenance.exposure_secs, Some(180.0));
    assert_eq!(
        provenance.date_obs.as_deref(),
        Some("2026-08-14T03:22:30.500")
    );

    // A frame with neither keyword is "unknown", never zero-by-default.
    assert_eq!(
        FrameProvenance::from_header_map(&HashMap::new()),
        FrameProvenance::unknown()
    );
}
