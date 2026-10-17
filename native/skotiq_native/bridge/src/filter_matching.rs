pub(crate) fn normalize_filter_name(name: &str) -> String {
    let normalized = name
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_uppercase();

    match normalized.as_str() {
        "LUMINANCE" | "LUM" | "CLEAR" => "L".to_string(),
        "RED" => "R".to_string(),
        "GREEN" => "G".to_string(),
        "BLUE" => "B".to_string(),
        "HALPHA" | "HA" | "H" => "HA".to_string(),
        "OIII" | "O3" | "OXYGENIII" => "OIII".to_string(),
        "SII" | "S2" | "SULFURII" => "SII".to_string(),
        other => other.to_string(),
    }
}

pub(crate) fn find_filter_match(names: &[String], requested: &str) -> Option<usize> {
    let requested_normalized = normalize_filter_name(requested);

    names
        .iter()
        .position(|name| normalize_filter_name(name) == requested_normalized)
        .or_else(|| {
            names.iter().position(|name| {
                let normalized = normalize_filter_name(name);
                normalized.contains(&requested_normalized)
                    || requested_normalized.contains(&normalized)
            })
        })
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
