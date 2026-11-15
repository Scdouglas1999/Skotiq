//! The filter-name rule. A filter's name stands for the set of bands it names:
//! split at spaces, slashes, dashes, underscores, plus signs and bars, long
//! spellings folded onto the short ones ("Luminance" and "Clear" are L, "Red"
//! is R, "H-alpha" is HA, "Sulfur II" is SII), and a bandwidth such as "7nm"
//! left out. "Ha 7nm" is HA, "Ha/OIII" is HA and OIII, "UV/IR Cut" is UV, IR
//! and CUT. Two names are the same filter when their bands are the same; a name
//! is never matched by a piece of another ("R" is not "Dark").
//!
//! `models/equipment/filter_names.dart` in the Dart package `skotiq_core`
//! holds the same rule for the app. Both are tested against
//! `packages/skotiq_core/test/fixtures/filter_matching_cases.json`.

use std::collections::BTreeSet;

fn band_alias(letters: &str) -> Option<&'static str> {
    Some(match letters {
        "L" | "LUM" | "LUMINANCE" | "LUMINOSITY" | "CLEAR" => "L",
        "R" | "RED" => "R",
        "G" | "GREEN" => "G",
        "B" | "BLUE" => "B",
        "H" | "HA" | "HALPHA" | "HYDROGEN" | "HYDROGENALPHA" => "HA",
        "HB" | "HBETA" | "HYDROGENBETA" => "HB",
        "OIII" | "O3" | "OXYGEN" | "OXYGENIII" => "OIII",
        "SII" | "S2" | "SULFUR" | "SULPHUR" | "SULFURII" | "SULPHURII" => "SII",
        "NII" | "N2" | "NITROGEN" | "NITROGENII" => "NII",
        _ => return None,
    })
}

fn letters(text: &str) -> String {
    text.chars()
        .filter(char::is_ascii_alphanumeric)
        .collect::<String>()
        .to_ascii_uppercase()
}

fn is_number(word: &str) -> bool {
    let mut parts = word.splitn(2, ['.', ',']);
    let whole = parts.next().unwrap_or("");
    let fraction = parts.next();
    !whole.is_empty()
        && whole.chars().all(|c| c.is_ascii_digit())
        && fraction.is_none_or(|f| !f.is_empty() && f.chars().all(|c| c.is_ascii_digit()))
}

fn is_width_unit(word: &str) -> bool {
    word.eq_ignore_ascii_case("nm") || word.eq_ignore_ascii_case("a") || word == "å" || word == "Å"
}

fn is_width(word: &str) -> bool {
    let unit_start = word
        .char_indices()
        .find(|(_, c)| !(c.is_ascii_digit() || *c == '.' || *c == ','))
        .map(|(i, _)| i);
    unit_start.is_some_and(|i| i > 0 && is_number(&word[..i]) && is_width_unit(&word[i..]))
}

/// The bands `name` names (see the module comment); empty for a blank name.
pub fn filter_bands(name: &str) -> BTreeSet<String> {
    let whole = letters(name);
    if whole.is_empty() {
        return BTreeSet::new();
    }
    if let Some(band) = band_alias(&whole) {
        return BTreeSet::from([band.to_string()]);
    }
    let words: Vec<&str> = name
        .split(|c: char| c.is_whitespace() || matches!(c, '/' | '-' | '_' | '+' | '|'))
        .filter(|word| !word.is_empty())
        .collect();
    let mut bands = BTreeSet::new();
    let mut i = 0;
    while i < words.len() {
        let word = words[i];
        let next = words.get(i + 1).copied();
        i += 1;
        if is_width(word) {
            continue;
        }
        if let Some(next) = next {
            if is_number(word) && is_width_unit(next) {
                i += 1;
                continue;
            }
        }
        let word_letters = letters(word);
        if word_letters.is_empty() {
            continue;
        }
        if let Some(band) =
            next.and_then(|next| band_alias(&(word_letters.clone() + &letters(next))))
        {
            bands.insert(band.to_string());
            i += 1;
            continue;
        }
        bands.insert(band_alias(&word_letters).map_or(word_letters, str::to_string));
    }
    bands
}

/// Whether `a` and `b` are the same filter by the filter-name rule. Two blank
/// names are the same (no filter); a blank and a named filter are not.
pub fn same_filter(a: &str, b: &str) -> bool {
    filter_bands(a) == filter_bands(b)
}

/// Which slot of a wheel a filter name means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FilterSlotMatch {
    /// The 0-based slot.
    Slot(usize),
    /// No slot is that filter.
    Missing,
    /// Several differently named slots are that filter ("Ha" on a wheel with
    /// "Ha 3nm" and "Ha 7nm"), so the name says none of them.
    Ambiguous(Vec<usize>),
}

/// The slot of `names` that `requested` means: the first slot with the same
/// name ignoring case and surrounding space, else the one slot that is
/// [`same_filter`]. A blank request is [`FilterSlotMatch::Missing`]; a filter
/// is never guessed.
pub fn match_filter_slot(names: &[String], requested: &str) -> FilterSlotMatch {
    let bands = filter_bands(requested);
    if bands.is_empty() {
        return FilterSlotMatch::Missing;
    }
    let wanted = requested.trim().to_lowercase();
    if let Some(slot) = names
        .iter()
        .position(|name| name.trim().to_lowercase() == wanted)
    {
        return FilterSlotMatch::Slot(slot);
    }
    let candidates: Vec<usize> = (0..names.len())
        .filter(|&i| filter_bands(&names[i]) == bands)
        .collect();
    let spellings: BTreeSet<String> = candidates
        .iter()
        .map(|&i| names[i].trim().to_lowercase())
        .collect();
    match candidates.first() {
        None => FilterSlotMatch::Missing,
        Some(&slot) if spellings.len() == 1 => FilterSlotMatch::Slot(slot),
        Some(_) => FilterSlotMatch::Ambiguous(candidates),
    }
}

impl FilterSlotMatch {
    /// The slot, or why there is none in words for the operator.
    pub fn into_slot(self, names: &[String], requested: &str) -> Result<usize, String> {
        match self {
            FilterSlotMatch::Slot(slot) => Ok(slot),
            FilterSlotMatch::Missing => Err(format!(
                "The filter wheel has no \"{}\" filter (it has {})",
                requested.trim(),
                names.join(", ")
            )),
            FilterSlotMatch::Ambiguous(slots) => Err(format!(
                "\"{}\" could be any of {}; name the one to use",
                requested.trim(),
                slots
                    .iter()
                    .map(|&i| format!("\"{}\"", names[i].trim()))
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../../../../packages/skotiq_core/test/fixtures/filter_matching_cases.json"
        ))
        .expect("the shared filter-name fixture is JSON")
    }

    #[test]
    fn a_name_stands_for_the_bands_the_dart_rule_gives() {
        let fixture = fixture();
        let cases = fixture["bands"].as_array().expect("bands cases");
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let expected: BTreeSet<String> = case["bands"]
                .as_array()
                .expect("bands")
                .iter()
                .map(|band| band.as_str().expect("band").to_string())
                .collect();
            assert_eq!(filter_bands(name), expected, "{name:?}");
        }
    }

    #[test]
    fn a_request_finds_the_slot_the_dart_rule_gives() {
        let fixture = fixture();
        let cases = fixture["slots"].as_array().expect("slot cases");
        assert!(!cases.is_empty());
        for case in cases {
            let names: Vec<String> = case["names"]
                .as_array()
                .expect("names")
                .iter()
                .map(|name| name.as_str().expect("name").to_string())
                .collect();
            let requested = case["requested"].as_str().expect("requested");
            let found = match_filter_slot(&names, requested);
            let slot = match &found {
                FilterSlotMatch::Slot(slot) => Some(*slot as u64),
                _ => None,
            };
            assert_eq!(slot, case["index"].as_u64(), "{requested:?} in {names:?}");
            assert_eq!(
                matches!(found, FilterSlotMatch::Ambiguous(_)),
                case["ambiguous"].as_bool().unwrap_or(false),
                "{requested:?} in {names:?}"
            );
        }
    }

    #[test]
    fn a_missing_or_ambiguous_filter_is_said_in_words() {
        let names: Vec<String> = ["L", "Ha 3nm", "Ha 7nm"].map(String::from).to_vec();
        assert_eq!(
            match_filter_slot(&names, "Ha").into_slot(&names, "Ha"),
            Err("\"Ha\" could be any of \"Ha 3nm\", \"Ha 7nm\"; name the one to use".to_string())
        );
        assert_eq!(
            match_filter_slot(&names, "R").into_slot(&names, "R"),
            Err("The filter wheel has no \"R\" filter (it has L, Ha 3nm, Ha 7nm)".to_string())
        );
    }
}
