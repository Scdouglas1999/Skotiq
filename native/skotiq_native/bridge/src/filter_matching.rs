pub(crate) fn normalize_filter_name(name: &str) -> String {
    let normalized = name
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_uppercase();

    match normalized.as_str() {
        "LUMINANCE" | "LUMINOSITY" | "LUM" | "CLEAR" => "L".to_string(),
        "RED" => "R".to_string(),
        "GREEN" => "G".to_string(),
        "BLUE" => "B".to_string(),
        "HALPHA" | "HA" | "H" | "HYDROGEN" | "HYDROGENALPHA" => "HA".to_string(),
        "OIII" | "O3" | "OXYGEN" | "OXYGENIII" => "OIII".to_string(),
        "SII" | "S2" | "SULFUR" | "SULPHUR" | "SULFURII" | "SULPHURII" => "SII".to_string(),
        "NII" | "N2" | "NITROGEN" | "NITROGENII" => "NII".to_string(),
        other => other.to_string(),
    }
}

/// The 0-based slot in `names` that `requested` means: the same name ignoring
/// case and surrounding space, else the first with the same normalized name,
/// else the first whose normalized name contains the request's or is contained
/// in it ("Ha" finds "Ha 7nm"). A blank name or request matches nothing.
///
/// `matchingFilterIndex` in the Dart package `skotiq_core`
/// (`models/equipment/filter_names.dart`) follows the same rule, so the editor names the
/// slot a run will use. Both are tested against
/// `packages/skotiq_core/test/fixtures/filter_matching_cases.json`.
pub(crate) fn find_filter_match(names: &[String], requested: &str) -> Option<usize> {
    let requested_exact = requested.trim().to_lowercase();
    let requested_normalized = normalize_filter_name(requested);
    if requested_normalized.is_empty() {
        return None;
    }

    names
        .iter()
        .position(|name| name.trim().to_lowercase() == requested_exact)
        .or_else(|| {
            names
                .iter()
                .position(|name| normalize_filter_name(name) == requested_normalized)
        })
        .or_else(|| {
            names.iter().position(|name| {
                let normalized = normalize_filter_name(name);
                !normalized.is_empty()
                    && (normalized.contains(&requested_normalized)
                        || requested_normalized.contains(&normalized))
            })
        })
}

/// The profile's name for a wheel's 0-based `slot`, or None when the slot is
/// unknown (-1) or has no non-blank name.
pub(crate) fn filter_slot_name(names: &[String], slot: i32) -> Option<String> {
    let name = names.get(usize::try_from(slot).ok()?)?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Log read "Filter changing · 0 → 1" while Equipment read "R (2 of
    /// 8)": the slot is 0-based and the event carries its name.
    #[test]
    fn a_slot_is_named_from_the_profile() {
        let names: Vec<String> = ["L", "R", " ", "B"].iter().map(|s| s.to_string()).collect();
        assert_eq!(filter_slot_name(&names, 0).as_deref(), Some("L"));
        assert_eq!(filter_slot_name(&names, 1).as_deref(), Some("R"));
        assert_eq!(filter_slot_name(&names, 2), None);
        assert_eq!(filter_slot_name(&names, -1), None);
        assert_eq!(filter_slot_name(&names, 8), None);
    }

    #[test]
    fn test_filter_alias_matching() {
        let names = vec![
            "Luminance".to_string(),
            "Red".to_string(),
            "H-Alpha".to_string(),
        ];

        assert_eq!(find_filter_match(&names, "L"), Some(0));
        assert_eq!(find_filter_match(&names, "Ha"), Some(2));
    }

    #[test]
    fn matches_the_cases_the_dart_matcher_is_tested_against() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../packages/skotiq_core/test/fixtures/filter_matching_cases.json"
        ))
        .unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let names: Vec<String> = case["names"]
                .as_array()
                .unwrap()
                .iter()
                .map(|name| name.as_str().unwrap().to_string())
                .collect();
            let requested = case["requested"].as_str().unwrap();
            let expected = case["index"].as_u64().map(|index| index as usize);
            assert_eq!(
                find_filter_match(&names, requested),
                expected,
                "{requested:?} in {names:?}"
            );
        }
    }
}
