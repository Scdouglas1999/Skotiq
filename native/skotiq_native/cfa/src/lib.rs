//! The color filter in front of a one-shot-color sensor.
//!
//! One type for every crate that names it: a camera driver reports it, a
//! frame carries it, the FITS and XISF readers and writers spell it, and the
//! demosaic and drizzle code read colors from it. Bayer sensors repeat a 2x2
//! cell, Fujifilm X-Trans sensors a 6x6 one. The text form is the cell's
//! letters row by row as `BAYERPAT` holds them (4 letters for Bayer, 36 for
//! X-Trans, the form Siril and PixInsight read).

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// The color of one filter cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BayerColor {
    Red,
    Green,
    Blue,
}

impl BayerColor {
    fn letter(self) -> char {
        match self {
            BayerColor::Red => 'R',
            BayerColor::Green => 'G',
            BayerColor::Blue => 'B',
        }
    }

    fn from_letter(letter: char) -> Option<Self> {
        match letter.to_ascii_uppercase() {
            'R' => Some(BayerColor::Red),
            'G' => Some(BayerColor::Green),
            'B' => Some(BayerColor::Blue),
            _ => None,
        }
    }
}

/// A 2x2 Bayer cell, named by its letters row by row from pixel (0, 0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum BayerPattern {
    Rggb,
    Grbg,
    Gbrg,
    Bggr,
}

impl BayerPattern {
    /// The RGGB cell seen from each of its four pixels (bit 0: one column in,
    /// bit 1: one row down).
    const BY_ORIGIN: [BayerPattern; 4] = [
        BayerPattern::Rggb,
        BayerPattern::Grbg,
        BayerPattern::Gbrg,
        BayerPattern::Bggr,
    ];

    pub fn color_at(&self, x: usize, y: usize) -> BayerColor {
        let origin = *self as usize;
        // The pixel of the RGGB cell this one is: red at RGGB's origin, blue
        // on its diagonal, green on the other two.
        let here = (x % 2) | (y % 2) << 1;
        match here ^ origin {
            0 => BayerColor::Red,
            3 => BayerColor::Blue,
            _ => BayerColor::Green,
        }
    }

    /// The pattern as seen from a crop whose top-left pixel is (`x`, `y`) of
    /// this one. Only the parity of an offset matters; a negative one wraps.
    ///
    /// | self | (0,0) | (1,0) | (0,1) | (1,1) |
    /// |------|-------|-------|-------|-------|
    /// | RGGB | RGGB  | GRBG  | GBRG  | BGGR  |
    /// | BGGR | BGGR  | GBRG  | GRBG  | RGGB  |
    /// | GRBG | GRBG  | RGGB  | BGGR  | GBRG  |
    /// | GBRG | GBRG  | BGGR  | RGGB  | GRBG  |
    pub fn shifted(&self, x: i64, y: i64) -> Self {
        let origin = *self as usize;
        let shift = x.rem_euclid(2) as usize | (y.rem_euclid(2) as usize) << 1;
        Self::BY_ORIGIN[origin ^ shift]
    }
}

/// A 6x6 X-Trans cell, row-major.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct XTransPattern([[BayerColor; 6]; 6]);

impl XTransPattern {
    pub fn color_at(&self, x: usize, y: usize) -> BayerColor {
        self.0[y % 6][x % 6]
    }
}

/// The color filter of a frame, as it lies at the frame's pixel (0, 0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorFilterArray {
    Bayer(BayerPattern),
    XTrans(XTransPattern),
}

impl From<BayerPattern> for ColorFilterArray {
    fn from(pattern: BayerPattern) -> Self {
        ColorFilterArray::Bayer(pattern)
    }
}

impl ColorFilterArray {
    /// The 2x2 Bayer cell, when this is not an X-Trans mosaic.
    pub fn bayer(&self) -> Option<BayerPattern> {
        match self {
            Self::Bayer(pattern) => Some(*pattern),
            Self::XTrans(_) => None,
        }
    }

    /// Parse a cell from its letters, either case: 4 for Bayer, 36 for
    /// X-Trans.
    pub fn parse(letters: &str) -> Option<Self> {
        let letters = letters.trim();
        let colors: Vec<BayerColor> = letters
            .chars()
            .map(BayerColor::from_letter)
            .collect::<Option<_>>()?;
        match colors.len() {
            4 => BayerPattern::BY_ORIGIN
                .into_iter()
                .find(|pattern| (0..4).all(|i| pattern.color_at(i % 2, i / 2) == colors[i]))
                .map(Self::Bayer),
            36 => {
                let mut cell = [[BayerColor::Green; 6]; 6];
                for (i, color) in colors.into_iter().enumerate() {
                    cell[i / 6][i % 6] = color;
                }
                // Every X-Trans row and column holds red and blue; a 36-letter
                // string without that is not an X-Trans cell.
                let complete = (0..6).all(|i| {
                    let row: Vec<BayerColor> = (0..6).map(|j| cell[i][j]).collect();
                    let col: Vec<BayerColor> = (0..6).map(|j| cell[j][i]).collect();
                    [row, col].iter().all(|line| {
                        line.contains(&BayerColor::Red) && line.contains(&BayerColor::Blue)
                    })
                });
                complete.then_some(Self::XTrans(XTransPattern(cell)))
            }
            _ => None,
        }
    }

    /// The cell's letters, row by row: the `BAYERPAT` value.
    pub fn letters(&self) -> String {
        let size = self.cell_size();
        (0..size)
            .flat_map(|y| (0..size).map(move |x| (x, y)))
            .map(|(x, y)| self.color_at(x, y).letter())
            .collect()
    }

    /// Side of the repeating cell: 2 for Bayer, 6 for X-Trans.
    pub fn cell_size(&self) -> usize {
        match self {
            Self::Bayer(_) => 2,
            Self::XTrans(_) => 6,
        }
    }

    pub fn color_at(&self, x: usize, y: usize) -> BayerColor {
        match self {
            Self::Bayer(pattern) => pattern.color_at(x, y),
            Self::XTrans(pattern) => pattern.color_at(x, y),
        }
    }

    /// The filter as seen from a crop whose top-left pixel is (`x`, `y`) of
    /// this one (`XBAYROFF`/`YBAYROFF`).
    pub fn shifted(&self, x: i64, y: i64) -> Self {
        match self {
            Self::Bayer(pattern) => Self::Bayer(pattern.shifted(x, y)),
            Self::XTrans(pattern) => {
                let (dx, dy) = (x.rem_euclid(6) as usize, y.rem_euclid(6) as usize);
                let mut cell = [[BayerColor::Green; 6]; 6];
                for (row, line) in cell.iter_mut().enumerate() {
                    for (col, color) in line.iter_mut().enumerate() {
                        *color = pattern.color_at(col + dx, row + dy);
                    }
                }
                Self::XTrans(XTransPattern(cell))
            }
        }
    }
}

impl Serialize for ColorFilterArray {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.letters())
    }
}

impl<'de> Deserialize<'de> for ColorFilterArray {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum StoredFilter {
            Letters(String),
            LegacyXTrans {
                #[serde(rename = "XTrans")]
                cell: [[u8; 6]; 6],
            },
        }
        let letters = match StoredFilter::deserialize(deserializer)? {
            StoredFilter::Letters(letters) => letters,
            StoredFilter::LegacyXTrans { cell } => {
                cell.into_iter().flatten().map(char::from).collect()
            }
        };
        ColorFilterArray::parse(&letters).ok_or_else(|| {
            serde::de::Error::custom(format!("'{letters}' names no color filter array"))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const XT3: &str = "GGRGGBGGBGGRBRGRBGGGBGGRGGRGGBRBGBRG";

    #[test]
    fn every_filter_round_trips_through_its_bayerpat_spelling() {
        for letters in ["RGGB", "GRBG", "GBRG", "BGGR", XT3] {
            let cfa = ColorFilterArray::parse(letters).unwrap();
            assert_eq!(cfa.letters(), letters);
            let json = serde_json::to_string(&cfa).unwrap();
            assert_eq!(json, format!("\"{letters}\""));
            assert_eq!(
                serde_json::from_str::<ColorFilterArray>(&json).unwrap(),
                cfa
            );
        }
        assert_eq!(
            ColorFilterArray::parse(" rggb "),
            Some(BayerPattern::Rggb.into())
        );
        assert_eq!(ColorFilterArray::parse("CMYG"), None);
        assert_eq!(ColorFilterArray::parse("RRGB"), None);
        assert_eq!(ColorFilterArray::parse(&"G".repeat(36)), None);
    }

    #[test]
    fn stored_device_filters_from_before_the_shared_type_still_read() {
        assert_eq!(
            serde_json::from_str::<ColorFilterArray>(r#""Rggb""#).unwrap(),
            BayerPattern::Rggb.into()
        );
        let rows: Vec<&[u8]> = XT3.as_bytes().chunks(6).collect();
        let old = serde_json::json!({ "XTrans": rows });
        assert_eq!(
            serde_json::from_value::<ColorFilterArray>(old).unwrap(),
            ColorFilterArray::parse(XT3).unwrap()
        );
    }

    #[test]
    fn a_bayer_cell_names_its_colors_from_pixel_zero() {
        let colors = |pattern: BayerPattern| {
            [(0, 0), (1, 0), (0, 1), (1, 1)].map(|(x, y)| pattern.color_at(x, y))
        };
        use BayerColor::{Blue as B, Green as G, Red as R};
        assert_eq!(colors(BayerPattern::Rggb), [R, G, G, B]);
        assert_eq!(colors(BayerPattern::Grbg), [G, R, B, G]);
        assert_eq!(colors(BayerPattern::Gbrg), [G, B, R, G]);
        assert_eq!(colors(BayerPattern::Bggr), [B, G, G, R]);
        assert_eq!(BayerPattern::Grbg.color_at(3, 5), G);
    }

    #[test]
    fn a_crop_sees_the_pattern_from_its_own_corner() {
        use BayerPattern::*;
        let table = [
            (Rggb, [Rggb, Grbg, Gbrg, Bggr]),
            (Bggr, [Bggr, Gbrg, Grbg, Rggb]),
            (Grbg, [Grbg, Rggb, Bggr, Gbrg]),
            (Gbrg, [Gbrg, Bggr, Rggb, Grbg]),
        ];
        for (source, shifted) in table {
            for (i, (x, y)) in [(0, 0), (1, 0), (0, 1), (1, 1)].into_iter().enumerate() {
                assert_eq!(source.shifted(x, y), shifted[i], "{source:?} by ({x}, {y})");
                assert_eq!(source.shifted(x - 2, y + 4), shifted[i]);
            }
        }
        let xtrans = ColorFilterArray::parse(XT3).unwrap();
        let moved = xtrans.shifted(1, 2);
        for (x, y) in [(0, 0), (5, 3), (2, 4)] {
            assert_eq!(moved.color_at(x, y), xtrans.color_at(x + 1, y + 2));
        }
        assert_eq!(xtrans.shifted(-6, 12), xtrans);
    }
}
