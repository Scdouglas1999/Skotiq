//! Relative air mass at an altitude, written as a frame's `AIRMASS` card.

use crate::FitsError;

/// Calculate airmass from true (geometric) altitude.
///
/// Airmass is the relative optical path length through Earth's atmosphere
/// compared to the zenith. The implementation uses **Pickering (2002)** above
/// 10° true altitude where it is well-conditioned (worst-case error vs.
/// rigorous radiative transfer is < 0.0008 airmass) and **Young (1994)** below
/// 10° down to the true horizon where Pickering's `1/sin(h + 244/(165+47*h^1.1))`
/// term degrades sharply.
///
/// `altitude_degrees` is a true altitude. The result is ≥ 1.0 at the zenith and
/// increases toward the horizon (Young at h=0° gives ≈31.74). An altitude below
/// 0° returns `FitsError::BelowHorizon`: airmass is physically undefined for a
/// sub-horizon path, and clamping hides the scheduler or coordinate-transform
/// bug that pointed the mount there. The caller decides what to do (skip,
/// retry, alert).
///
/// Validity: Pickering 2002 over 10° ≤ h ≤ 90°, Young 1994 over 0° ≤ h < 10°.
///
/// # References
/// * Pickering, K. A. 2002. "The Southern Limits of the Ancient Star Catalog."
///   *DIO* 12 #1, p. 20.
/// * Young, A. T. 1994. "Air mass and refraction." *Applied Optics* 33, 1108–1110.
pub fn calculate_airmass(altitude_degrees: f64) -> Result<f64, FitsError> {
    if !altitude_degrees.is_finite() {
        return Err(FitsError::InvalidFormat(format!(
            "Altitude must be finite, got {}",
            altitude_degrees
        )));
    }
    if altitude_degrees < 0.0 {
        return Err(FitsError::BelowHorizon { altitude_degrees });
    }
    // Clamp upper bound only — the math is well-defined at 90° but we guard
    // against numerical noise like 90.000001 that would push trig sin(90+) past 1.
    let alt = altitude_degrees.min(90.0);

    if alt >= 89.9 {
        // Why: at zenith the formulas converge to 1.0; this avoids floating-point
        // jitter producing values like 0.99999999.
        return Ok(1.0);
    }

    let airmass = if alt >= 10.0 {
        // Pickering 2002 — accurate to < 0.001 at h ≥ 10°.
        let h_pow = alt.powf(1.1);
        let correction = 244.0 / (165.0 + 47.0 * h_pow);
        let effective_alt = alt + correction;
        1.0 / effective_alt.to_radians().sin()
    } else {
        // Young 1994 — empirical formula valid all the way to h = 0°. Form:
        //   X(z) = (1.002432 cos²z + 0.148386 cos z + 0.0096467) /
        //          (cos³z + 0.149864 cos²z + 0.0102963 cos z + 0.000303978)
        // where z = 90° - h is the true zenith angle. At h = 0°, X ≈ 38.0.
        let z = (90.0 - alt).to_radians();
        let cos_z = z.cos();
        let cos2 = cos_z * cos_z;
        let cos3 = cos2 * cos_z;
        let numerator = 1.002432 * cos2 + 0.148386 * cos_z + 0.0096467;
        let denominator = cos3 + 0.149864 * cos2 + 0.0102963 * cos_z + 0.000303978;
        numerator / denominator
    };

    if !airmass.is_finite() {
        return Err(FitsError::InvalidFormat(format!(
            "Airmass computation produced non-finite result for altitude {}°",
            altitude_degrees
        )));
    }
    Ok(airmass)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_airmass_zenith() {
        let airmass = calculate_airmass(90.0).expect("zenith airmass must succeed");
        assert_eq!(airmass, 1.0, "Airmass at zenith should be 1.0");
    }

    #[test]
    fn test_calculate_airmass_45_degrees() {
        let airmass = calculate_airmass(45.0).expect("45 deg airmass must succeed");
        assert!(
            airmass > 1.0 && airmass < 2.0,
            "Airmass at 45° should be between 1.0 and 2.0"
        );
        // At 45 degrees, airmass should be approximately 1.41 (sqrt(2))
        assert!(
            (airmass - 1.41).abs() < 0.1,
            "Airmass at 45° should be close to 1.41"
        );
    }

    #[test]
    fn test_calculate_airmass_horizon_uses_young_1994() {
        // Why: Young 1994 evaluated at z=90° (h=0°) gives airmass ≈ 31.74.
        let airmass = calculate_airmass(0.0).expect("h=0° must succeed via Young 1994");
        assert!(
            (airmass - 31.74).abs() < 0.5,
            "Young 1994 airmass at horizon should be near 31.74, got {}",
            airmass
        );
    }

    #[test]
    fn test_calculate_airmass_5_degrees_uses_young() {
        // At 5° true altitude Young 1994 yields ~10.32. Pickering would yield
        // ~10.4 — both are reasonable, but the test verifies a real number
        // (no clamp to 40) and that the function does not error in the low band.
        let airmass = calculate_airmass(5.0).expect("h=5° must succeed");
        assert!(
            (8.0..=12.0).contains(&airmass),
            "Young 1994 airmass at 5° should be 8-12, got {}",
            airmass
        );
    }

    #[test]
    fn test_calculate_airmass_15_degrees_uses_pickering() {
        // 15° is in the Pickering range; expect ~3.81.
        let airmass = calculate_airmass(15.0).expect("h=15° must succeed");
        assert!(
            (3.5..=4.1).contains(&airmass),
            "Pickering airmass at 15° should be ~3.8, got {}",
            airmass
        );
    }

    #[test]
    fn test_calculate_airmass_below_horizon_errors() {
        // sub-horizon altitudes must surface an error rather than
        // silently clamping. The caller decides how to handle.
        let err = calculate_airmass(-1.0).expect_err("below-horizon must error");
        assert!(
            matches!(err, FitsError::BelowHorizon { altitude_degrees } if altitude_degrees < 0.0),
            "Expected BelowHorizon error, got {:?}",
            err
        );
    }

    #[test]
    fn test_calculate_airmass_30_degrees() {
        let airmass = calculate_airmass(30.0).expect("h=30° must succeed");
        assert!(
            airmass > 1.5 && airmass < 3.0,
            "Airmass at 30° should be between 1.5 and 3.0"
        );
    }
}
