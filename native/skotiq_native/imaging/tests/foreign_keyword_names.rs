//! A card whose name is no FITS keyword (too long, with spaces, as foreign XISF
//! files and HIERARCH headers carry) never fails a FITS write: it is written as
//! a HIERARCH card, or as a COMMENT line when even that cannot hold it, and a
//! HIERARCH card in a FITS file survives a read and a rewrite.

use skotiq_imaging::{
    read_fits, read_frame, write_fits, write_frame, FitsHeader, FitsValue, ImageData,
};
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("foreign-keyword-names-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn frame() -> ImageData {
    ImageData::from_u16(4, 3, 1, &(0..12).collect::<Vec<u16>>())
}

fn header_cards(path: &PathBuf) -> Vec<String> {
    let bytes = std::fs::read(path).unwrap();
    let mut cards = Vec::new();
    for record in bytes.chunks(80) {
        let card = String::from_utf8_lossy(record).trim_end().to_string();
        let end = card == "END";
        cards.push(card);
        if end {
            return cards;
        }
    }
    panic!("no END card");
}

#[test]
fn an_xisf_frame_with_foreign_names_is_written_as_fits_with_every_card() {
    let long_value = "a site description far too long to share one card with its name".repeat(2);
    let mut header = FitsHeader::new();
    header.set_string("OBJECT", "M31");
    header.set_float("EXPOSURE_TIME_SECONDS", 300.0);
    header.set_comment("EXPOSURE_TIME_SECONDS", "seconds");
    header.set_string("Observatory Name", "Roll-off roof");
    header.set_int("HIERARCH ESO DET NDIT", 12);
    header.set_string("RATIO=ONE", "kept as text");
    header.set_string("SITE DESCRIPTION", &long_value);
    let xisf = scratch("foreign.xisf");
    write_frame(&xisf, &frame(), &header).unwrap();

    let (image, from_xisf) = read_frame(&xisf).unwrap();
    let fits = scratch("foreign.fits");
    write_fits(&fits, &image, &from_xisf).expect("a foreign name never fails the FITS write");

    let (pixels, read) = read_fits(&fits).unwrap();
    assert_eq!(pixels.as_u16().unwrap(), (0..12).collect::<Vec<u16>>());
    assert_eq!(read.get_string("OBJECT"), Some("M31"));
    assert_eq!(read.get_float("EXPOSURE_TIME_SECONDS"), Some(300.0));
    assert_eq!(read.get_comment("EXPOSURE_TIME_SECONDS"), Some("seconds"));
    assert_eq!(read.get_string("OBSERVATORY NAME"), Some("Roll-off roof"));
    assert_eq!(read.get_int("ESO DET NDIT"), Some(12));
    assert!(
        read.comments
            .contains(&"RATIO=ONE = 'kept as text'".to_string()),
        "a name with '=' is kept as text: {:?}",
        read.comments
    );
    assert!(
        read.comments
            .contains(&format!("SITE DESCRIPTION = '{long_value}'")),
        "a value HIERARCH cannot hold is kept as text: {:?}",
        read.comments
    );

    let cards = header_cards(&fits);
    assert!(cards.contains(&"HIERARCH EXPOSURE_TIME_SECONDS = 300.0 / seconds".to_string()));
    assert!(cards.contains(&"HIERARCH OBSERVATORY NAME = 'Roll-off roof'".to_string()));
    assert!(
        cards.contains(&"HIERARCH ESO DET NDIT = 12".to_string()),
        "{cards:#?}"
    );
    assert!(cards.iter().all(|c| c.len() <= 80));
}

/// A HIERARCH card from another program's FITS file is kept when Skotiq
/// rewrites the file's header, as it does to add a plate solve.
#[test]
fn a_hierarch_card_survives_a_header_rewrite() {
    let records = [
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    1",
        "NAXIS2  =                    1",
        "HIERARCH ESO DET DIT = 1.5 / integration time",
        "HIERARCH ESO OBS NAME = 'Deep field'",
        "HIERARCH= 7",
        "END",
    ];
    let mut bytes = Vec::new();
    for record in records {
        let mut card = record.as_bytes().to_vec();
        card.resize(80, b' ');
        bytes.extend_from_slice(&card);
    }
    bytes.resize(2880, b' ');
    bytes.push(9);
    bytes.resize(5760, 0);
    let path = scratch("hierarch.fits");
    std::fs::write(&path, &bytes).unwrap();

    let wcs = skotiq_imaging::SipWcs::from_pointing(10.0, 41.0, 12.0, 1.5, 1, 1);
    skotiq_imaging::write_wcs_into_frame(&path, &wcs).unwrap();

    let (_, header) = read_fits(&path).unwrap();
    assert!(matches!(header.get("ESO DET DIT"), Some(FitsValue::Float(v)) if *v == 1.5));
    assert_eq!(header.get_comment("ESO DET DIT"), Some("integration time"));
    assert_eq!(header.get_string("ESO OBS NAME"), Some("Deep field"));
    assert_eq!(
        header.get_int("HIERARCH"),
        Some(7),
        "a plain card named HIERARCH"
    );
    assert_eq!(header.get_float("CRVAL1"), Some(10.0));
}
