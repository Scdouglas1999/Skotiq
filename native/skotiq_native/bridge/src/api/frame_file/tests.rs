use super::{api_read_frame_header, api_write_frame_wcs, FrameHeaderRead, FrameWcs};
use skotiq_imaging::{write_fits, FitsHeader, ImageData, PixelType, SipWcs};
use std::path::{Path, PathBuf};

fn scratch(name: &str) -> PathBuf {
    let dir = tempfile::tempdir().unwrap().keep();
    dir.join(name)
}

fn read(path: &Path) -> FrameHeaderRead {
    tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(api_read_frame_header(path.to_string_lossy().into_owned()))
        .unwrap()
}

fn text<'a>(read: &'a FrameHeaderRead, keyword: &str) -> Option<&'a str> {
    read.cards
        .iter()
        .find(|c| c.keyword == keyword)
        .map(|c| c.text.as_str())
}

fn number(read: &FrameHeaderRead, keyword: &str) -> Option<f64> {
    read.cards
        .iter()
        .find(|c| c.keyword == keyword)
        .and_then(|c| c.number)
}

/// A FITS file whose header is exactly `cards` (each padded to 80 columns),
/// with a 4x3 16-bit image.
fn fits_with_cards(path: &Path, cards: &[&str]) {
    let mut header: Vec<u8> = Vec::new();
    for card in [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                    4",
        "NAXIS2  =                    3",
    ]
    .iter()
    .chain(cards)
    .chain(["END"].iter())
    {
        header.extend(format!("{card:<80}").bytes());
    }
    header.resize(header.len().div_ceil(2880) * 2880, b' ');
    let mut data = vec![0u8; 4 * 3 * 2];
    data.resize(2880, 0);
    std::fs::write(path, [header, data].concat()).unwrap();
}

/// A monolithic XISF file as PixInsight writes one: the facts in XISF
/// properties and no FITSKeyword element.
fn xisf_properties_only(path: &Path) {
    let pixels = vec![0u8; 4 * 3 * 4];
    let xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><xisf version=\"1.0\" xmlns=\"http://www.pixinsight.com/xisf\">\
         <Image geometry=\"4:3:1\" sampleFormat=\"Float32\" bounds=\"0:1\" colorSpace=\"Gray\" location=\"attachment:4096:{}\">\
         <Property id=\"Instrument:Camera:Name\" type=\"String\">PI Test Camera</Property>\
         <Property id=\"Instrument:Filter:Name\" type=\"String\">Ha</Property>\
         <Property id=\"Instrument:Sensor:Temperature\" type=\"Float32\" value=\"-10\"/>\
         <Property id=\"Instrument:ExposureTime\" type=\"Float32\" value=\"300\"/>\
         </Image></xisf>",
        pixels.len()
    );
    let mut bytes = b"XISF0100".to_vec();
    bytes.extend((xml.len() as u32).to_le_bytes());
    bytes.extend(0u32.to_le_bytes());
    bytes.extend(xml.bytes());
    bytes.resize(4096, 0);
    bytes.extend(pixels);
    std::fs::write(path, bytes).unwrap();
}

#[test]
fn a_properties_only_xisf_reads_its_camera_filter_temperature_and_size() {
    let path = scratch("master.xisf");
    xisf_properties_only(&path);
    let read = read(&path);
    assert_eq!(text(&read, "INSTRUME"), Some("PI Test Camera"));
    assert_eq!(text(&read, "FILTER"), Some("Ha"));
    assert_eq!(number(&read, "CCD-TEMP"), Some(-10.0));
    assert_eq!(number(&read, "EXPTIME"), Some(300.0));
    assert_eq!(number(&read, "NAXIS1"), Some(4.0));
    assert_eq!(number(&read, "NAXIS2"), Some(3.0));
    assert!(read.wcs.is_none());
}

#[test]
fn long_strings_and_hierarch_keywords_read_whole() {
    let path = scratch("long.fits");
    fits_with_cards(
        &path,
        &[
            "OBJECT  = 'NGC7000-North-America-Nebula-and-Pelican-Cygnus-wide-field-mosaic-&'",
            "CONTINUE  'panel-3'",
            "HIERARCH SKOTIQ CAMERA MODEL = 'ASI2600MM'",
            "GAIN    =                  100",
        ],
    );
    let read = read(&path);
    assert_eq!(
        text(&read, "OBJECT"),
        Some("NGC7000-North-America-Nebula-and-Pelican-Cygnus-wide-field-mosaic-panel-3")
    );
    assert_eq!(text(&read, "SKOTIQ CAMERA MODEL"), Some("ASI2600MM"));
    assert_eq!(number(&read, "GAIN"), Some(100.0));
    assert_eq!(text(&read, "GAIN"), Some("100"));
    assert_eq!(number(&read, "OBJECT"), None);
}

#[test]
fn a_pc_form_header_reads_as_its_cd_matrix() {
    let path = scratch("pc.fits");
    fits_with_cards(
        &path,
        &[
            "CTYPE1  = 'RA---TAN'",
            "CTYPE2  = 'DEC--TAN'",
            "CRVAL1  =                40.53",
            "CRVAL2  =                42.76",
            "CRPIX1  =                  2.5",
            "CRPIX2  =                  2.0",
            "CDELT1  =            -0.000275",
            "CDELT2  =             0.000275",
            "PC1_1   =                  0.0",
            "PC1_2   =                  1.0",
            "PC2_1   =                 -1.0",
            "PC2_2   =                  0.0",
        ],
    );
    let wcs = read(&path).wcs.expect("a PC-form header states a WCS");
    assert_eq!(
        (wcs.crval1, wcs.crval2, wcs.crpix1, wcs.crpix2),
        (40.53, 42.76, 2.5, 2.0)
    );
    assert_eq!(
        (wcs.cd1_1, wcs.cd1_2, wcs.cd2_1, wcs.cd2_2),
        (0.0, -0.000275, -0.000275, 0.0)
    );
}

#[test]
fn a_written_wcs_replaces_the_astrometry_the_frame_held() {
    let path = scratch("solved.fits");
    let mut header = FitsHeader::new();
    header.set_string("OBJECT", "M34");
    let mut distorted = SipWcs::from_pointing(40.5, 42.8, 30.0, 1.2, 4, 3);
    distorted.a_order = 2;
    distorted.b_order = 2;
    distorted.a_coeffs = vec![0.0, 0.0, 1e-6, 0.0, 2e-6, 0.0, 3e-6, 0.0, 0.0];
    distorted.b_coeffs = vec![0.0, 0.0, 4e-6, 0.0, 5e-6, 0.0, 6e-6, 0.0, 0.0];
    distorted.write_to_header(&mut header);
    header.set_float("PC1_1", 1.0);
    write_fits(&path, &ImageData::new(4, 3, 1, PixelType::U16), &header).unwrap();

    let plain = FrameWcs::from(SipWcs::from_pointing(10.0, -5.0, 0.0, 2.0, 4, 3));
    tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(api_write_frame_wcs(
            path.to_string_lossy().into_owned(),
            plain.clone(),
        ))
        .unwrap();

    let read = read(&path);
    let wcs = read.wcs.clone().expect("the written solution reads back");
    assert_eq!(
        (wcs.crval1, wcs.crval2, wcs.crpix1, wcs.crpix2),
        (10.0, -5.0, 2.5, 2.0)
    );
    for (got, want) in [
        (wcs.cd1_1, plain.cd1_1),
        (wcs.cd1_2, plain.cd1_2),
        (wcs.cd2_1, plain.cd2_1),
        (wcs.cd2_2, plain.cd2_2),
    ] {
        assert!(
            (got - want).abs() <= 1e-10 * want.abs().max(1e-6),
            "{got} vs {want}"
        );
    }
    assert_eq!(
        (wcs.a_order, wcs.b_order, wcs.ap_order, wcs.bp_order),
        (0, 0, 0, 0)
    );
    assert_eq!(text(&read, "CTYPE1"), Some("RA---TAN"));
    assert_eq!(text(&read, "OBJECT"), Some("M34"));
    for gone in ["PC1_1", "A_ORDER", "B_ORDER", "A_0_2", "B_2_0"] {
        assert_eq!(text(&read, gone), None, "{gone} outlived the new solution");
    }
}

#[test]
fn a_color_frame_states_its_channels() {
    let path = scratch("rgb.fits");
    write_fits(
        &path,
        &ImageData::new(4, 3, 3, PixelType::U16),
        &FitsHeader::new(),
    )
    .unwrap();
    let read = read(&path);
    assert_eq!(number(&read, "NAXIS3"), Some(3.0));
}

#[test]
fn a_file_that_is_no_frame_is_refused() {
    let path = scratch("notes.txt");
    std::fs::write(&path, "not a frame").unwrap();
    let refused = tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(api_read_frame_header(path.to_string_lossy().into_owned()));
    assert!(refused.is_err());
}
