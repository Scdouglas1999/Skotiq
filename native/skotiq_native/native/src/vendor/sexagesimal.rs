//! Sexagesimal arithmetic the serial mount protocols share.
//!
//! The protocols differ in how they print a coordinate (LX200 `HH:MM:SS` and
//! `sDD*MM:SS`, iOptron a signed count of hundredths of an arc second) but not
//! in the arithmetic underneath, which is what lives here.

/// Takes a leading `+` or `-` off `text`. An unsigned value is positive.
pub(crate) fn split_sign(text: &str) -> (f64, &str) {
    if let Some(rest) = text.strip_prefix('-') {
        (-1.0, rest)
    } else if let Some(rest) = text.strip_prefix('+') {
        (1.0, rest)
    } else {
        (1.0, text)
    }
}

/// The sign a protocol prints in front of a signed field.
pub(crate) fn sign_char(value: f64) -> char {
    if value < 0.0 {
        '-'
    } else {
        '+'
    }
}

/// Hours (or degrees), minutes and seconds as one value.
pub(crate) fn from_parts(whole: f64, minutes: f64, seconds: f64) -> f64 {
    whole + minutes / 60.0 + seconds / 3600.0
}

/// `value` rounded to a whole number of the smallest unit a format prints,
/// with `units_per_whole` of them to the hour or degree (3600 for seconds,
/// 360,000 for hundredths of a second).
///
/// Formatters round here and split afterwards with [`split_units`]. Splitting
/// first and rounding the last field carries 59.6 s up to a printed "60",
/// which mounts refuse.
pub(crate) fn to_units(value: f64, units_per_whole: i64) -> i64 {
    (value * units_per_whole as f64).round() as i64
}

/// Splits a count from [`to_units`] into whole hours or degrees, minutes, and
/// the units left within the minute.
pub(crate) fn split_units(total: i64, units_per_whole: i64) -> (i64, i64, i64) {
    let units_per_minute = units_per_whole / 60;
    (
        total / units_per_whole,
        (total % units_per_whole) / units_per_minute,
        total % units_per_minute,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sign_is_split_off_and_an_unsigned_value_is_positive() {
        assert_eq!(split_sign("-33*52"), (-1.0, "33*52"));
        assert_eq!(split_sign("+40*00"), (1.0, "40*00"));
        assert_eq!(split_sign("075*23"), (1.0, "075*23"));
        assert_eq!(split_sign(""), (1.0, ""));
    }

    #[test]
    fn rounding_carries_into_the_next_field_instead_of_printing_sixty() {
        // 0.1 s short of one hour, at whole seconds.
        let total = to_units(1.0 - 0.1 / 3600.0, 3600);
        assert_eq!(split_units(total, 3600), (1, 0, 0));
        // 0.004 s short of one hour, at hundredths of a second.
        let total = to_units(1.0 - 0.004 / 3600.0, 360_000);
        assert_eq!(split_units(total, 360_000), (1, 0, 0));
    }

    #[test]
    fn split_units_keeps_the_remainder_in_the_unit_it_was_given() {
        assert_eq!(split_units(to_units(5.5, 3600), 3600), (5, 30, 0));
        // 33 deg 52 min 11.00 s in hundredths of an arc second.
        assert_eq!(
            split_units(to_units(33.869722, 360_000), 360_000),
            (33, 52, 1100)
        );
    }

    #[test]
    fn parts_join_and_signs_print() {
        assert_eq!(from_parts(5.0, 30.0, 0.0), 5.5);
        assert_eq!(sign_char(-0.5), '-');
        assert_eq!(sign_char(0.0), '+');
    }
}
