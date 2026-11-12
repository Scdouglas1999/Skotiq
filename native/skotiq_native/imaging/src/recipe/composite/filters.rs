//! Which filters a target was imaged through, and how they combine into color.
//!
//! A target's per-filter masters arrive with whatever the capture software wrote
//! into `FILTER` or the filter-wheel slot was named: `Lum`, `Luminance`, `Red`,
//! `H-alpha`, `Ha 7nm`, `O3`, `UV/IR cut`. [`classify_filter`] reduces each
//! to one [`FilterRole`]; [`plan_filter_set`] then chooses the conventional
//! combination for the set and lists the alternatives the same masters allow.
//!
//! # The conventions
//!
//! * Red, green and blue present: an RGB composite. With a luminance master it
//!   is LRGB, the luminance carrying the detail and the RGB the color.
//! * Hydrogen-alpha beside a full RGB set is blended into red (and into the
//!   luminance when there is one): HaRGB / HaLRGB.
//! * Narrowband only: SHO (the Hubble palette) when SII, Ha and OIII are all
//!   present, HOO when only Ha and OIII are. Any two of them can also be mixed
//!   by hand ([`Palette::Custom`], with a [`ChannelMix`]); that is never the
//!   conventional choice, only one the caller may ask for.
//! * A one-shot-color master (three channels) is already color; a luminance
//!   master or Ha beside it makes LRGB or HaRGB with the color master as the
//!   RGB.
//! * Anything else has no conventional color combination and the plan says why
//!   instead of inventing a channel: a set missing one of red, green and blue
//!   gets no color composite, because synthesising the missing primary would
//!   be color the camera never recorded.
//!
//! When the masters allow more than one combination the plan carries the
//! conventional one and names the others, so the caller can offer them.

use std::fmt;

/// What one master contributes to a color composite.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum FilterRole {
    /// Broadband luminance: `L`, `Lum`, `Clear`, `UV/IR cut`.
    Luminance,
    /// Broadband red.
    Red,
    /// Broadband green.
    Green,
    /// Broadband blue.
    Blue,
    /// Hydrogen-alpha, 656.3 nm.
    HAlpha,
    /// Doubly ionised oxygen, 500.7 nm.
    Oiii,
    /// Singly ionised sulphur, 671.6 nm.
    Sii,
    /// A three-channel master from a one-shot-color (Bayer) camera.
    Color,
    /// A filter with no role in any combination this build makes, named as the
    /// header gave it.
    Other(String),
}

impl FilterRole {
    /// The wire token a recipe stores.
    pub fn as_wire(&self) -> &str {
        match self {
            Self::Luminance => "luminance",
            Self::Red => "red",
            Self::Green => "green",
            Self::Blue => "blue",
            Self::HAlpha => "hAlpha",
            Self::Oiii => "oiii",
            Self::Sii => "sii",
            Self::Color => "color",
            Self::Other(_) => "other",
        }
    }

    /// The role a wire token names; `None` for a token no combination uses.
    pub fn from_wire(token: &str) -> Option<Self> {
        Some(match token {
            "luminance" => Self::Luminance,
            "red" => Self::Red,
            "green" => Self::Green,
            "blue" => Self::Blue,
            "hAlpha" => Self::HAlpha,
            "oiii" => Self::Oiii,
            "sii" => Self::Sii,
            "color" => Self::Color,
            _ => return None,
        })
    }

    /// The short name a report prints.
    pub fn short_name(&self) -> String {
        match self {
            Self::Luminance => "L".to_string(),
            Self::Red => "R".to_string(),
            Self::Green => "G".to_string(),
            Self::Blue => "B".to_string(),
            Self::HAlpha => "Ha".to_string(),
            Self::Oiii => "OIII".to_string(),
            Self::Sii => "SII".to_string(),
            Self::Color => "OSC".to_string(),
            Self::Other(name) => name.clone(),
        }
    }
}

/// The role of a master from its filter name and channel count.
///
/// A three-channel master is color whatever its filter is called: a dual-band
/// filter on a one-shot-color camera still produces a Bayer image. A mono
/// master is matched on its filter name with case, spaces, dashes, underscores,
/// brackets and a trailing bandwidth (`7nm`) ignored.
pub fn classify_filter(name: Option<&str>, channels: u32) -> FilterRole {
    if channels == 3 {
        return FilterRole::Color;
    }
    let raw = name.unwrap_or("").trim();
    let key = normalize(raw);
    match key.as_str() {
        "l" | "lum" | "luma" | "luminance" | "clear" | "c" | "cl" | "uvircut" | "uvir"
        | "ircut" | "uvirblock" | "uvircutoff" | "lrgbl" => FilterRole::Luminance,
        "r" | "red" => FilterRole::Red,
        "g" | "green" => FilterRole::Green,
        "b" | "blue" => FilterRole::Blue,
        "ha" | "halpha" | "h" | "hα" | "hydrogenalpha" => FilterRole::HAlpha,
        "oiii" | "o3" | "o" | "oxygen" | "oxygeniii" => FilterRole::Oiii,
        "sii" | "s2" | "s" | "sulfur" | "sulphur" | "sulfurii" | "sulphurii" => FilterRole::Sii,
        _ => FilterRole::Other(if raw.is_empty() {
            "no filter name".to_string()
        } else {
            raw.to_string()
        }),
    }
}

/// Lower-case the name, drop separators and brackets, and strip a trailing
/// bandwidth such as `7nm` or `3.5 nm`.
fn normalize(raw: &str) -> String {
    let mut key: String = raw
        .chars()
        .filter(|c| !matches!(c, ' ' | '-' | '_' | '/' | '[' | ']' | '(' | ')' | '.'))
        .flat_map(char::to_lowercase)
        .collect();
    if let Some(stripped) = key.strip_suffix("nm") {
        let without_digits = stripped.trim_end_matches(|c: char| c.is_ascii_digit());
        if without_digits.len() < stripped.len() && !without_digits.is_empty() {
            key = without_digits.to_string();
        }
    }
    key
}

/// A color combination of a target's per-filter masters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Palette {
    /// Luminance over RGB color.
    Lrgb,
    /// Red, green and blue.
    Rgb,
    /// RGB with Ha blended into red.
    HaRgb,
    /// LRGB with Ha blended into red and into the luminance.
    HaLrgb,
    /// SII to red, Ha to green, OIII to blue.
    Sho,
    /// Ha to red, OIII to green and blue.
    Hoo,
    /// One-shot-color masters averaged into one color image.
    Osc,
    /// Ha, OIII and SII mixed into red, green and blue by a [`ChannelMix`] the
    /// recipe stores.
    Custom,
}

/// The narrowband roles a [`ChannelMix`] reads, in the order SHO lays them
/// over red, green and blue.
pub const NARROWBAND_ROLES: [FilterRole; 3] =
    [FilterRole::Sii, FilterRole::HAlpha, FilterRole::Oiii];

/// How much of each narrowband master goes into red, green and blue: one row
/// per output channel, each a list of `(master, weight)`.
///
/// A channel is the plain weighted sum of its row, as a PixelMath expression
/// `R = a·Ha + b·OIII + c·SII` would compute it. A master a row does not name
/// has weight zero.
#[derive(Debug, Clone, PartialEq)]
pub struct ChannelMix(pub [Vec<(FilterRole, f64)>; 3]);

impl ChannelMix {
    /// The wire names of the three rows.
    pub const CHANNELS: [&'static str; 3] = ["red", "green", "blue"];
    /// Lowest and highest weight a mix accepts. Above 1 a master is boosted,
    /// which a weak OIII or SII often needs; 2 is twice its matched signal.
    pub const WEIGHT_RANGE: (f64, f64) = (0.0, 2.0);

    /// The mix as a recipe stores it: `{"red": {"sii": 1.0}, ...}`.
    pub fn to_json(&self) -> serde_json::Value {
        let mut out = serde_json::Map::new();
        for (channel, row) in Self::CHANNELS.iter().zip(&self.0) {
            let mut weights = serde_json::Map::new();
            for (role, weight) in row {
                weights.insert(role.as_wire().to_string(), serde_json::json!(weight));
            }
            out.insert(channel.to_string(), serde_json::Value::Object(weights));
        }
        serde_json::Value::Object(out)
    }

    /// The mix a hand-made combination of `roles` starts from: SHO when all
    /// three lines are there, otherwise the first of SII, Ha, OIII present to
    /// red and the other to green and blue, which for Ha and OIII is HOO.
    /// `None` with fewer than two narrowband roles.
    pub fn starting_point(roles: &[FilterRole]) -> Option<Self> {
        let present: Vec<FilterRole> = NARROWBAND_ROLES
            .iter()
            .filter(|r| roles.contains(r))
            .cloned()
            .collect();
        match present.as_slice() {
            [_, _, _] => Palette::Sho.mix(),
            [first, second] => Some(Self([
                vec![(first.clone(), 1.0)],
                vec![(second.clone(), 1.0)],
                vec![(second.clone(), 1.0)],
            ])),
            _ => None,
        }
    }
}

impl Palette {
    /// The wire token a recipe stores.
    pub const fn as_wire(&self) -> &'static str {
        match self {
            Self::Lrgb => "lrgb",
            Self::Rgb => "rgb",
            Self::HaRgb => "haRgb",
            Self::HaLrgb => "haLrgb",
            Self::Sho => "sho",
            Self::Hoo => "hoo",
            Self::Osc => "osc",
            Self::Custom => "custom",
        }
    }

    /// The palette a wire token names.
    pub fn from_wire(token: &str) -> Option<Self> {
        Some(match token {
            "lrgb" => Self::Lrgb,
            "rgb" => Self::Rgb,
            "haRgb" => Self::HaRgb,
            "haLrgb" => Self::HaLrgb,
            "sho" => Self::Sho,
            "hoo" => Self::Hoo,
            "osc" => Self::Osc,
            "custom" => Self::Custom,
            _ => return None,
        })
    }

    /// Every wire token, for the parameter documentation.
    pub const WIRE: &'static [&'static str] = &[
        "lrgb", "rgb", "haRgb", "haLrgb", "sho", "hoo", "osc", "custom",
    ];

    /// The name a report prints.
    pub const fn display_name(&self) -> &'static str {
        match self {
            Self::Lrgb => "LRGB",
            Self::Rgb => "RGB",
            Self::HaRgb => "HaRGB",
            Self::HaLrgb => "HaLRGB",
            Self::Sho => "SHO (Hubble palette)",
            Self::Hoo => "HOO (bicolor)",
            Self::Osc => "one-shot color",
            Self::Custom => "Custom mix",
        }
    }

    /// The fixed mix a narrowband palette is; `None` for a palette that is not
    /// a narrowband mix, and for [`Palette::Custom`], whose mix the recipe
    /// stores.
    pub fn mix(&self) -> Option<ChannelMix> {
        match self {
            Self::Sho => Some(ChannelMix([
                vec![(FilterRole::Sii, 1.0)],
                vec![(FilterRole::HAlpha, 1.0)],
                vec![(FilterRole::Oiii, 1.0)],
            ])),
            Self::Hoo => Some(ChannelMix([
                vec![(FilterRole::HAlpha, 1.0)],
                vec![(FilterRole::Oiii, 1.0)],
                vec![(FilterRole::Oiii, 1.0)],
            ])),
            _ => None,
        }
    }

    /// Whether the palette applies a separate luminance over the color.
    pub fn uses_luminance(&self) -> bool {
        matches!(self, Self::Lrgb | Self::HaLrgb)
    }

    /// The roles the palette reads out of `present`, every one required. A
    /// custom mix reads whichever narrowband masters are there.
    fn required(&self, present: &[FilterRole]) -> Vec<FilterRole> {
        let rgb_from_color = present.contains(&FilterRole::Color) && !rgb_present(present);
        let rgb = if rgb_from_color {
            vec![FilterRole::Color]
        } else {
            vec![FilterRole::Red, FilterRole::Green, FilterRole::Blue]
        };
        let mut out = match self {
            Self::Rgb => rgb,
            Self::Lrgb => {
                let mut v = rgb;
                v.push(FilterRole::Luminance);
                v
            }
            Self::HaRgb => {
                let mut v = rgb;
                v.push(FilterRole::HAlpha);
                v
            }
            Self::HaLrgb => {
                let mut v = rgb;
                v.push(FilterRole::HAlpha);
                v.push(FilterRole::Luminance);
                v
            }
            Self::Sho => vec![FilterRole::Sii, FilterRole::HAlpha, FilterRole::Oiii],
            Self::Hoo => vec![FilterRole::HAlpha, FilterRole::Oiii],
            Self::Osc => vec![FilterRole::Color],
            Self::Custom => NARROWBAND_ROLES
                .iter()
                .filter(|r| present.contains(r))
                .cloned()
                .collect(),
        };
        out.sort();
        out
    }
}

fn rgb_present(roles: &[FilterRole]) -> bool {
    [FilterRole::Red, FilterRole::Green, FilterRole::Blue]
        .iter()
        .all(|r| roles.contains(r))
}

impl fmt::Display for Palette {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.display_name())
    }
}

/// One master offered to [`plan_filter_set`].
#[derive(Debug, Clone, PartialEq)]
pub struct FilterSetInput {
    /// The filter name from the header or the filter wheel.
    pub filter: Option<String>,
    /// The master's channel count.
    pub channels: u32,
    /// Total integration in seconds, the measure of depth.
    pub integration_seconds: f64,
}

/// What the plan decided for one input.
#[derive(Debug, Clone, PartialEq)]
pub struct PlannedInput {
    /// Index into the inputs the plan was given.
    pub index: usize,
    pub role: FilterRole,
}

/// The combination chosen for a filter set.
#[derive(Debug, Clone, PartialEq)]
pub struct FilterSetPlan {
    /// The combination, or `None` when the set has no color combination.
    pub palette: Option<Palette>,
    /// The inputs the combination reads.
    pub used: Vec<PlannedInput>,
    /// The input every other is registered onto.
    pub reference: Option<usize>,
    /// Inputs left out, each with the reason.
    pub excluded: Vec<(usize, String)>,
    /// Other combinations the same masters allow.
    pub alternatives: Vec<Palette>,
    /// Why this combination (or none), in the words a report prints.
    pub reason: String,
}

/// Choose the color combination for one target's masters.
///
/// `preferred` selects one of the alternatives instead of the conventional
/// default; a palette the set cannot make is refused with the reason.
pub fn plan_filter_set(inputs: &[FilterSetInput], preferred: Option<Palette>) -> FilterSetPlan {
    let roles: Vec<FilterRole> = inputs
        .iter()
        .map(|input| classify_filter(input.filter.as_deref(), input.channels))
        .collect();
    let has = |role: &FilterRole| roles.iter().any(|r| r == role);
    let has_rgb = rgb_present(&roles);
    let has_color = has(&FilterRole::Color);
    let has_l = has(&FilterRole::Luminance);
    let has_ha = has(&FilterRole::HAlpha);
    let has_o = has(&FilterRole::Oiii);
    let has_s = has(&FilterRole::Sii);

    let mut possible: Vec<Palette> = Vec::new();
    if has_rgb || has_color {
        if has_ha && has_l {
            possible.push(Palette::HaLrgb);
        }
        if has_l {
            possible.push(Palette::Lrgb);
        }
        if has_ha {
            possible.push(Palette::HaRgb);
        }
        if has_rgb {
            possible.push(Palette::Rgb);
        } else if roles.iter().filter(|r| **r == FilterRole::Color).count() > 1 {
            possible.push(Palette::Osc);
        }
    }
    if has_ha && has_o && has_s {
        possible.push(Palette::Sho);
    }
    if has_ha && has_o {
        possible.push(Palette::Hoo);
    }
    let custom_possible = NARROWBAND_ROLES.iter().filter(|r| has(r)).count() >= 2;
    if custom_possible {
        possible.push(Palette::Custom);
    }

    let chosen = match preferred {
        Some(wanted) if possible.contains(&wanted) => Some(wanted),
        Some(wanted) => {
            return FilterSetPlan {
                palette: None,
                used: Vec::new(),
                reference: None,
                excluded: Vec::new(),
                alternatives: possible,
                reason: if wanted == Palette::Custom {
                    "a custom mix needs at least two of Ha, OIII and SII and these masters do \
                     not provide them"
                        .to_string()
                } else {
                    format!(
                        "{} needs {} and these masters do not provide them",
                        wanted.display_name(),
                        describe_roles(&wanted.required(&roles))
                    )
                },
            };
        }
        // A mix made by hand is never chosen for the operator.
        None => possible.iter().copied().find(|p| *p != Palette::Custom),
    };

    let Some(palette) = chosen else {
        return FilterSetPlan {
            palette: None,
            used: Vec::new(),
            reference: None,
            excluded: Vec::new(),
            alternatives: possible,
            reason: if custom_possible {
                format!(
                    "{}; they can still be mixed by hand as a custom mix",
                    no_palette_reason(&roles)
                )
            } else {
                no_palette_reason(&roles)
            },
        };
    };

    let required = palette.required(&roles);
    let mut used = Vec::new();
    let mut excluded = Vec::new();
    for (index, role) in roles.iter().enumerate() {
        if required.contains(role) {
            used.push(PlannedInput {
                index,
                role: role.clone(),
            });
        } else {
            excluded.push((index, exclusion_reason(role, palette)));
        }
    }

    let reference = choose_reference(inputs, &used, palette);
    let alternatives: Vec<Palette> = possible.into_iter().filter(|p| *p != palette).collect();
    let mut reason = format!(
        "{} from {}",
        palette.display_name(),
        describe_roles(&required)
    );
    if preferred.is_none() && !alternatives.is_empty() {
        reason.push_str(&format!(
            "; the conventional choice for these filters (also possible: {})",
            alternatives
                .iter()
                .map(|p| p.display_name())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    FilterSetPlan {
        palette: Some(palette),
        used,
        reference,
        excluded,
        alternatives,
        reason,
    }
}

/// The input the others are registered onto: the deepest luminance master when
/// the palette has one, otherwise the deepest master of the role that carries
/// the most signal (Ha for narrowband, the color master for one-shot color,
/// any of red, green and blue for RGB).
fn choose_reference(
    inputs: &[FilterSetInput],
    used: &[PlannedInput],
    palette: Palette,
) -> Option<usize> {
    let preference: &[FilterRole] = match palette {
        Palette::Lrgb | Palette::HaLrgb => &[FilterRole::Luminance],
        Palette::Sho | Palette::Hoo | Palette::Custom => &[FilterRole::HAlpha],
        Palette::Osc => &[FilterRole::Color],
        Palette::Rgb | Palette::HaRgb => &[
            FilterRole::Color,
            FilterRole::Red,
            FilterRole::Green,
            FilterRole::Blue,
        ],
    };
    let deepest = |candidates: &mut dyn Iterator<Item = &PlannedInput>| {
        candidates.map(|p| p.index).max_by(|a, b| {
            inputs[*a]
                .integration_seconds
                .total_cmp(&inputs[*b].integration_seconds)
                // Equal depth resolves to the earlier input, so the choice
                // never depends on the iterator's tie behaviour.
                .then(b.cmp(a))
        })
    };
    if matches!(palette, Palette::Rgb | Palette::HaRgb) {
        let mut broadband = used.iter().filter(|p| preference.contains(&p.role));
        return deepest(&mut broadband);
    }
    for role in preference {
        let mut matching = used.iter().filter(|p| &p.role == role);
        if let Some(index) = deepest(&mut matching) {
            return Some(index);
        }
    }
    let mut any = used.iter();
    deepest(&mut any)
}

fn describe_roles(roles: &[FilterRole]) -> String {
    let names: Vec<String> = roles.iter().map(FilterRole::short_name).collect();
    match names.len() {
        0 => "nothing".to_string(),
        1 => names[0].clone(),
        _ => {
            let (last, rest) = names.split_last().expect("two or more names");
            format!("{} and {}", rest.join(", "), last)
        }
    }
}

fn exclusion_reason(role: &FilterRole, palette: Palette) -> String {
    match role {
        FilterRole::Other(name) => {
            format!("the filter '{name}' has no role in a color combination this build makes")
        }
        other => format!(
            "{} is not part of {}",
            other.short_name(),
            palette.display_name()
        ),
    }
}

/// Why a set of roles has no color combination.
fn no_palette_reason(roles: &[FilterRole]) -> String {
    let distinct: std::collections::BTreeSet<&FilterRole> = roles.iter().collect();
    let broadband: Vec<&FilterRole> = [FilterRole::Red, FilterRole::Green, FilterRole::Blue]
        .iter()
        .filter(|r| distinct.contains(r))
        .collect();
    if !broadband.is_empty() {
        let missing: Vec<String> = [FilterRole::Red, FilterRole::Green, FilterRole::Blue]
            .iter()
            .filter(|r| !distinct.contains(r))
            .map(FilterRole::short_name)
            .collect();
        return format!(
            "a color image needs red, green and blue masters and this set has no {} master; \
             a missing primary is not synthesized, because that would be color the camera \
             never recorded",
            missing.join(" or ")
        );
    }
    if distinct.len() == 1 {
        let only = distinct.iter().next().expect("one role");
        return format!(
            "only {} was imaged, so there is no second filter to combine into color",
            only.short_name()
        );
    }
    if distinct.is_empty() {
        return "there are no masters to combine".to_string();
    }
    format!(
        "{} have no conventional color combination",
        describe_roles(&distinct.into_iter().cloned().collect::<Vec<_>>())
    )
}

#[cfg(test)]
#[path = "filters_tests.rs"]
mod filters_tests;
