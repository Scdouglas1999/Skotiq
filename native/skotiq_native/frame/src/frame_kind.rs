//! What a frame's `IMAGETYP` card says it is, as other software writes it.

use crate::FrameType;

/// The kind of frame an `IMAGETYP` card names: a light, dark, flat or bias,
/// and whether it is a master integrated from many.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameKind {
    /// Light, Dark, Flat or Bias.
    pub base: FrameType,
    pub master: bool,
}

impl FrameKind {
    /// Read a card the many ways writers spell it ("Light", "LIGHT", "Light
    /// Frame", "Master Dark", "MASTER_LIGHT", "Offset", "DARKFLAT"), ignoring
    /// case: a card naming a bias or offset is a bias, else one naming both a
    /// dark and a flat is a dark-flat, then a dark, a flat, a light (also
    /// "science" and "object"). "master" anywhere makes it a master. `None`
    /// for a card naming none of these.
    pub fn from_imagetyp(card: &str) -> Option<Self> {
        let t = card.to_ascii_lowercase();
        let base = if t.contains("bias") || t.contains("offset") {
            FrameType::Bias
        } else if t.contains("dark") && t.contains("flat") {
            FrameType::DarkFlat
        } else if t.contains("dark") {
            FrameType::Dark
        } else if t.contains("flat") {
            FrameType::Flat
        } else if t.contains("light") || t.contains("science") || t.contains("object") {
            FrameType::Light
        } else {
            return None;
        };
        Some(Self {
            base,
            master: t.contains("master"),
        })
    }

    /// Whether a `FRAMETYP` or `IMAGETYP` card says "master", read the way
    /// `reading` says.
    pub fn card_says_master(card: &str, reading: CardReading) -> bool {
        let t = card.to_ascii_lowercase();
        match reading {
            CardReading::Contains => t.contains("master"),
            CardReading::Exact => t == "master",
        }
    }
}

/// How strictly a reader takes a card's spelling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CardReading {
    /// The word anywhere in the card, as [`FrameKind::from_imagetyp`] reads it.
    Contains,
    /// The card is the word, ignoring case.
    Exact,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_card_is_read_the_ways_writers_spell_it() {
        let kind = |base, master| Some(FrameKind { base, master });
        for (card, expected) in [
            ("Light", kind(FrameType::Light, false)),
            ("LIGHT", kind(FrameType::Light, false)),
            ("Light Frame", kind(FrameType::Light, false)),
            ("Science", kind(FrameType::Light, false)),
            ("Object", kind(FrameType::Light, false)),
            ("MASTER_LIGHT", kind(FrameType::Light, true)),
            ("Master Dark", kind(FrameType::Dark, true)),
            ("Master Bias", kind(FrameType::Bias, true)),
            ("Offset", kind(FrameType::Bias, false)),
            ("FLAT", kind(FrameType::Flat, false)),
            ("Dark Flat", kind(FrameType::DarkFlat, false)),
            ("DARKFLAT", kind(FrameType::DarkFlat, false)),
            ("FlatDark", kind(FrameType::DarkFlat, false)),
            ("Master DarkFlat", kind(FrameType::DarkFlat, true)),
            ("MASTER_REF", None),
            ("REJECTION_MAP", None),
            ("", None),
        ] {
            assert_eq!(FrameKind::from_imagetyp(card), expected, "{card:?}");
        }
    }

    #[test]
    fn each_reading_says_master_its_own_way() {
        use CardReading::*;
        for (card, contains, exact) in [
            ("MASTER", true, true),
            ("master", true, true),
            ("Master Dark", true, false),
            ("MASTERDARK", true, false),
            ("Light", false, false),
        ] {
            assert_eq!(
                FrameKind::card_says_master(card, Contains),
                contains,
                "{card:?}"
            );
            assert_eq!(FrameKind::card_says_master(card, Exact), exact, "{card:?}");
        }
    }
}
