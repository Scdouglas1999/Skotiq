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

    /// Whether `card` names a frame of type `base`, read the way `reading`
    /// says. Only [`CardReading::Contains`] knows other words for a kind
    /// ("science", "offset").
    pub fn card_names(card: &str, base: FrameType, reading: CardReading) -> bool {
        let word = base.as_str().to_ascii_lowercase();
        match reading {
            CardReading::Contains => {
                Self::from_imagetyp(card).is_some_and(|kind| kind.base == base)
            }
            CardReading::Word => card
                .to_ascii_lowercase()
                .split(|c: char| !c.is_ascii_alphanumeric())
                .any(|w| w == word),
            CardReading::Exact => {
                card.eq_ignore_ascii_case(&word)
                    || card.eq_ignore_ascii_case(&format!("{word} frame"))
            }
        }
    }

    /// Whether a `FRAMETYP` or `IMAGETYP` card says "master", read the way
    /// `reading` says ([`CardReading::Word`] reads it as one of the words).
    pub fn card_says_master(card: &str, reading: CardReading) -> bool {
        let t = card.to_ascii_lowercase();
        match reading {
            CardReading::Contains => t.contains("master"),
            CardReading::Word => t
                .split(|c: char| !c.is_ascii_alphanumeric())
                .any(|w| w == "master"),
            CardReading::Exact => t == "master",
        }
    }
}

/// How strictly a reader takes a card's spelling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CardReading {
    /// The word anywhere in the card, as [`FrameKind::from_imagetyp`] reads it.
    Contains,
    /// The word as one whole word of the card ("Master Dark", "DARK").
    Word,
    /// The card is the word, alone or followed by " frame" ("Light Frame"),
    /// ignoring case.
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
    fn each_reading_names_a_kind_its_own_way() {
        use CardReading::*;
        for (card, base, contains, word, exact) in [
            ("Light", FrameType::Light, true, true, true),
            ("LIGHT FRAME", FrameType::Light, true, true, true),
            ("Light_Frame", FrameType::Light, true, true, false),
            ("Science", FrameType::Light, true, false, false),
            ("MASTER_LIGHT", FrameType::Light, true, true, false),
            ("Master Dark", FrameType::Dark, true, true, false),
            ("DarkFlat", FrameType::Dark, false, false, false),
            ("DarkFlat", FrameType::DarkFlat, true, true, true),
            ("Dark Flat", FrameType::Flat, false, true, false),
            ("Offset", FrameType::Bias, true, false, false),
            ("", FrameType::Light, false, false, false),
        ] {
            assert_eq!(
                FrameKind::card_names(card, base, Contains),
                contains,
                "{card:?} contains"
            );
            assert_eq!(
                FrameKind::card_names(card, base, Word),
                word,
                "{card:?} word"
            );
            assert_eq!(
                FrameKind::card_names(card, base, Exact),
                exact,
                "{card:?} exact"
            );
        }
        for (card, contains, word, exact) in [
            ("MASTER", true, true, true),
            ("master", true, true, true),
            ("Master Dark", true, true, false),
            ("MASTERDARK", true, false, false),
            ("Light", false, false, false),
        ] {
            assert_eq!(
                FrameKind::card_says_master(card, Contains),
                contains,
                "{card:?}"
            );
            assert_eq!(FrameKind::card_says_master(card, Word), word, "{card:?}");
            assert_eq!(FrameKind::card_says_master(card, Exact), exact, "{card:?}");
        }
    }
}
