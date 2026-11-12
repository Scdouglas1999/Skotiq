use super::block::BlockLocation;
use super::write::{attachment_positions, attachment_spans};
use super::*;
use crate::{read_bayer_geometry, read_frame, read_frame_header, rewrite_frame_header};
use crate::{write_frame_with, FitsHeader, FrameWriteOptions, PixelType};
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sk-xisf-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// A deterministic image of any type whose every sample differs from its
/// neighbors, so a misplaced byte shows.
fn test_image(w: u32, h: u32, channels: u32, pixel_type: PixelType) -> ImageData {
    let n = (w * h * channels) as usize;
    let mut image = ImageData::new(w, h, channels, pixel_type);
    let size = pixel_type.byte_size();
    for i in 0..n {
        let v = match pixel_type {
            PixelType::U8 => (i * 7 % 251) as f64,
            PixelType::U16 => (i * 2654435761 % 65521) as f64,
            PixelType::U32 => (i as u64 * 2654435761 % 4_294_967_291) as f64,
            PixelType::F32 | PixelType::F64 => ((i * 7919) % 10007) as f64 / 10007.0,
        };
        crate::samples::sample_to_le(&mut image.data[i * size..(i + 1) * size], pixel_type, v);
    }
    image
}

fn capture_header() -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_float("EXPTIME", 120.0);
    h.set_comment("EXPTIME", "Exposure time in seconds");
    h.set_string("DATE-OBS", "2026-11-11T07:12:06.250");
    h.set_string("IMAGETYP", "Light");
    h.set_string("OBJECT", "NGC 891");
    h.set_string("FILTER", "Ha");
    h.set_int("GAIN", 139);
    h.set_float("CCD-TEMP", -10.5);
    h.set_int("XBINNING", 1);
    h.set_int("YBINNING", 1);
    h.set_float("XPIXSZ", 3.76);
    h.set_float("FOCALLEN", 1016.0);
    h.set_float("SITELAT", 39.97);
    h.set_float("SITELONG", -75.5);
    h.set_float("RA", 35.639);
    h.set_float("DEC", 42.349);
    h.set_string("OBSERVER", "O'Brien");
    h.set_bool("MOSAICX", true);
    h.add_comment("Captured by Skotiq");
    h.add_history("Calibrated with master dark");
    h
}

fn cards(h: &FitsHeader) -> Vec<(String, String, Option<String>)> {
    h.cards()
        .map(|(k, v, c)| (k.to_string(), crate::fits::value_card_text(v), c.map(str::to_string)))
        .collect()
}

fn options(compression: Option<XisfCompression>, checksum: Option<ChecksumAlgorithm>) -> FrameWriteOptions {
    FrameWriteOptions {
        xisf: XisfWriteOptions {
            compression,
            checksum,
            thumbnail: true,
        },
    }
}

#[test]
fn every_sample_format_codec_and_shuffle_round_trips() {
    let header = capture_header();
    let mut compressions = vec![None];
    for codec in XisfCodec::ALL {
        for shuffle in [false, true] {
            compressions.push(Some(XisfCompression {
                codec,
                shuffle,
                level: None,
            }));
        }
    }
    for pixel_type in [
        PixelType::U8,
        PixelType::U16,
        PixelType::U32,
        PixelType::F32,
        PixelType::F64,
    ] {
        for channels in [1, 3] {
            let image = test_image(37, 23, channels, pixel_type);
            for (i, compression) in compressions.iter().enumerate() {
                let checksum = ChecksumAlgorithm::ALL.get(i % 6).copied();
                let path = scratch(&format!("rt-{pixel_type:?}-{channels}-{i}.xisf"));
                write_frame_with(&path, &image, &header, &options(*compression, checksum)).unwrap();
                let (back, back_header) = read_frame(&path).unwrap();
                let what = format!("{pixel_type:?} x{channels} {compression:?} {checksum:?}");
                assert_eq!(back.data, image.data, "{what}");
                assert_eq!(
                    (back.width, back.height, back.channels, back.pixel_type),
                    (image.width, image.height, image.channels, image.pixel_type),
                    "{what}"
                );
                assert_eq!(cards(&back_header), cards(&header), "{what}");
                assert_eq!(back_header.comments, header.comments, "{what}");
                assert_eq!(back_header.history, header.history, "{what}");
            }
        }
    }
}

#[test]
fn compressible_data_is_compressed_in_parallel_subblocks() {
    // Smooth 16-bit data over more than one subblock.
    let (w, h) = (2048u32, 1536u32);
    let samples: Vec<u16> = (0..w * h).map(|i| 1000 + ((i % w) / 8) as u16).collect();
    let image = ImageData::from_u16(w, h, 1, &samples);
    let path = scratch("subblocks.xisf");
    let zstd = XisfCompression {
        codec: XisfCodec::Zstd,
        shuffle: true,
        level: None,
    };
    write_frame_with(&path, &image, &FitsHeader::new(), &options(Some(zstd), None)).unwrap();
    let unit = read_xisf_unit(&path).unwrap();
    let block = unit.images[0].block.as_ref().unwrap();
    assert_eq!(block.compression.unwrap().shuffle_item, Some(2));
    assert!(block.subblocks.as_ref().is_some_and(|s| s.len() > 1));
    assert!(std::fs::metadata(&path).unwrap().len() < (w * h) as u64 / 4);
    assert_eq!(unit.read_pixels(0).unwrap().data, image.data);
}

#[test]
fn incompressible_data_is_stored_without_compression() {
    let mut state = 0x2545F4914F6CDD1Du64;
    let samples: Vec<u16> = (0..512 * 512)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u16
        })
        .collect();
    let image = ImageData::from_u16(512, 512, 1, &samples);
    let path = scratch("noise.xisf");
    let lz4 = XisfCompression {
        codec: XisfCodec::Lz4,
        shuffle: false,
        level: None,
    };
    write_frame_with(&path, &image, &FitsHeader::new(), &options(Some(lz4), None)).unwrap();
    let unit = read_xisf_unit(&path).unwrap();
    assert!(unit.images[0].block.as_ref().unwrap().compression.is_none());
    assert_eq!(unit.read_pixels(0).unwrap().data, image.data);
}

#[test]
fn standard_properties_carry_what_the_cards_say() {
    let mut header = capture_header();
    header.set_float("APTDIA", 203.0);
    let path = scratch("props.xisf");
    write_frame_with(&path, &test_image(8, 8, 1, PixelType::U16), &header, &options(None, None))
        .unwrap();
    let unit = read_xisf_unit(&path).unwrap();
    let image = &unit.images[0];
    let f = |id: &str| image.property(id).and_then(PropertyValue::as_f64).unwrap();
    assert_eq!(f("Instrument:ExposureTime"), 120.0);
    assert!((f("Instrument:Telescope:FocalLength") - 1.016).abs() < 1e-6);
    assert!((f("Instrument:Telescope:Aperture") - 0.203).abs() < 1e-6);
    assert_eq!(f("Instrument:Sensor:Temperature"), -10.5);
    assert_eq!(f("Observation:Object:RA"), 35.639);
    assert_eq!(
        image.property("Observation:Time:Start"),
        Some(&PropertyValue::TimePoint("2026-11-11T07:12:06.250Z".into()))
    );
    assert_eq!(
        image.property("Instrument:Filter:Name").and_then(PropertyValue::as_str),
        Some("Ha")
    );
    assert_eq!(image.image_type.as_deref(), Some("Light"));
    assert_eq!(
        unit.metadata_property("XISF:CreatorApplication")
            .and_then(PropertyValue::as_str)
            .map(|s| s.starts_with("Skotiq ")),
        Some(true)
    );
    assert!(unit.metadata_property("XISF:CreationTime").is_some());
    let thumbnail = unit.read_thumbnail().unwrap().unwrap();
    assert_eq!(thumbnail.pixel_type, PixelType::U8);
}

#[test]
fn a_bayer_frame_carries_its_effective_pattern() {
    let mut header = capture_header();
    header.set_string("BAYERPAT", "RGGB");
    header.set_int("XBAYROFF", 1);
    let path = scratch("cfa.xisf");
    write_frame_with(&path, &test_image(8, 8, 1, PixelType::U16), &header, &options(None, None))
        .unwrap();
    let unit = read_xisf_unit(&path).unwrap();
    let cfa = unit.images[0].color_filter_array.as_ref().unwrap();
    assert_eq!((cfa.pattern.as_str(), cfa.width, cfa.height), ("GRBG", 2, 2));
    let back = read_frame_header(&path).unwrap();
    assert_eq!(read_bayer_geometry(&back), read_bayer_geometry(&header));
}

#[test]
fn a_wcs_becomes_the_first_layer_of_an_astrometric_solution_and_back() {
    let mut header = capture_header();
    header.set_string("CTYPE1", "RA---TAN");
    header.set_string("CTYPE2", "DEC--TAN");
    header.set_float("CRVAL1", 35.6);
    header.set_float("CRVAL2", 42.3);
    header.set_float("CRPIX1", 2048.5);
    header.set_float("CRPIX2", 1536.5);
    header.set_float("CD1_1", -2.1e-4);
    header.set_float("CD1_2", 1.0e-6);
    header.set_float("CD2_1", -1.0e-6);
    header.set_float("CD2_2", -2.1e-4);
    header.set_string("RADESYS", "ICRS");
    let path = scratch("wcs.xisf");
    write_frame_with(&path, &test_image(8, 8, 1, PixelType::U16), &header, &options(None, None))
        .unwrap();
    let unit = read_xisf_unit(&path).unwrap();
    let image = &unit.images[0];
    let v = |id: &str| {
        image
            .property(&format!("AstrometricSolution:{id}"))
            .and_then(PropertyValue::as_f64_values)
            .unwrap()
    };
    assert_eq!(v("ReferenceImageCoordinates"), vec![2048.0, 1536.0]);
    assert_eq!(v("ReferenceCelestialCoordinates"), vec![35.6, 42.3]);
    assert_eq!(v("LinearTransformationMatrix"), vec![-2.1e-4, 1.0e-6, -1.0e-6, -2.1e-4]);
    assert_eq!(
        image
            .property("AstrometricSolution:ProjectionSystem")
            .and_then(PropertyValue::as_str),
        Some("Gnomonic")
    );

    // A file with the solution and no keywords gives the same WCS.
    let mut bare = unit.clone();
    bare.images[0].fits_keywords.clear();
    let cards = header_from_image(&bare.images[0]);
    for key in ["CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD2_2"] {
        assert_eq!(cards.get_float(key), header.get_float(key), "{key}");
    }
    assert_eq!(cards.get_string("CTYPE2"), Some("DEC--TAN"));
    assert_eq!(cards.get_float("EXPTIME"), Some(120.0));
    assert_eq!(cards.get_float("FOCALLEN"), Some(1016.0));
    assert_eq!(cards.get_string("DATE-OBS"), Some("2026-11-11T07:12:06.250"));
    assert_eq!(cards.get_string("IMAGETYP"), Some("Light"));
}

#[test]
fn several_images_are_read_by_index() {
    let first = test_image(16, 8, 1, PixelType::U16);
    let second = test_image(5, 7, 3, PixelType::F32);
    let path = scratch("multi.xisf");
    let headers = [
        (image_header_from_fits(&capture_header(), &first), &first),
        (image_header_from_fits(&FitsHeader::new(), &second), &second),
    ];
    write_images(&path, &[], &headers, &XisfWriteOptions::default()).unwrap();
    let unit = read_xisf_unit(&path).unwrap();
    assert_eq!(unit.images.len(), 2);
    assert_eq!(unit.read_pixels(0).unwrap().data, first.data);
    assert_eq!(unit.read_pixels(1).unwrap().data, second.data);
    assert!(matches!(
        unit.read_pixels(2),
        Err(XisfError::NoSuchImage { index: 2, count: 2 })
    ));
    // The app's frame is the first image.
    assert_eq!(read_frame(&path).unwrap().0.data, first.data);
}

/// A monolithic file from header text with `{0}`, `{1}`… standing for the
/// positions of `blocks`, which are attached from byte 4096 on.
fn monolithic(name: &str, xml: &str, blocks: &[&[u8]]) -> PathBuf {
    let mut positions = Vec::new();
    let mut at = 4096usize;
    for block in blocks {
        positions.push(at);
        at += block.len().div_ceil(16) * 16;
    }
    let mut text = xml.to_string();
    for (i, p) in positions.iter().enumerate() {
        text = text.replace(&format!("{{{i}}}"), &p.to_string());
    }
    assert!(16 + text.len() <= 4096);
    let mut bytes = Vec::new();
    bytes.extend_from_slice(XISF_SIGNATURE);
    bytes.extend_from_slice(&(text.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&[0; 4]);
    bytes.extend_from_slice(text.as_bytes());
    for (block, p) in blocks.iter().zip(&positions) {
        bytes.resize(*p, 0);
        bytes.extend_from_slice(block);
    }
    let path = scratch(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

fn wrap(body: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><xisf version="1.0" xmlns="http://www.pixinsight.com/xisf"><Metadata><Property id="XISF:CreationTime" type="TimePoint" value="2026-01-01T00:00:00Z"/><Property id="XISF:CreatorApplication" type="String">Test</Property></Metadata>{body}</xisf>"#
    )
}

#[test]
fn the_specification_examples_decode() {
    // Section 10.6.4: a 6×6 RGB UInt8 image, zlib-compressed and embedded,
    // and section 10.3's inline ByteArray, plain and compressed.
    let xml = wrap(
        r#"<Image geometry="6:6:3" sampleFormat="UInt8" colorSpace="RGB" location="embedded">
   <Data compression="zlib:108" encoding="base64">
      eJxjYGBg+A+GEPCfAYkJFQZSUPZ/KBtTBFMXOuc/AwCjKyPd
   </Data>
   <Property id="TestProperty" type="ByteArray" length="34" location="inline:base64">
   VGhpcyBpcyBhIHRlc3QgLSBURVNUIC0gMTIzNDU2Nzg5MA==
</Property>
   <Property id="Test" type="ByteArray" length="34" compression="zlib:34" location="inline:base64">eNoLycgsVgCiRIWS1OISBV2FENfgECBlaGRsYmpmbmFpAACzWQkd</Property>
   <Property id="Hex" type="UI16Vector" length="2" location="inline:hex" byteOrder="big">0102 0304</Property>
   <Property id="Flags" type="UInt32" value="0x8000FFA0"/>
   <Property id="Peak" type="Complex32" value="(0.123,-0.735e-02)"/>
</Image>"#,
    );
    let path = monolithic("spec-examples.xisf", &xml, &[]);
    let unit = read_xisf_unit(&path).unwrap();
    let image = &unit.images[0];
    let pixels = unit.read_pixels(0).unwrap();
    assert_eq!((pixels.width, pixels.height, pixels.channels), (6, 6, 3));
    assert_eq!(pixels.data.len(), 108);
    let text = b"This is a test - TEST - 1234567890".to_vec();
    for id in ["TestProperty", "Test"] {
        assert_eq!(
            image.property(id),
            Some(&PropertyValue::Vector {
                element: Element::U8,
                data: text.clone()
            }),
            "{id}"
        );
    }
    assert_eq!(
        image.property("Hex").and_then(PropertyValue::as_f64_values),
        Some(vec![258.0, 772.0])
    );
    assert_eq!(image.property("Flags"), Some(&PropertyValue::UInt32(0x8000_FFA0)));
}

#[test]
fn byte_order_storage_models_and_attachments() {
    // A 3×2 RGB UInt16 image stored pixel by pixel, big-endian.
    let samples: Vec<u16> = (0..18).map(|i| 1000 + i * 3).collect();
    let big: Vec<u8> = samples.iter().flat_map(|v| v.to_be_bytes()).collect();
    let xml = wrap(
        r#"<Image geometry="3:2:3" sampleFormat="UInt16" colorSpace="RGB" pixelStorage="Normal" byteOrder="big" location="attachment:{0}:36"/>"#,
    );
    let path = monolithic("normal-big.xisf", &xml, &[&big]);
    let pixels = read_frame(&path).unwrap().0;
    assert_eq!(pixels.as_u16().unwrap(), samples);

    // The same samples planar and compressed with byte shuffling: the
    // compressed path de-planarizes in its own pass.
    let source = &samples;
    let planar: Vec<u8> = (0..3)
        .flat_map(|c| (0..6).map(move |p| source[p * 3 + c]))
        .flat_map(u16::to_le_bytes)
        .collect();
    let packed = codec::compress(XisfCodec::Lz4Hc, 50, &shuffle(&planar, 2)).unwrap();
    let xml = wrap(&format!(
        r#"<Image geometry="3:2:3" sampleFormat="UInt16" colorSpace="RGB" compression="lz4hc+sh:36:2" location="attachment:{{0}}:{}"/>"#,
        packed.len()
    ));
    let path = monolithic("planar-lz4hc.xisf", &xml, &[&packed]);
    assert_eq!(read_frame(&path).unwrap().0.as_u16().unwrap(), samples);
}

#[test]
fn a_damaged_block_is_refused_by_its_checksum() {
    let image = test_image(32, 32, 1, PixelType::U16);
    for compression in [
        None,
        Some(XisfCompression {
            codec: XisfCodec::Zstd,
            shuffle: true,
            level: None,
        }),
    ] {
        let path = scratch("damaged.xisf");
        write_frame_with(
            &path,
            &image,
            &FitsHeader::new(),
            &options(compression, Some(ChecksumAlgorithm::Sha256)),
        )
        .unwrap();
        let unit = read_xisf_unit(&path).unwrap();
        let BlockLocation::Attachment { position, .. } =
            unit.images[0].block.as_ref().unwrap().location
        else {
            panic!("attached");
        };
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[position as usize + 5] ^= 0x40;
        std::fs::write(&path, &bytes).unwrap();
        match read_frame(&path) {
            Err(crate::FrameIoError::Xisf(XisfError::ChecksumMismatch { .. })) => {}
            other => panic!("{compression:?}: {:?}", other.map(|_| ())),
        }
    }
}

#[test]
fn distributed_units_read_from_data_block_files_and_plain_files() {
    let samples: Vec<u16> = (0..12).map(|i| i * 100).collect();
    let data: Vec<u8> = samples.iter().flat_map(|v| v.to_le_bytes()).collect();
    let dir = scratch("distributed");
    std::fs::create_dir_all(&dir).unwrap();

    // A data blocks file: signature, reserved, one index node with one
    // element, then the block at 128.
    let mut xisb = Vec::new();
    xisb.extend_from_slice(XISB_SIGNATURE);
    xisb.extend_from_slice(&[0; 8]);
    xisb.extend_from_slice(&1u32.to_le_bytes());
    xisb.extend_from_slice(&[0; 4]);
    xisb.extend_from_slice(&0u64.to_le_bytes());
    for field in [0x7a73_526b_584c_6167u64, 128, data.len() as u64, 0, 0] {
        xisb.extend_from_slice(&field.to_le_bytes());
    }
    xisb.resize(128, 0);
    xisb.extend_from_slice(&data);
    std::fs::write(dir.join("blocks.xisb"), &xisb).unwrap();
    std::fs::write(dir.join("plain.dat"), &data).unwrap();

    for location in [
        "path(@header_dir/blocks.xisb):0x7a73526b584c6167",
        "path(@header_dir/plain.dat)",
    ] {
        let header = dir.join("unit.xish");
        std::fs::write(
            &header,
            wrap(&format!(
                r#"<Image geometry="4:3:1" sampleFormat="UInt16" location="{location}"/>"#
            )),
        )
        .unwrap();
        assert_eq!(read_frame(&header).unwrap().0.as_u16().unwrap(), samples, "{location}");
    }

    std::fs::write(
        dir.join("remote.xish"),
        wrap(r#"<Image geometry="4:3:1" sampleFormat="UInt16" location="url(http://example.com/x.bin)"/>"#),
    )
    .unwrap();
    let error = read_frame(&dir.join("remote.xish")).unwrap_err().to_string();
    assert!(error.contains("remote server"), "{error}");
}

#[test]
fn wide_and_complex_formats_are_converted_or_refused_plainly() {
    let values = [0u64, u64::MAX / 2, u64::MAX];
    let data: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    let path = monolithic(
        "u64.xisf",
        &wrap(r#"<Image geometry="3:1:1" sampleFormat="UInt64" location="attachment:{0}:24"/>"#),
        &[&data],
    );
    let pixels = read_frame(&path).unwrap().0;
    assert_eq!(pixels.pixel_type, PixelType::F64);
    let read: Vec<f64> = pixels.samples_f64();
    assert_eq!(read[0], 0.0);
    assert!((read[1] - 0.5).abs() < 1e-9 && read[2] == 1.0);

    let path = monolithic(
        "complex.xisf",
        &wrap(r#"<Image geometry="2:1:1" sampleFormat="Complex32" location="attachment:{0}:16"/>"#),
        &[&[0u8; 16]],
    );
    let error = read_frame(&path).unwrap_err().to_string();
    assert!(error.contains("complex numbers"), "{error}");
    // The header of an image the app cannot decode is still readable.
    assert!(read_xisf_unit(&path).is_ok());
}

#[test]
fn cielab_pixels_are_converted_to_rgb() {
    let space = RgbWorkingSpace::srgb();
    let rgb = [[0.2f64, 0.5, 0.8], [0.9, 0.1, 0.3]];
    let lab: Vec<[f64; 3]> = rgb.iter().map(|p| space.rgb_to_lab(*p)).collect();
    let data: Vec<u8> = (0..3)
        .flat_map(|c| lab.iter().map(move |p| p[c] as f32))
        .flat_map(f32::to_le_bytes)
        .collect();
    let path = monolithic(
        "lab.xisf",
        &wrap(r#"<Image geometry="2:1:3" sampleFormat="Float32" bounds="0:1" colorSpace="CIELab" location="attachment:{0}:24"/>"#),
        &[&data],
    );
    let pixels = read_frame(&path).unwrap().0;
    let out = pixels.samples_f64();
    for (p, expected) in rgb.iter().enumerate() {
        for c in 0..3 {
            assert!((out[p * 3 + c] - expected[c]).abs() < 1e-3, "{out:?}");
        }
    }
}

#[test]
fn a_metadata_rewrite_keeps_pixels_and_everything_unknown() {
    let image = test_image(64, 48, 3, PixelType::U16);
    let path = scratch("rewrite.xisf");
    write_frame_with(
        &path,
        &image,
        &capture_header(),
        &options(
            Some(XisfCompression {
                codec: XisfCodec::Zlib,
                shuffle: true,
                level: None,
            }),
            Some(ChecksumAlgorithm::Sha1),
        ),
    )
    .unwrap();

    // Add what another program might have written: an unknown property, an
    // ICC profile, an extension element pointing at an attached block, and an
    // unknown attribute.
    let mut unit = read_xisf_unit(&path).unwrap();
    unit.images[0]
        .properties
        .push(XisfProperty::new("Vendor:Thing", PropertyValue::f64_matrix(1, 2, &[1.5, 2.5])));
    unit.images[0].icc_profile = Some(vec![0, 0, 1, 2, b'a', b'c', b's', b'p']);
    unit.images[0]
        .extra_attributes
        .push(("vendorAttr".into(), "kept".into()));
    let first = attachment_positions(&unit).min().unwrap();
    unit.preserved.push(format!(
        r#"<Vendor:Table xmlns:Vendor="urn:x"><Cell location="attachment:{first}:4"/></Vendor:Table>"#
    ));
    rewrite_unit_metadata(&path, &unit).unwrap();

    // Grow the header well past its alignment so every block moves.
    let long = "x".repeat(10_000);
    rewrite_frame_header(&path, |h| {
        h.set_string("OBJECT", "NGC 891 (rewritten)");
        h.add_history(&long);
    })
    .unwrap();

    let unit = read_xisf_unit(&path).unwrap();
    let back = &unit.images[0];
    assert_eq!(unit.read_pixels(0).unwrap().data, image.data);
    assert!(unit.read_thumbnail().unwrap().is_some());
    assert_eq!(
        back.property("Vendor:Thing").and_then(PropertyValue::as_f64_values),
        Some(vec![1.5, 2.5])
    );
    assert_eq!(back.icc_profile.as_deref(), Some(&[0, 0, 1, 2, b'a', b'c', b's', b'p'][..]));
    assert!(back.extra_attributes.contains(&("vendorAttr".into(), "kept".into())));
    assert_eq!(
        back.property("Observation:Object:Name").and_then(PropertyValue::as_str),
        Some("NGC 891 (rewritten)")
    );
    let header = header_from_image(back);
    assert_eq!(header.get_string("OBJECT"), Some("NGC 891 (rewritten)"));
    assert_eq!(header.history.last(), Some(&long));
    assert!(unit.metadata_property("XISF:OriginalCreationTime").is_some());

    // The extension element's block moved with the others and still holds
    // the first four bytes of the image's block.
    let raw = &unit.preserved[0];
    let (_, moved) = attachment_spans(raw)[0].clone();
    let pixel_block = match back.block.as_ref().unwrap().location {
        BlockLocation::Attachment { position, .. } => position,
        _ => unreachable!(),
    };
    assert_eq!(moved, pixel_block);
    assert_ne!(moved, first);
}

#[test]
fn malformed_files_give_errors_never_panics() {
    let image = test_image(40, 30, 3, PixelType::U16);
    let path = scratch("fuzz-source.xisf");
    write_frame_with(
        &path,
        &image,
        &capture_header(),
        &options(
            Some(XisfCompression {
                codec: XisfCodec::Zstd,
                shuffle: true,
                level: None,
            }),
            Some(ChecksumAlgorithm::Sha1),
        ),
    )
    .unwrap();
    let good = std::fs::read(&path).unwrap();
    let target = scratch("fuzz.xisf");

    // Every truncation: one that cuts the image's block is refused; one that
    // cuts only the thumbnail after it may open, with the right pixels.
    let unit = read_xisf_unit(&path).unwrap();
    let Some(BlockLocation::Attachment { position, size }) =
        unit.images[0].block.as_ref().map(|b| b.location.clone())
    else {
        panic!("attached");
    };
    for len in (0..good.len()).step_by(97) {
        std::fs::write(&target, &good[..len]).unwrap();
        if let Ok((back, _)) = read_frame(&target) {
            assert!(len as u64 >= position + size, "truncated to {len}");
            assert_eq!(back.data, image.data, "truncated to {len}");
        }
    }

    // Random corruption of the header and the data.
    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    let mut next = || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    for _ in 0..400 {
        let mut bytes = good.clone();
        for _ in 0..1 + next() % 4 {
            let at = (next() as usize) % bytes.len();
            bytes[at] = next() as u8;
        }
        std::fs::write(&target, &bytes).unwrap();
        let _ = read_frame(&target);
        let _ = read_frame_header(&target);
    }

    // Hostile numbers that must not allocate or loop.
    let hostile = [
        r#"<Image geometry="4294967295:4294967295:255" sampleFormat="Float64" location="attachment:{0}:8"/>"#,
        r#"<Image geometry="1000000:1000000:3" sampleFormat="UInt16" compression="zstd:6000000000000" location="attachment:{0}:8"/>"#,
        r#"<Image geometry="2:2:1" sampleFormat="UInt16" compression="zlib:8" subblocks="4,4:4,99999999999" location="attachment:{0}:8"/>"#,
        r#"<Image geometry="2:2:1" sampleFormat="UInt16" location="attachment:{0}:999999999"/>"#,
        r#"<Image geometry="2:2:1" sampleFormat="UInt16" location="attachment:18446744073709551615:8"/>"#,
        r#"<Image geometry="2:2:1" sampleFormat="UInt16" location="attachment:{0}:8"><Property id="V" type="F64Vector" length="99999999999999" location="inline:base64">AAAA</Property></Image>"#,
        r#"<Image geometry="0:2:1" sampleFormat="UInt16" location="attachment:{0}:8"/>"#,
        r#"<Image geometry="2:2:1" sampleFormat="UInt16" compression="brotli:8" location="attachment:{0}:8"/>"#,
        r#"<Image geometry="2:2:1" sampleFormat="UInt16" checksum="md5:00" location="attachment:{0}:8"/>"#,
    ];
    for (i, body) in hostile.iter().enumerate() {
        let path = monolithic(&format!("hostile-{i}.xisf"), &wrap(body), &[&[1u8; 8]]);
        assert!(read_frame(&path).is_err(), "{body}");
    }

    // A header length field larger than the file.
    let mut bytes = good.clone();
    bytes[8..12].copy_from_slice(&u32::MAX.to_le_bytes());
    std::fs::write(&target, &bytes).unwrap();
    assert!(read_frame(&target).is_err());
}
