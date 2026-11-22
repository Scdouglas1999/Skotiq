//! The cards that say what a frame or product is: the master cards every
//! master builder writes, what a reader can tell from them, how the frame was
//! taken, and whether it was already calibrated.
//!
//! Builders and readers disagree today on spelling and strictness; each passes
//! its own spelling or reading here so the differences are visible in one
//! place.

use crate::FitsHeader;
use skotiq_frame::{Acquisition, CardReading, FrameKind, FrameType};

/// The identification cards of a master or other product, written
/// in this order: `IMAGETYP`, `FRAMETYP = MASTER`, `CALSTAT`, `NFRAMES`,
/// `NCOMBINE`. A card left `None` (or `frame_type` false) is not written.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProductCards<'a> {
    /// The `IMAGETYP` spelling this product is written with.
    pub image_type: &'a str,
    /// Whether `FRAMETYP = MASTER` is written.
    pub frame_type: bool,
    /// The `CALSTAT` label naming the step that made it.
    pub calstat: Option<&'a str>,
    /// `NFRAMES`, the frames behind it.
    pub frames: Option<i64>,
    /// `NCOMBINE`, the frames combined into it.
    pub combined: Option<i64>,
}

impl ProductCards<'_> {
    /// A file named only by its `IMAGETYP` (a coverage or rejection map, a
    /// registration reference, a streamed dark or bias master).
    pub fn image_type(image_type: &str) -> ProductCards<'_> {
        ProductCards {
            image_type,
            frame_type: false,
            calstat: None,
            frames: None,
            combined: None,
        }
    }

    /// A Skotiq product made from a master (a finishing step, an atlas
    /// cutout): `IMAGETYP` and `CALSTAT`.
    pub fn product<'a>(image_type: &'a str, calstat: &'a str) -> ProductCards<'a> {
        ProductCards {
            image_type,
            frame_type: false,
            calstat: Some(calstat),
            frames: None,
            combined: None,
        }
    }

    /// A Skotiq master: `IMAGETYP`, `FRAMETYP = MASTER` and `CALSTAT`.
    pub fn master<'a>(image_type: &'a str, calstat: &'a str) -> ProductCards<'a> {
        ProductCards {
            image_type,
            frame_type: true,
            calstat: Some(calstat),
            frames: None,
            combined: None,
        }
    }

    pub fn with_frames(self, frames: i64) -> Self {
        Self {
            frames: Some(frames),
            ..self
        }
    }

    pub fn with_combined(self, combined: i64) -> Self {
        Self {
            combined: Some(combined),
            ..self
        }
    }

    pub fn write_to(&self, header: &mut FitsHeader) {
        header.set_string("IMAGETYP", self.image_type);
        if self.frame_type {
            header.set_string("FRAMETYP", "MASTER");
        }
        if let Some(label) = self.calstat {
            header.set_string("CALSTAT", label);
        }
        if let Some(frames) = self.frames {
            header.set_int("NFRAMES", frames);
        }
        if let Some(combined) = self.combined {
            header.set_int("NCOMBINE", combined);
        }
    }
}

/// What a header's master cards say, as read back from any writer.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MasterProvenance {
    /// `IMAGETYP`.
    pub image_type: Option<String>,
    /// `FRAMETYP`.
    pub frame_type: Option<String>,
    /// `NFRAMES`.
    pub frames: Option<i64>,
    /// `NCOMBINE`.
    pub combined: Option<i64>,
}

impl MasterProvenance {
    pub fn from_header(header: &FitsHeader) -> Self {
        let text = |key: &str| header.get_string(key).map(str::to_string);
        Self {
            image_type: text("IMAGETYP"),
            frame_type: text("FRAMETYP"),
            frames: header.get_int("NFRAMES"),
            combined: header.get_int("NCOMBINE"),
        }
    }

    /// Whether `FRAMETYP` says master, read the way `reading` says.
    pub fn frame_type_says_master(&self, reading: CardReading) -> bool {
        self.frame_type
            .as_deref()
            .is_some_and(|card| FrameKind::card_says_master(card, reading))
    }

    /// Whether any card says the frame was integrated from several: `FRAMETYP`
    /// or `IMAGETYP` contains "master", or `NCOMBINE` or `NFRAMES` is above one.
    pub fn any_card_says_integrated(&self) -> bool {
        let says_master = |card: &Option<String>| {
            card.as_deref()
                .is_some_and(|card| FrameKind::card_says_master(card, CardReading::Contains))
        };
        says_master(&self.frame_type)
            || says_master(&self.image_type)
            || self.combined.is_some_and(|n| n > 1)
            || self.frames.is_some_and(|n| n > 1)
    }

    /// Whether `IMAGETYP` names a frame of type `base`, read the way `reading`
    /// says; a header without the card names none.
    pub fn image_type_names(&self, base: FrameType, reading: CardReading) -> bool {
        self.image_type
            .as_deref()
            .is_some_and(|card| FrameKind::card_names(card, base, reading))
    }
}

/// How a frame was taken, from the cards that state it: `EXPTIME` (else
/// `EXPOSURE`), `SET-TEMP` (else `SET_TEMP`), `READOUTM`, `INSTRUME`,
/// `FILTER`, and the numeric `GAIN`, `OFFSET`, `XBINNING`, `YBINNING`.
pub fn acquisition(header: &FitsHeader) -> Acquisition {
    let text = |key: &str| header.get_string(key).map(str::to_string);
    let first_number = |keys: &[&str]| keys.iter().find_map(|key| header.get_float(key));
    Acquisition {
        instrument: text("INSTRUME"),
        filter: text("FILTER"),
        exposure_s: first_number(&["EXPTIME", "EXPOSURE"]),
        set_point_c: first_number(&["SET-TEMP", "SET_TEMP"]),
        read_mode: text("READOUTM"),
        gain: header.get_float("GAIN"),
        offset: header.get_float("OFFSET"),
        bin_x: header.get_float("XBINNING"),
        bin_y: header.get_float("YBINNING"),
    }
}

/// The marks a header can carry that its frame was already calibrated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CalibrationMarks {
    /// A `CALSTAT` card, even an empty one.
    pub calstat_card: bool,
    /// A `CALSTAT` card with text (Skotiq and MaxIm DL write one).
    pub calstat_text: bool,
    /// The HISTORY line PixInsight's ImageCalibration writes.
    pub pixinsight_history: bool,
}

impl CalibrationMarks {
    pub fn from_header(header: &FitsHeader) -> Self {
        let calstat = header.get_string("CALSTAT");
        Self {
            calstat_card: calstat.is_some(),
            calstat_text: calstat.is_some_and(|value| !value.trim().is_empty()),
            pixinsight_history: header
                .history
                .iter()
                .any(|line| line.starts_with("Calibration with ImageCalibration")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn master_cards_are_written_in_order_and_read_back() {
        let mut header = FitsHeader::new();
        ProductCards::master("FLAT", "Skotiq master flat")
            .with_frames(20)
            .with_combined(20)
            .write_to(&mut header);
        let written: Vec<_> = header.cards().map(|(key, _, _)| key.to_string()).collect();
        assert_eq!(
            written,
            ["IMAGETYP", "FRAMETYP", "CALSTAT", "NFRAMES", "NCOMBINE"]
        );
        let read = MasterProvenance::from_header(&header);
        assert!(read.frame_type_says_master(CardReading::Exact));
        assert!(read.any_card_says_integrated());
        assert!(read.image_type_names(FrameType::Flat, CardReading::Word));
        assert_eq!((read.frames, read.combined), (Some(20), Some(20)));
    }

    #[test]
    fn a_streamed_dark_says_integrated_by_its_type_and_count_only() {
        let mut header = FitsHeader::new();
        ProductCards::image_type("Master Dark").write_to(&mut header);
        let read = MasterProvenance::from_header(&header);
        assert!(!read.frame_type_says_master(CardReading::Exact));
        assert!(read.any_card_says_integrated());
        assert!(read.image_type_names(FrameType::Dark, CardReading::Word));
    }

    #[test]
    fn calibration_marks_tell_an_empty_calstat_from_a_label() {
        let mut header = FitsHeader::new();
        assert_eq!(
            CalibrationMarks::from_header(&header),
            CalibrationMarks {
                calstat_card: false,
                calstat_text: false,
                pixinsight_history: false
            }
        );
        header.set_string("CALSTAT", " ");
        let marks = CalibrationMarks::from_header(&header);
        assert!(marks.calstat_card && !marks.calstat_text);
        header.add_history("Calibration with ImageCalibration process");
        assert!(CalibrationMarks::from_header(&header).pixinsight_history);
    }

    #[test]
    fn the_image_size_needs_two_positive_axes() {
        let mut header = FitsHeader::new();
        assert_eq!((header.image_size(), header.planes()), (None, 1));
        header.set_int("NAXIS1", 4);
        assert_eq!(header.image_size(), None);
        header.set_int("NAXIS2", 3);
        header.set_int("NAXIS3", 0);
        assert_eq!((header.image_size(), header.planes()), (Some((4, 3)), 1));
        header.set_int("NAXIS3", 3);
        header.set_int("NAXIS1", -4);
        assert_eq!((header.image_size(), header.planes()), (None, 3));
    }
}
