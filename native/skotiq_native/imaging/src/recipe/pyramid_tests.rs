//! Downsample arithmetic and the astrometry transforms that go with it.

use std::sync::Arc;

use super::*;
use crate::fits::FitsHeader;
use crate::recipe::testkit::{synthetic_star_field, wcs_header};

fn flat_image(width: u32, height: u32, channels: u32, values: Vec<f32>) -> OpImage {
    OpImage::new(
        width,
        height,
        channels,
        values,
        wcs_header(width, height, channels),
    )
    .expect("geometry and buffer agree")
}

#[test]
fn a_two_by_two_block_becomes_its_mean() {
    let image = flat_image(2, 2, 1, vec![1.0, 3.0, 5.0, 11.0]);
    let half = downsample_2x(&image).expect("the image halves");
    assert_eq!(half.width(), 1);
    assert_eq!(half.height(), 1);
    assert_eq!(half.data(), &[5.0]);
}

#[test]
fn channels_are_averaged_independently() {
    let image = flat_image(
        2,
        2,
        3,
        vec![
            1.0, 10.0, 100.0, 3.0, 30.0, 300.0, 5.0, 50.0, 500.0, 7.0, 70.0, 700.0,
        ],
    );
    let half = downsample_2x(&image).expect("the image halves");
    assert_eq!(half.channels(), 3);
    assert_eq!(half.data(), &[4.0, 40.0, 400.0]);
}

#[test]
fn an_odd_dimension_keeps_its_last_row_and_column() {
    let image = flat_image(
        3,
        3,
        1,
        vec![1.0, 3.0, 9.0, 5.0, 7.0, 11.0, 13.0, 15.0, 17.0],
    );
    let half = downsample_2x(&image).expect("the image halves");
    assert_eq!((half.width(), half.height()), (2, 2));
    assert_eq!(half.data(), &[4.0, 10.0, 14.0, 17.0]);
}

#[test]
fn a_single_pixel_image_cannot_be_halved() {
    let image = flat_image(1, 1, 1, vec![42.0]);
    assert!(matches!(
        downsample_2x(&image),
        Err(OpError::GeometryMismatch { .. })
    ));
}

#[test]
fn the_axis_keywords_follow_the_new_geometry() {
    let image = synthetic_star_field(64, 32, 1, 3);
    let half = downsample_2x(&image).expect("the image halves");
    assert_eq!(half.header().get_int("NAXIS1"), Some(32));
    assert_eq!(half.header().get_int("NAXIS2"), Some(16));
}

#[test]
fn the_cd_matrix_doubles_and_the_reference_pixel_halves() {
    let image = synthetic_star_field(64, 32, 1, 3);
    let half = downsample_2x(&image).expect("the image halves");
    assert_eq!(half.header().get_float("CD1_1"), Some(-0.001));
    assert_eq!(half.header().get_float("CD2_2"), Some(0.001));
    // The base CRPIX1 is (64 + 1) / 2 = 32.5, which maps to (32.5 + 0.5) / 2.
    assert_eq!(half.header().get_float("CRPIX1"), Some(16.5));
    assert_eq!(half.header().get_float("CRPIX2"), Some(8.5));
}

#[test]
fn the_reference_pixel_still_points_at_the_same_sky() {
    // The reference pixel is the frame centre in both grids: a 64-wide frame
    // centres on 1-based pixel 32.5, and its half-scale grid on 16.5.
    let image = synthetic_star_field(64, 32, 1, 3);
    let half = downsample_2x(&image).expect("the image halves");
    let full_wcs = image.wcs().expect("the base carries a WCS");
    let half_wcs = half.wcs().expect("the level carries a WCS");
    assert_eq!(full_wcs.crval1, half_wcs.crval1);
    assert_eq!(full_wcs.crval2, half_wcs.crval2);
    assert_eq!((full_wcs.crpix1 + 0.5) / 2.0, half_wcs.crpix1);
}

#[test]
fn sip_terms_scale_by_two_to_the_order_less_one() {
    let mut header = wcs_header(64, 64, 1);
    header.set_int("A_ORDER", 2);
    header.set_float("A_0_0", 4.0);
    header.set_float("A_1_0", 4.0);
    header.set_float("A_1_1", 4.0);
    header.set_float("A_2_0", 4.0);
    let image =
        OpImage::new(64, 64, 1, vec![0.0; 64 * 64], header).expect("geometry and buffer agree");
    let half = downsample_2x(&image).expect("the image halves");
    let h = half.header();
    assert_eq!(h.get_float("A_0_0"), Some(2.0));
    assert_eq!(h.get_float("A_1_0"), Some(4.0));
    assert_eq!(h.get_float("A_1_1"), Some(8.0));
    assert_eq!(h.get_float("A_2_0"), Some(8.0));
}

#[test]
fn a_header_without_a_wcs_is_left_alone() {
    let image =
        OpImage::new(4, 4, 1, vec![1.0; 16], FitsHeader::new()).expect("geometry and buffer agree");
    let half = downsample_2x(&image).expect("the image halves");
    assert!(half.header().get_float("CRPIX1").is_none());
    assert!(half.header().get_int("NAXIS1").is_none());
}

#[test]
fn a_pyramid_halves_until_the_floor() {
    let base = Arc::new(synthetic_star_field(64, 64, 1, 5));
    let pyramid = ImagePyramid::build_with_min_dimension(base, 8).expect("the pyramid builds");
    assert_eq!(pyramid.level_count(), 4);
    let sizes: Vec<(u32, u32)> = (0..pyramid.level_count())
        .map(|level| {
            let image = pyramid.level(level).expect("the level exists");
            (image.width(), image.height())
        })
        .collect();
    assert_eq!(sizes, vec![(64, 64), (32, 32), (16, 16), (8, 8)]);
}

#[test]
fn a_base_below_the_floor_yields_a_single_level() {
    let base = Arc::new(synthetic_star_field(16, 16, 1, 5));
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 64).expect("the pyramid builds");
    assert_eq!(pyramid.level_count(), 1);
    assert_eq!(pyramid.base().width(), 16);
    assert!(pyramid.level(1).is_none());
}

#[test]
fn the_default_floor_is_the_documented_one() {
    let base = Arc::new(synthetic_star_field(256, 256, 1, 5));
    let pyramid = ImagePyramid::build(base).expect("the pyramid builds");
    let coarsest = pyramid
        .level(pyramid.level_count() - 1)
        .expect("the coarsest level exists");
    assert!(coarsest.width() >= DEFAULT_MIN_PYRAMID_DIMENSION);
    assert!(coarsest.width() / 2 < DEFAULT_MIN_PYRAMID_DIMENSION);
}

#[test]
fn a_viewport_picks_the_coarsest_level_that_still_covers_it() {
    let base = Arc::new(synthetic_star_field(64, 64, 1, 5));
    let pyramid = ImagePyramid::build_with_min_dimension(base, 8).expect("the pyramid builds");
    assert_eq!(pyramid.level_for_max_dimension(64), 0);
    assert_eq!(pyramid.level_for_max_dimension(40), 0);
    assert_eq!(pyramid.level_for_max_dimension(32), 1);
    assert_eq!(pyramid.level_for_max_dimension(9), 2);
    assert_eq!(pyramid.level_for_max_dimension(8), 3);
    assert_eq!(pyramid.level_for_max_dimension(1), 3);
}

#[test]
fn the_pyramid_reports_what_it_costs() {
    let base = Arc::new(synthetic_star_field(64, 64, 1, 5));
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 8).expect("the pyramid builds");
    let expected: usize = (64 * 64 + 32 * 32 + 16 * 16 + 8 * 8) * 4;
    assert_eq!(pyramid.byte_size(), expected);
}

#[test]
fn downsampling_is_reproducible() {
    let image = synthetic_star_field(48, 33, 3, 9);
    let a = downsample_2x(&image).expect("the image halves");
    let b = downsample_2x(&image).expect("the image halves");
    assert_eq!(a.data(), b.data());
}

#[test]
fn a_pyramid_level_matches_a_repeated_halving() {
    let base = Arc::new(synthetic_star_field(48, 32, 1, 11));
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 4).expect("the pyramid builds");
    let manual =
        downsample_2x(&downsample_2x(&base).expect("first halving")).expect("second halving");
    let level = pyramid.level(2).expect("level 2 exists");
    assert_eq!(level.data(), manual.data());
}
