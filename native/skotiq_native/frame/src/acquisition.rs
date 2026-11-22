//! Whether two frames were taken the same way: the settings a header states
//! and the rule a builder holds them to before combining frames into one
//! master or pairing a flat with its bias.

/// One setting a frame header states about how the frame was taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Setting {
    Instrument,
    Filter,
    Exposure,
    SetPoint,
    ReadMode,
    Gain,
    Offset,
    BinX,
    BinY,
}

impl Setting {
    /// The FITS card that states it.
    pub fn card(self) -> &'static str {
        match self {
            Self::Instrument => "INSTRUME",
            Self::Filter => "FILTER",
            Self::Exposure => "EXPTIME",
            Self::SetPoint => "SET-TEMP",
            Self::ReadMode => "READOUTM",
            Self::Gain => "GAIN",
            Self::Offset => "OFFSET",
            Self::BinX => "XBINNING",
            Self::BinY => "YBINNING",
        }
    }
}

/// How a frame was taken, as its header states it; `None` where it is silent.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Acquisition {
    pub instrument: Option<String>,
    pub filter: Option<String>,
    pub exposure_s: Option<f64>,
    pub set_point_c: Option<f64>,
    pub read_mode: Option<String>,
    pub gain: Option<f64>,
    pub offset: Option<f64>,
    pub bin_x: Option<f64>,
    pub bin_y: Option<f64>,
}

/// How gain, offset and binning are compared.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum NumberMatch {
    /// Equal after dropping the fraction.
    Whole,
    /// Equal within the given amount.
    Within(f64),
}

/// How far two exposures may differ: the larger of `absolute_s` and
/// `relative` of the first frame's exposure.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExposureTolerance {
    pub absolute_s: f64,
    pub relative: f64,
}

/// Which settings must agree, and how closely. A setting is compared only
/// when both frames state it. Gain, offset and binning are always compared.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AgreementPolicy {
    pub instrument: bool,
    pub filter: bool,
    pub exposure: Option<ExposureTolerance>,
    /// Largest set-point difference, in °C.
    pub set_point_c: Option<f64>,
    pub read_mode: bool,
    pub numbers: NumberMatch,
}

/// The first setting two frames disagree on, with each frame's value as text.
#[derive(Debug, Clone, PartialEq)]
pub struct Disagreement {
    pub setting: Setting,
    pub first: String,
    pub other: String,
}

impl Acquisition {
    /// The first setting `other` disagrees with `self` on under `policy`, in
    /// the order instrument, filter, exposure, set-point, read mode, gain,
    /// offset, binning.
    pub fn disagreement(&self, other: &Self, policy: &AgreementPolicy) -> Option<Disagreement> {
        let text = |setting, wanted: bool, a: &Option<String>, b: &Option<String>| match (a, b) {
            (Some(a), Some(b)) if wanted && a != b => Some(Disagreement {
                setting,
                first: a.clone(),
                other: b.clone(),
            }),
            _ => None,
        };
        let close =
            |setting, limit: Option<f64>, a: Option<f64>, b: Option<f64>| match (a, b, limit) {
                (Some(a), Some(b), Some(limit)) if (a - b).abs() > limit => Some(Disagreement {
                    setting,
                    first: a.to_string(),
                    other: b.to_string(),
                }),
                _ => None,
            };
        let number = |setting, a: Option<f64>, b: Option<f64>| {
            let (a, b) = (a?, b?);
            let differs = match policy.numbers {
                NumberMatch::Whole => a as i64 != b as i64,
                NumberMatch::Within(limit) => (a - b).abs() > limit,
            };
            let shown = |v: f64| match policy.numbers {
                NumberMatch::Whole => (v as i64).to_string(),
                NumberMatch::Within(_) => v.to_string(),
            };
            differs.then(|| Disagreement {
                setting,
                first: shown(a),
                other: shown(b),
            })
        };
        let exposure_limit = policy
            .exposure
            .zip(self.exposure_s)
            .map(|(tolerance, first)| tolerance.absolute_s.max(first.abs() * tolerance.relative));
        text(
            Setting::Instrument,
            policy.instrument,
            &self.instrument,
            &other.instrument,
        )
        .or_else(|| text(Setting::Filter, policy.filter, &self.filter, &other.filter))
        .or_else(|| {
            close(
                Setting::Exposure,
                exposure_limit,
                self.exposure_s,
                other.exposure_s,
            )
        })
        .or_else(|| {
            close(
                Setting::SetPoint,
                policy.set_point_c,
                self.set_point_c,
                other.set_point_c,
            )
        })
        .or_else(|| {
            text(
                Setting::ReadMode,
                policy.read_mode,
                &self.read_mode,
                &other.read_mode,
            )
        })
        .or_else(|| number(Setting::Gain, self.gain, other.gain))
        .or_else(|| number(Setting::Offset, self.offset, other.offset))
        .or_else(|| number(Setting::BinX, self.bin_x, other.bin_x))
        .or_else(|| number(Setting::BinY, self.bin_y, other.bin_y))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn taken(gain: f64, mode: &str, set_point: f64) -> Acquisition {
        Acquisition {
            instrument: Some("ZWO ASI2600MM Pro".into()),
            filter: Some("L".into()),
            exposure_s: Some(120.0),
            set_point_c: Some(set_point),
            read_mode: Some(mode.into()),
            gain: Some(gain),
            offset: Some(50.0),
            bin_x: Some(1.0),
            bin_y: Some(1.0),
        }
    }

    const STRICT: AgreementPolicy = AgreementPolicy {
        instrument: true,
        filter: true,
        exposure: Some(ExposureTolerance {
            absolute_s: 1e-3,
            relative: 1e-4,
        }),
        set_point_c: Some(0.05),
        read_mode: true,
        numbers: NumberMatch::Whole,
    };

    #[test]
    fn the_first_differing_setting_is_named_with_both_values() {
        let first = taken(100.0, "0", -10.0);
        assert_eq!(first.disagreement(&first, &STRICT), None);
        assert_eq!(
            first.disagreement(&taken(200.0, "1", -10.0), &STRICT),
            Some(Disagreement {
                setting: Setting::ReadMode,
                first: "0".into(),
                other: "1".into(),
            })
        );
        assert_eq!(
            first
                .disagreement(&taken(200.4, "0", -10.0), &STRICT)
                .map(|d| (d.setting, d.other)),
            Some((Setting::Gain, "200".to_string()))
        );
    }

    #[test]
    fn a_setting_is_compared_only_when_asked_and_stated_by_both() {
        let first = taken(100.0, "0", -10.0);
        let loose = AgreementPolicy {
            set_point_c: None,
            read_mode: false,
            numbers: NumberMatch::Within(1e-6),
            ..STRICT
        };
        assert_eq!(first.disagreement(&taken(100.0, "1", 0.0), &loose), None);
        let silent = Acquisition {
            gain: None,
            read_mode: None,
            ..taken(0.0, "", -10.0)
        };
        assert_eq!(first.disagreement(&silent, &STRICT), None);
        assert_eq!(
            first
                .disagreement(&taken(100.0000001, "0", -10.0), &loose)
                .map(|d| d.setting),
            None
        );
        assert_eq!(
            first
                .disagreement(&taken(100.4, "0", -10.0), &loose)
                .map(|d| d.setting),
            Some(Setting::Gain)
        );
    }

    #[test]
    fn exposure_tolerance_scales_with_the_first_frame() {
        let mut first = taken(100.0, "0", -10.0);
        let mut other = first.clone();
        other.exposure_s = Some(120.011);
        assert_eq!(first.disagreement(&other, &STRICT), None);
        other.exposure_s = Some(120.013);
        assert_eq!(
            first.disagreement(&other, &STRICT).map(|d| d.setting),
            Some(Setting::Exposure)
        );
        first.exposure_s = Some(0.001);
        other.exposure_s = Some(0.0019);
        assert_eq!(first.disagreement(&other, &STRICT), None);
    }
}
