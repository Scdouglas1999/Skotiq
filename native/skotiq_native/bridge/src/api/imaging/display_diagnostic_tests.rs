use super::display_data_summary;

/// The fused fold must agree with the three separate passes it replaced.
#[test]
fn fused_summary_matches_three_separate_passes() {
    let data: Vec<u8> = (0..=255u8).chain(17..90u8).collect();

    let expected_min = *data.iter().min().unwrap();
    let expected_max = *data.iter().max().unwrap();
    let expected_mean = data.iter().map(|&v| v as u64).sum::<u64>() / data.len() as u64;

    assert_eq!(
        display_data_summary(&data),
        Some((expected_min, expected_max, expected_mean))
    );
}

/// A zero-pixel buffer reports nothing instead of dividing by its length.
#[test]
fn empty_buffer_reports_nothing_rather_than_dividing_by_zero() {
    assert_eq!(display_data_summary(&[]), None);
}

#[test]
fn single_pixel_is_its_own_min_max_and_mean() {
    assert_eq!(display_data_summary(&[42]), Some((42, 42, 42)));
}
