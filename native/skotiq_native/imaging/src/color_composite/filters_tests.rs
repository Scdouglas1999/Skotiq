use super::*;

#[test]
fn filter_names_normalize_to_roles() {
    let table: &[(&str, u32, FilterRole)] = &[
        ("L", 1, FilterRole::Luminance),
        ("Lum", 1, FilterRole::Luminance),
        ("Luminance", 1, FilterRole::Luminance),
        ("luminance ", 1, FilterRole::Luminance),
        ("Clear", 1, FilterRole::Luminance),
        ("UV/IR cut", 1, FilterRole::Luminance),
        ("UV-IR Cut", 1, FilterRole::Luminance),
        ("R", 1, FilterRole::Red),
        ("Red", 1, FilterRole::Red),
        ("G", 1, FilterRole::Green),
        ("green", 1, FilterRole::Green),
        ("B", 1, FilterRole::Blue),
        ("Blue", 1, FilterRole::Blue),
        ("Ha", 1, FilterRole::HAlpha),
        ("H-alpha", 1, FilterRole::HAlpha),
        ("Halpha", 1, FilterRole::HAlpha),
        ("H_Alpha", 1, FilterRole::HAlpha),
        ("Ha 7nm", 1, FilterRole::HAlpha),
        ("Ha3nm", 1, FilterRole::HAlpha),
        ("OIII", 1, FilterRole::Oiii),
        ("O3", 1, FilterRole::Oiii),
        ("[O III]", 1, FilterRole::Oiii),
        ("OIII 6.5nm", 1, FilterRole::Oiii),
        ("SII", 1, FilterRole::Sii),
        ("S2", 1, FilterRole::Sii),
        ("S-II", 1, FilterRole::Sii),
        ("L-eXtreme", 3, FilterRole::Color),
        ("", 3, FilterRole::Color),
        ("Hb", 1, FilterRole::Other("Hb".to_string())),
        ("", 1, FilterRole::Other("no filter name".to_string())),
    ];
    for (name, channels, expected) in table {
        assert_eq!(
            classify_filter(Some(name), *channels),
            *expected,
            "filter {name:?} with {channels} channel(s)"
        );
    }
    assert_eq!(
        classify_filter(None, 1),
        FilterRole::Other("no filter name".to_string())
    );
}

fn input(filter: &str, channels: u32, seconds: f64) -> FilterSetInput {
    FilterSetInput {
        filter: Some(filter.to_string()),
        channels,
        integration_seconds: seconds,
    }
}

#[test]
fn filter_sets_choose_the_conventional_palette() {
    struct Case {
        filters: &'static [(&'static str, u32, f64)],
        palette: Option<Palette>,
        reference: Option<&'static str>,
        alternatives: &'static [Palette],
        excluded: &'static [&'static str],
    }
    let cases = [
        Case {
            filters: &[
                ("L", 1, 1440.0),
                ("R", 1, 1800.0),
                ("G", 1, 2040.0),
                ("B", 1, 2040.0),
            ],
            palette: Some(Palette::Lrgb),
            reference: Some("L"),
            alternatives: &[Palette::Rgb],
            excluded: &[],
        },
        Case {
            filters: &[("Red", 1, 600.0), ("Green", 1, 900.0), ("Blue", 1, 600.0)],
            palette: Some(Palette::Rgb),
            reference: Some("Green"),
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[
                ("R", 1, 600.0),
                ("G", 1, 600.0),
                ("B", 1, 600.0),
                ("Ha", 1, 3600.0),
            ],
            palette: Some(Palette::HaRgb),
            reference: Some("R"),
            alternatives: &[Palette::Rgb],
            excluded: &[],
        },
        Case {
            filters: &[
                ("Lum", 1, 600.0),
                ("R", 1, 600.0),
                ("G", 1, 600.0),
                ("B", 1, 600.0),
                ("H-alpha", 1, 3600.0),
            ],
            palette: Some(Palette::HaLrgb),
            reference: Some("Lum"),
            alternatives: &[Palette::Lrgb, Palette::HaRgb, Palette::Rgb],
            excluded: &[],
        },
        Case {
            filters: &[("Ha", 1, 3600.0), ("OIII", 1, 3600.0), ("SII", 1, 3600.0)],
            palette: Some(Palette::Sho),
            reference: Some("Ha"),
            alternatives: &[Palette::Hoo],
            excluded: &[],
        },
        Case {
            filters: &[("Ha", 1, 3600.0), ("O3", 1, 1800.0)],
            palette: Some(Palette::Hoo),
            reference: Some("Ha"),
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("L", 1, 3600.0)],
            palette: None,
            reference: None,
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("Ha", 1, 3600.0)],
            palette: None,
            reference: None,
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("L", 1, 3600.0), ("R", 1, 600.0), ("G", 1, 600.0)],
            palette: None,
            reference: None,
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("", 3, 3600.0)],
            palette: None,
            reference: None,
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("", 3, 3600.0), ("L", 1, 1800.0)],
            palette: Some(Palette::Lrgb),
            reference: Some("L"),
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("UV/IR cut", 3, 1800.0), ("Ha", 1, 3600.0)],
            palette: Some(Palette::HaRgb),
            reference: Some("UV/IR cut"),
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[("", 3, 1800.0), ("", 3, 3600.0)],
            palette: Some(Palette::Osc),
            reference: None,
            alternatives: &[],
            excluded: &[],
        },
        Case {
            filters: &[
                ("R", 1, 600.0),
                ("G", 1, 600.0),
                ("B", 1, 600.0),
                ("Hb", 1, 600.0),
            ],
            palette: Some(Palette::Rgb),
            reference: Some("R"),
            alternatives: &[],
            excluded: &["Hb"],
        },
        Case {
            filters: &[
                ("R", 1, 600.0),
                ("G", 1, 600.0),
                ("B", 1, 600.0),
                ("OIII", 1, 600.0),
            ],
            palette: Some(Palette::Rgb),
            reference: Some("R"),
            alternatives: &[],
            excluded: &["OIII"],
        },
    ];

    for case in cases {
        let inputs: Vec<FilterSetInput> = case
            .filters
            .iter()
            .map(|(f, c, s)| input(f, *c, *s))
            .collect();
        let plan = plan_filter_set(&inputs, None);
        let names: Vec<&str> = case.filters.iter().map(|(f, _, _)| *f).collect();
        assert_eq!(plan.palette, case.palette, "{names:?}: {}", plan.reason);
        if let Some(expected) = case.reference {
            let reference = plan.reference.expect("a reference");
            assert_eq!(names[reference], expected, "{names:?}: reference");
        }
        assert_eq!(
            plan.alternatives, case.alternatives,
            "{names:?}: alternatives"
        );
        let excluded: Vec<&str> = plan.excluded.iter().map(|(i, _)| names[*i]).collect();
        assert_eq!(excluded, case.excluded, "{names:?}: excluded");
        assert!(!plan.reason.is_empty());
    }
}

#[test]
fn missing_primary_is_named_and_not_synthesized() {
    let plan = plan_filter_set(
        &[
            input("L", 1, 3600.0),
            input("R", 1, 600.0),
            input("G", 1, 600.0),
        ],
        None,
    );
    assert_eq!(plan.palette, None);
    assert!(plan.reason.contains("no B master"), "{}", plan.reason);
    assert!(plan.reason.contains("not synthesized"), "{}", plan.reason);
}

#[test]
fn the_conventional_choice_names_its_alternatives() {
    let plan = plan_filter_set(
        &[
            input("L", 1, 1440.0),
            input("R", 1, 1800.0),
            input("G", 1, 2040.0),
            input("B", 1, 2040.0),
        ],
        None,
    );
    assert!(plan.reason.starts_with("LRGB from"), "{}", plan.reason);
    assert!(
        plan.reason.contains("also possible: RGB"),
        "{}",
        plan.reason
    );
}

#[test]
fn a_preferred_alternative_is_honored_or_refused_with_the_reason() {
    let lrgb = [
        input("L", 1, 1440.0),
        input("R", 1, 1800.0),
        input("G", 1, 2040.0),
        input("B", 1, 2040.0),
    ];
    let rgb = plan_filter_set(&lrgb, Some(Palette::Rgb));
    assert_eq!(rgb.palette, Some(Palette::Rgb));
    assert_eq!(rgb.excluded.len(), 1, "L is left out of RGB");
    assert_eq!(rgb.alternatives, vec![Palette::Lrgb]);

    let sho = plan_filter_set(&lrgb, Some(Palette::Sho));
    assert_eq!(sho.palette, None);
    assert!(sho.reason.contains("SHO"), "{}", sho.reason);
}

#[test]
fn multiple_sessions_of_one_filter_all_take_part() {
    let plan = plan_filter_set(
        &[
            input("L", 1, 1440.0),
            input("Luminance", 1, 3600.0),
            input("R", 1, 600.0),
            input("G", 1, 600.0),
            input("B", 1, 600.0),
        ],
        None,
    );
    assert_eq!(plan.palette, Some(Palette::Lrgb));
    assert_eq!(plan.used.len(), 5);
    assert_eq!(
        plan.reference,
        Some(1),
        "the deeper luminance is the reference"
    );
}

#[test]
fn wire_tokens_round_trip() {
    for token in Palette::WIRE {
        let palette = Palette::from_wire(token).expect("a palette");
        assert_eq!(palette.as_wire(), *token);
    }
    for role in [
        FilterRole::Luminance,
        FilterRole::Red,
        FilterRole::Green,
        FilterRole::Blue,
        FilterRole::HAlpha,
        FilterRole::Oiii,
        FilterRole::Sii,
        FilterRole::Color,
    ] {
        assert_eq!(FilterRole::from_wire(role.as_wire()), Some(role));
    }
}
