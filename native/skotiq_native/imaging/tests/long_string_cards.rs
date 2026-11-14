//! A header string longer than one card is written with the FITS long-string
//! convention (FITS 4.0 section 4.2.1.2: `&` and `CONTINUE`) and read back
//! whole, so no value can stop a frame from being saved.

use skotiq_imaging::{read_fits, read_fits_header, write_fits, FitsHeader, ImageData};
use std::path::{Path, PathBuf};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("long-string-cards-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn frame() -> ImageData {
    ImageData::from_u16(4, 3, 1, &(0..12).collect::<Vec<u16>>())
}

/// The header records of a FITS file, one string per 80-byte card, up to END.
fn cards(path: &Path) -> Vec<String> {
    let bytes = std::fs::read(path).unwrap();
    let mut out = Vec::new();
    for record in bytes.chunks(80) {
        let card = String::from_utf8(record.to_vec()).unwrap();
        let end = card.starts_with("END ");
        out.push(card);
        if end {
            return out;
        }
    }
    panic!("no END card");
}

fn dark_path(len: usize) -> String {
    let stem = "/home/observer/Astrophotography/Calibration Library/ZWO ASI2600MM Pro/";
    let name = "master_dark_300s_gain100_offset50_-10C.fits";
    let filler = len - stem.len() - name.len();
    let path = format!("{stem}{}/{name}", "d".repeat(filler - 1));
    assert_eq!(path.len(), len);
    path
}

#[test]
fn a_150_character_darkfile_is_written_and_read_back_whole() {
    let path = scratch("darkfile.fits");
    let dark = dark_path(150);
    let mut header = FitsHeader::new();
    header.set_string("OBJECT", "M31");
    header.set_string("DARKFILE", &dark);
    header.set_comment("DARKFILE", "master dark subtracted");
    header.set_float("EXPTIME", 300.0);

    write_fits(&path, &frame(), &header).expect("a long string never fails the write");

    let (image, read) = read_fits(&path).unwrap();
    assert_eq!(read.get_string("DARKFILE"), Some(dark.as_str()));
    assert_eq!(read.get_comment("DARKFILE"), Some("master dark subtracted"));
    assert_eq!(read.get_string("OBJECT"), Some("M31"));
    assert_eq!(read.get_float("EXPTIME"), Some(300.0));
    assert_eq!(image.as_u16().unwrap(), (0..12).collect::<Vec<u16>>());
    assert_eq!(
        read_fits_header(&path).unwrap().get_string("DARKFILE"),
        Some(dark.as_str()),
        "the header-only read joins the pieces too"
    );

    let cards = cards(&path);
    assert!(
        cards.iter().any(|c| c.starts_with("LONGSTRN= 'OGIP 1.0'")),
        "the header announces the convention: {cards:#?}"
    );
    let first = cards
        .iter()
        .position(|c| c.starts_with("DARKFILE= '"))
        .unwrap();
    assert!(cards[first].trim_end().ends_with("&'"), "{}", cards[first]);
    assert!(
        cards[first + 1].starts_with("CONTINUE  '"),
        "{}",
        cards[first + 1]
    );
    assert!(
        cards[first + 2].starts_with("CONTINUE  '"),
        "{}",
        cards[first + 2]
    );
    assert!(
        cards[first + 2].contains("/ master dark subtracted"),
        "the comment rides on the last piece: {}",
        cards[first + 2]
    );
    assert!(!cards[first + 3].starts_with("CONTINUE"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn quotes_ampersands_and_spaces_survive_any_split() {
    let values = [
        // A quote pair straddling where a card would end.
        format!("{}O'Brien's field", "x".repeat(60)),
        // Quotes only, so the escaped text is twice the length.
        "'".repeat(90),
        // A literal ampersand at a piece boundary and at the very end.
        format!("{}&{}&", "a".repeat(66), "b".repeat(30)),
        // Spaces at a piece boundary stay; leading text of a piece is kept.
        format!("{}   {}", "c".repeat(64), "d".repeat(40)),
        // Non-ASCII text is written in its ASCII spelling, then split.
        "Région de la nébuleuse d'Orion — ".repeat(4),
    ];
    let ascii = "Region de la nebuleuse d'Orion - ".repeat(4);
    for (index, value) in values.iter().enumerate() {
        let expected = if index == 4 { &ascii } else { value };
        let path = scratch(&format!("split-{index}.fits"));
        let mut header = FitsHeader::new();
        header.set_string("OBJECT", value);
        header.set_string("FILTER", "Ha");
        write_fits(&path, &frame(), &header).unwrap();
        let (_, read) = read_fits(&path).unwrap();
        assert_eq!(
            read.get_string("OBJECT"),
            Some(expected.trim_end()),
            "value {index}"
        );
        assert_eq!(read.get_string("FILTER"), Some("Ha"));
        for card in cards(&path) {
            assert_eq!(card.len(), 80, "every card is one record");
        }
        let _ = std::fs::remove_file(&path);
    }
}

#[test]
fn a_header_without_long_strings_does_not_announce_the_convention() {
    let path = scratch("short.fits");
    let mut header = FitsHeader::new();
    header.set_string("OBJECT", &"N".repeat(68));
    write_fits(&path, &frame(), &header).unwrap();
    let cards = cards(&path);
    assert!(!cards
        .iter()
        .any(|c| c.starts_with("LONGSTRN") || c.starts_with("CONTINUE")));
    let (_, read) = read_fits(&path).unwrap();
    assert_eq!(read.get_string("OBJECT"), Some("N".repeat(68).as_str()));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_rewritten_long_string_header_keeps_one_announcement() {
    let path = scratch("rewrite.fits");
    let mut header = FitsHeader::new();
    header.set_string("OBSERVER", &"Observer ".repeat(15));
    write_fits(&path, &frame(), &header).unwrap();
    let (image, read) = read_fits(&path).unwrap();
    assert!(
        read.get("LONGSTRN").is_none(),
        "the reader folds the convention away"
    );
    write_fits(&path, &image, &read).unwrap();
    let cards = cards(&path);
    assert_eq!(
        cards.iter().filter(|c| c.starts_with("LONGSTRN")).count(),
        1
    );
    let (_, again) = read_fits(&path).unwrap();
    assert_eq!(
        again.get_string("OBSERVER"),
        Some("Observer ".repeat(15).trim_end())
    );
    let _ = std::fs::remove_file(&path);
}

/// What other writers produce: a short value ending in `&` with no CONTINUE
/// after it keeps its ampersand, and a CONTINUE with nothing to continue is
/// ignored, as cfitsio reads them.
#[test]
fn a_lone_ampersand_and_an_orphan_continue_read_as_cfitsio_reads_them() {
    let records = [
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    1",
        "NAXIS2  =                    1",
        "OBJECT  = 'AT&T&'",
        "FILTER  = 'Ha'",
        "CONTINUE  'stray'",
        "OBSERVER= 'first &'",
        "CONTINUE  ' second&' / one",
        "CONTINUE  'third' / two",
        "END",
    ];
    let mut bytes = Vec::new();
    for record in records {
        let mut card = record.as_bytes().to_vec();
        card.resize(80, b' ');
        bytes.extend_from_slice(&card);
    }
    bytes.resize(2880, b' ');
    bytes.push(7);
    bytes.resize(5760, 0);
    let (_, header) = skotiq_imaging::read_fits_from_bytes(&bytes).unwrap();
    assert_eq!(header.get_string("OBJECT"), Some("AT&T&"));
    assert_eq!(header.get_string("FILTER"), Some("Ha"));
    assert_eq!(header.get_string("OBSERVER"), Some("first  secondthird"));
    assert_eq!(header.get_comment("OBSERVER"), Some("one two"));
    assert!(header.get("CONTINUE").is_none());
}

/// XISF keeps a FITS keyword's value in an attribute with no card width, so a
/// long value goes in whole, in one FITSKeyword, with no convention card.
#[test]
fn an_xisf_frame_keeps_a_long_value_in_one_keyword() {
    let path = scratch("darkfile.xisf");
    let dark = dark_path(150);
    let mut header = FitsHeader::new();
    header.set_string("DARKFILE", &dark);
    skotiq_imaging::write_frame(&path, &frame(), &header).unwrap();

    let (_, read) = skotiq_imaging::read_frame(&path).unwrap();
    assert_eq!(read.get_string("DARKFILE"), Some(dark.as_str()));
    let text = String::from_utf8_lossy(&std::fs::read(&path).unwrap()).into_owned();
    assert!(
        text.contains(&format!("value=\"&apos;{dark}&apos;\"")),
        "one keyword holds the value"
    );
    assert!(!text.contains("LONGSTRN") && !text.contains("CONTINUE"));
    let _ = std::fs::remove_file(&path);
}
