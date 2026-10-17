//! The live stack's data product: the accumulated master, written as FITS.
//!
//! The live stacker accumulates pixels, not headers. Its frames arrive either as
//! files (which carry a FITS header) or as raw `u16` buffers from a capture
//! (which carry nothing), so the master save path cannot demand the per-frame
//! `EXPTIME` / `DATE-OBS` a single light frame would have. Rather than fall back
//! to a PNG — 16-bit pixels with no header, no WCS and no integration time — the
//! master carries both keywords synthesized from the stack's own provenance:
//!
//! * `EXPTIME` — the summed integration of the frames that reported an exposure.
//! * `DATE-OBS` — the earliest stacked frame's observation stamp, or the moment
//!   the stack itself started when no frame reported one.
//!
//! What each value is based on is disclosed in its card comment, so a stacking
//! tool reading `EXPTIME = 0.0` can tell "no frame reported an exposure" from
//! "the exposure really was zero". Following the accumulating-master convention
//! in [`crate::master_accumulation`], an unknown per-frame exposure contributes
//! nothing rather than a guess.

use std::collections::HashMap;
use std::path::Path;

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};

use crate::fits::{write_fits, FitsError, FitsHeader};
use crate::ImageData;

/// The FITS `DATE-OBS` form Skotiq writes: UTC, milliseconds, no offset.
const DATE_OBS_FORMAT: &str = "%Y-%m-%dT%H:%M:%S%.3f";

/// What a frame's own header told the stacker, when it had one.
///
/// Both fields are `Option` because the in-memory ingest path (`from_data`)
/// genuinely has neither: a raw `u16` buffer has no keywords. `None` means
/// "unknown", never "zero".
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FrameProvenance {
    /// The frame's `EXPTIME` in seconds.
    pub exposure_secs: Option<f64>,
    /// The frame's `DATE-OBS`, verbatim as the header carried it.
    pub date_obs: Option<String>,
}

impl FrameProvenance {
    /// A frame that told us nothing — the in-memory ingest path.
    pub fn unknown() -> Self {
        Self::default()
    }

    /// Read the two keywords out of the flattened header
    /// [`crate::read_image`] returns. A keyword that is absent, blank or
    /// unparseable stays `None` so it contributes nothing to the master.
    pub fn from_header_map(header: &HashMap<String, String>) -> Self {
        let exposure_secs = header
            .get("EXPTIME")
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v > 0.0);
        let date_obs = header
            .get("DATE-OBS")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty());
        Self {
            exposure_secs,
            date_obs,
        }
    }
}

/// Provenance folded across every frame the stacker actually accepted.
///
/// Rejected frames never reach [`StackProvenance::fold`], so the counts here
/// describe the pixels really in the master rather than everything attempted.
#[derive(Debug, Clone, PartialEq)]
pub struct StackProvenance {
    /// When the stack began accumulating — the fallback `DATE-OBS`, and the one
    /// timestamp that is always known.
    started_at: DateTime<Utc>,
    /// Frames folded into the master.
    stacked_frames: u32,
    /// How many of those reported an exposure.
    frames_with_exposure: u32,
    /// Σ of the reported exposures, in seconds.
    total_integration_secs: f64,
    /// Earliest parseable frame stamp, with the text it was parsed from.
    earliest_date_obs: Option<(DateTime<Utc>, String)>,
    /// First frame stamp we could not parse. Used only when no frame carried a
    /// parseable one — a stamp in an unrecognised form is still closer to the
    /// truth than the stack's start time.
    first_unparsed_date_obs: Option<String>,
}

impl Default for StackProvenance {
    fn default() -> Self {
        Self::started_at(Utc::now())
    }
}

impl StackProvenance {
    /// Begin provenance for a stack that started at `started_at`.
    pub fn started_at(started_at: DateTime<Utc>) -> Self {
        Self {
            started_at,
            stacked_frames: 0,
            frames_with_exposure: 0,
            total_integration_secs: 0.0,
            earliest_date_obs: None,
            first_unparsed_date_obs: None,
        }
    }

    /// Fold one accepted frame's provenance into the running totals.
    pub fn fold(&mut self, frame: &FrameProvenance) {
        self.stacked_frames = self.stacked_frames.saturating_add(1);

        if let Some(exposure) = frame.exposure_secs {
            if exposure.is_finite() && exposure > 0.0 {
                self.frames_with_exposure = self.frames_with_exposure.saturating_add(1);
                self.total_integration_secs += exposure;
            }
        }

        let Some(text) = frame.date_obs.as_deref().map(str::trim) else {
            return;
        };
        if text.is_empty() {
            return;
        }
        match parse_date_obs(text) {
            Some(parsed) => {
                let is_earlier = self
                    .earliest_date_obs
                    .as_ref()
                    .is_none_or(|(current, _)| parsed < *current);
                if is_earlier {
                    self.earliest_date_obs = Some((parsed, text.to_string()));
                }
            }
            None if self.first_unparsed_date_obs.is_none() => {
                self.first_unparsed_date_obs = Some(text.to_string());
            }
            None => {}
        }
    }

    /// Frames folded into the master.
    pub fn stacked_frames(&self) -> u32 {
        self.stacked_frames
    }

    /// Σ of the exposures the stacked frames reported, in seconds. Frames that
    /// reported no exposure contribute nothing.
    pub fn total_integration_secs(&self) -> f64 {
        self.total_integration_secs
    }

    /// The header this stack's master is written with: the synthesized
    /// `EXPTIME` / `DATE-OBS` plus the master identification keywords the
    /// post-session masters use.
    pub fn to_fits_header(&self) -> FitsHeader {
        let mut header = FitsHeader::new();
        header.set_string("IMAGETYP", "MASTER_LIGHT");
        header.set_string("FRAMETYP", "MASTER");
        header.set_string("CALSTAT", "Skotiq live stack");
        header.set_int("NFRAMES", self.stacked_frames as i64);

        header.set_float("EXPTIME", self.total_integration_secs);
        header.set_comment("EXPTIME", &self.exptime_comment());

        let (date_obs, comment) = self.date_obs();
        header.set_string("DATE-OBS", &date_obs);
        header.set_comment("DATE-OBS", comment);

        header.add_history(&format!(
            "Live stack of {} frames; EXPTIME summed from {} frame headers",
            self.stacked_frames, self.frames_with_exposure
        ));
        header
    }

    /// The master's `DATE-OBS` and the comment disclosing where it came from.
    fn date_obs(&self) -> (String, &'static str) {
        if let Some((parsed, _)) = &self.earliest_date_obs {
            return (
                parsed.format(DATE_OBS_FORMAT).to_string(),
                "earliest stacked frame",
            );
        }
        if let Some(raw) = &self.first_unparsed_date_obs {
            return (raw.clone(), "as reported by a stacked frame");
        }
        (
            self.started_at.format(DATE_OBS_FORMAT).to_string(),
            "live stack started; no frame reported DATE-OBS",
        )
    }

    fn exptime_comment(&self) -> String {
        if self.frames_with_exposure == 0 {
            return "no stacked frame reported EXPTIME".to_string();
        }
        if self.frames_with_exposure == self.stacked_frames {
            return format!(
                "total integration of {} stacked frames",
                self.stacked_frames
            );
        }
        format!(
            "integration of {} of {} stacked frames",
            self.frames_with_exposure, self.stacked_frames
        )
    }
}

/// Parse a FITS `DATE-OBS`. UTC is the FITS convention, so a stamp without an
/// offset is read as UTC; anything else returns `None` rather than a guess.
fn parse_date_obs(text: &str) -> Option<DateTime<Utc>> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(text) {
        return Some(parsed.with_timezone(&Utc));
    }
    NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S%.f")
        .ok()
        .and_then(|naive| Utc.from_local_datetime(&naive).single())
}

/// Write the stacked master to `path` as FITS, with the header
/// [`StackProvenance::to_fits_header`] synthesizes.
pub fn write_stack_master(
    path: &Path,
    image: &ImageData,
    provenance: &StackProvenance,
) -> Result<(), FitsError> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    write_fits(path, image, &provenance.to_fits_header())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(hour: u32, minute: u32, second: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 8, 14, hour, minute, second)
            .unwrap()
    }

    #[test]
    fn unknown_exposures_contribute_nothing_to_the_integration() {
        let mut provenance = StackProvenance::started_at(at(3, 0, 0));
        provenance.fold(&FrameProvenance::unknown());
        provenance.fold(&FrameProvenance {
            exposure_secs: Some(30.0),
            date_obs: None,
        });

        assert_eq!(provenance.total_integration_secs(), 30.0);
        assert_eq!(provenance.stacked_frames(), 2);
    }

    #[test]
    fn a_nonsense_exposure_is_ignored_rather_than_summed() {
        let mut provenance = StackProvenance::started_at(at(3, 0, 0));
        provenance.fold(&FrameProvenance {
            exposure_secs: Some(f64::NAN),
            date_obs: None,
        });
        provenance.fold(&FrameProvenance {
            exposure_secs: Some(-5.0),
            date_obs: None,
        });

        assert_eq!(provenance.total_integration_secs(), 0.0);
        assert_eq!(
            provenance.to_fits_header().get_comment("EXPTIME"),
            Some("no stacked frame reported EXPTIME")
        );
    }

    #[test]
    fn an_offset_stamp_is_compared_in_utc() {
        let mut provenance = StackProvenance::started_at(at(3, 0, 0));
        // 03:30 UTC, written as 05:30+02:00 — earlier than the 04:00 UTC frame
        // only if the offset is honoured.
        provenance.fold(&FrameProvenance {
            exposure_secs: None,
            date_obs: Some("2026-08-14T04:00:00".to_string()),
        });
        provenance.fold(&FrameProvenance {
            exposure_secs: None,
            date_obs: Some("2026-08-14T05:30:00+02:00".to_string()),
        });

        let header = provenance.to_fits_header();
        assert_eq!(
            header.get_string("DATE-OBS"),
            Some("2026-08-14T03:30:00.000")
        );
        assert_eq!(
            header.get_comment("DATE-OBS"),
            Some("earliest stacked frame")
        );
    }

    #[test]
    fn an_unparseable_stamp_is_preferred_over_the_stack_start() {
        let mut provenance = StackProvenance::started_at(at(3, 0, 0));
        provenance.fold(&FrameProvenance {
            exposure_secs: None,
            date_obs: Some("14/08/26 04:00:00".to_string()),
        });

        let header = provenance.to_fits_header();
        assert_eq!(header.get_string("DATE-OBS"), Some("14/08/26 04:00:00"));
        assert_eq!(
            header.get_comment("DATE-OBS"),
            Some("as reported by a stacked frame")
        );
    }
}
