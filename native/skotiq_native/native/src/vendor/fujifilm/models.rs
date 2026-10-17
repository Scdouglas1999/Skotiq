//! Shutter-speed mapping, live-view quality and the camera model database.

use super::*;

// Shutter speed mapping

/// Shutter speed code to seconds mapping
pub(crate) struct ShutterSpeedEntry {
    pub(crate) code: c_long,
    pub(crate) seconds: f64,
}

/// Common shutter speeds from XAPI.h
/// The SDK uses integer codes proportional to time
pub(crate) static SHUTTER_SPEEDS: &[ShutterSpeedEntry] = &[
    ShutterSpeedEntry {
        code: 122,
        seconds: 1.0 / 8000.0,
    },
    ShutterSpeedEntry {
        code: 244,
        seconds: 1.0 / 4000.0,
    },
    ShutterSpeedEntry {
        code: 488,
        seconds: 1.0 / 2000.0,
    },
    ShutterSpeedEntry {
        code: 976,
        seconds: 1.0 / 1000.0,
    },
    ShutterSpeedEntry {
        code: 1953,
        seconds: 1.0 / 500.0,
    },
    ShutterSpeedEntry {
        code: 3906,
        seconds: 1.0 / 250.0,
    },
    ShutterSpeedEntry {
        code: 7812,
        seconds: 1.0 / 125.0,
    },
    ShutterSpeedEntry {
        code: 15625,
        seconds: 1.0 / 60.0,
    },
    ShutterSpeedEntry {
        code: 31250,
        seconds: 1.0 / 30.0,
    },
    ShutterSpeedEntry {
        code: 62500,
        seconds: 1.0 / 15.0,
    },
    ShutterSpeedEntry {
        code: 125000,
        seconds: 1.0 / 8.0,
    },
    ShutterSpeedEntry {
        code: 250000,
        seconds: 1.0 / 4.0,
    },
    ShutterSpeedEntry {
        code: 500000,
        seconds: 1.0 / 2.0,
    },
    ShutterSpeedEntry {
        code: 1000000,
        seconds: 1.0,
    },
    ShutterSpeedEntry {
        code: 2000000,
        seconds: 2.0,
    },
    ShutterSpeedEntry {
        code: 4000000,
        seconds: 4.0,
    },
    ShutterSpeedEntry {
        code: 8000000,
        seconds: 8.0,
    },
    ShutterSpeedEntry {
        code: 16000000,
        seconds: 15.0,
    },
    ShutterSpeedEntry {
        code: 32000000,
        seconds: 30.0,
    },
    ShutterSpeedEntry {
        code: 64000000,
        seconds: 60.0,
    },
];

/// Find the closest shutter speed code for a given duration
pub(crate) fn find_shutter_code(seconds: f64) -> c_long {
    if seconds > 60.0 {
        return XSDK_SHUTTER_BULB;
    }

    // Find the closest matching shutter speed
    let mut best_code = XSDK_SHUTTER_BULB;
    let mut best_diff = f64::MAX;

    for entry in SHUTTER_SPEEDS {
        let diff = (entry.seconds - seconds).abs();
        if diff < best_diff {
            best_diff = diff;
            best_code = entry.code;
        }
    }

    best_code
}

// Live view quality

/// Live view quality setting
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum LiveViewQuality {
    /// Fine quality (highest, more bandwidth)
    Fine,
    /// Normal quality (balanced)
    #[default]
    Normal,
    /// Basic quality (lowest, less bandwidth)
    Basic,
}

impl LiveViewQuality {
    /// Convert to SDK constant
    pub(crate) fn to_sdk_code(self) -> c_long {
        match self {
            LiveViewQuality::Fine => SDK_LIVEVIEW_QUALITY_FINE,
            LiveViewQuality::Normal => SDK_LIVEVIEW_QUALITY_NORMAL,
            LiveViewQuality::Basic => SDK_LIVEVIEW_QUALITY_BASIC,
        }
    }
}

// Camera model database

/// Fujifilm camera model information
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FujifilmModel {
    // GFX Medium Format (Bayer sensors)
    Gfx100,
    Gfx100II,
    Gfx100SII,
    Gfx50R,
    Gfx50S,
    Gfx50SII,

    // X-H Series (X-Trans V sensors, high-res)
    XH2,
    XH2S,

    // X-T Series (X-Trans)
    XT3,
    XT4,
    XT5,

    // Other X-series
    XM5,
    XS10,
    XS20,
    XPro3,
    XE4,
    X100V,
    X100VI,

    Unknown,
}

impl FujifilmModel {
    /// Parse model from product name string
    pub(crate) fn from_product_name(name: &str) -> Self {
        let name_upper = name.to_uppercase();

        if name_upper.contains("GFX 100S II") || name_upper.contains("GFX100S II") {
            Self::Gfx100SII
        } else if name_upper.contains("GFX 100 II") || name_upper.contains("GFX100 II") {
            Self::Gfx100II
        } else if name_upper.contains("GFX 100") || name_upper.contains("GFX100") {
            Self::Gfx100
        } else if name_upper.contains("GFX 50S II") || name_upper.contains("GFX50S II") {
            Self::Gfx50SII
        } else if name_upper.contains("GFX 50R") || name_upper.contains("GFX50R") {
            Self::Gfx50R
        } else if name_upper.contains("GFX 50S") || name_upper.contains("GFX50S") {
            Self::Gfx50S
        } else if name_upper.contains("X-H2S") || name_upper.contains("XH2S") {
            Self::XH2S
        } else if name_upper.contains("X-H2") || name_upper.contains("XH2") {
            Self::XH2
        } else if name_upper.contains("X-T5") || name_upper.contains("XT5") {
            Self::XT5
        } else if name_upper.contains("X-T4") || name_upper.contains("XT4") {
            Self::XT4
        } else if name_upper.contains("X-T3") || name_upper.contains("XT3") {
            Self::XT3
        } else if name_upper.contains("X-M5") || name_upper.contains("XM5") {
            Self::XM5
        } else if name_upper.contains("X-S20") || name_upper.contains("XS20") {
            Self::XS20
        } else if name_upper.contains("X-S10") || name_upper.contains("XS10") {
            Self::XS10
        } else if name_upper.contains("X-PRO3") || name_upper.contains("XPRO3") {
            Self::XPro3
        } else if name_upper.contains("X-E4") || name_upper.contains("XE4") {
            Self::XE4
        } else if name_upper.contains("X100VI") {
            Self::X100VI
        } else if name_upper.contains("X100V") {
            Self::X100V
        } else {
            Self::Unknown
        }
    }

    /// Check if this is an X-Trans sensor (non-Bayer)
    pub(crate) fn is_xtrans(&self) -> bool {
        matches!(
            self,
            Self::XH2
                | Self::XH2S
                | Self::XT5
                | Self::XT4
                | Self::XT3
                | Self::XM5
                | Self::XS20
                | Self::XS10
                | Self::XPro3
                | Self::XE4
                | Self::X100V
                | Self::X100VI
        )
    }

    /// Whether this body can be switched to 16-bit RAW output.
    ///
    /// Taken from the per-model capability headers under
    /// `SDKs/Fujifilm/extracted/SDK13410/HEADERS/`, where
    /// `API_PARAM_CapRAWOutputDepth` is `2` (supported) on GFX100.h:244,
    /// GFX100S.h:245, GFX50SII.h:245, GFX100II.h:255, GFX100SII.h:255 and
    /// GFX100RF.h:255, and `-1` (unsupported) on X-T5.h:255, X-H2.h:255,
    /// X-H2S.h:255, X-M5.h:255, X-S20.h:255 and GFXETERNA55.h:255. GFX50R.h and
    /// GFX50S.h declare no `CapRAWOutputDepth` entry at all — 14-bit only.
    ///
    /// `from_product_name` folds "GFX 100S" into `Gfx100`, so that body is
    /// covered by the `Gfx100` arm.
    pub(crate) fn supports_16bit_raw(&self) -> bool {
        matches!(
            self,
            Self::Gfx100 | Self::Gfx100II | Self::Gfx100SII | Self::Gfx50SII
        )
    }

    /// Get sensor specifications (width, height, pixel_size_um, bit_depth)
    ///
    /// The bit depth here is the LOWEST-authority source of a frame's sample
    /// depth — a static pre-first-frame estimate. 14 is the only depth the
    /// bodies outside [`Self::supports_16bit_raw`] can deliver, since the SDK
    /// defines exactly two RAW output depths (XAPIOpt.H:584-585) and their
    /// capability headers reject the 16-bit one. For a GFX-class body it is a
    /// coin toss this table cannot resolve: switched to
    /// `SDK_RAWOUTPUTDEPTH_16BIT` (XAPIOpt.H:585) the body delivers 65535-scale
    /// samples. `FujifilmCamera::refresh_raw_depth` ranks the sources:
    /// measured-from-frame > SDK-reported > this table.
    pub(crate) fn sensor_specs(&self) -> (u32, u32, f64, u32) {
        match self {
            Self::Gfx100 | Self::Gfx100II | Self::Gfx100SII => (11648, 8736, 3.76, 14),
            Self::Gfx50R | Self::Gfx50S | Self::Gfx50SII => (8256, 6192, 5.3, 14),
            Self::XH2 | Self::XT5 => (9728, 7296, 3.0, 14), // 40MP X-Trans
            Self::XH2S => (6240, 4160, 3.76, 14),           // 26MP X-Trans stacked
            _ => (6240, 4160, 3.76, 14),                    // 26MP X-Trans default
        }
    }
}
