//! What the driver reads out of a body's libgphoto2 configuration: the ISO
//! speeds it offers and its long exposure noise reduction switch. Pure
//! functions over a snapshot of the widget tree, so they are tested against
//! the trees real bodies present.

use super::CameraWidgetType;

/// One ISO speed the body offers: the number, and the choice string
/// libgphoto2 sets it by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IsoChoice {
    pub(crate) speed: i32,
    pub(crate) choice: String,
}

/// The selectable ISO speeds in a body's `iso` choices, lowest first.
///
/// A choice is a speed only when it is a whole number ("100", "51200"). Auto
/// ISO ("Auto", "Auto ISO") has no number and is left out, as are choices
/// that name a speed by step instead of value ("Hi 1", "Lo 0.3"): the frame
/// would record a number the camera never said.
pub(crate) fn iso_choices(choices: &[String]) -> Vec<IsoChoice> {
    let mut speeds: Vec<IsoChoice> = choices
        .iter()
        .filter_map(|choice| {
            let speed = choice.trim().parse::<i32>().ok().filter(|s| *s > 0)?;
            Some(IsoChoice {
                speed,
                choice: choice.clone(),
            })
        })
        .collect();
    speeds.sort_by_key(|c| c.speed);
    speeds.dedup_by_key(|c| c.speed);
    speeds
}

/// The offered speed nearest to `requested`, by ratio (ISO steps are
/// multiplicative). A tie goes to the lower speed.
pub(crate) fn nearest_iso(speeds: &[IsoChoice], requested: i32) -> Option<&IsoChoice> {
    let requested = f64::from(requested.max(1));
    speeds.iter().min_by(|a, b| {
        let da = (f64::from(a.speed) / requested).ln().abs();
        let db = (f64::from(b.speed) / requested).ln().abs();
        da.total_cmp(&db)
    })
}

/// A snapshot of one libgphoto2 configuration widget and its children.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ConfigWidget {
    pub(crate) name: String,
    pub(crate) label: String,
    pub(crate) kind: CameraWidgetType,
    /// The current value as text; a toggle reads "0" or "1".
    pub(crate) value: Option<String>,
    pub(crate) choices: Vec<String>,
    pub(crate) children: Vec<ConfigWidget>,
}

impl ConfigWidget {
    fn walk<'a>(&'a self, out: &mut Vec<&'a ConfigWidget>) {
        out.push(self);
        for child in &self.children {
            child.walk(out);
        }
    }
}

/// Whether a widget is a long exposure noise reduction switch. libgphoto2
/// names it per maker (Nikon `longexpnr` "Long Exp Noise Reduction"; other
/// bodies spell the label out or shorten it to "NR"), so both the name and
/// the label are read. High ISO noise reduction is a different setting and
/// does not match.
fn is_long_exposure_nr(widget: &ConfigWidget) -> bool {
    let name = widget.name.to_ascii_lowercase();
    let label = widget.label.to_ascii_lowercase();
    let says_nr = |s: &str| s.contains("noise") || s.contains("nr");
    (name.contains("longexp") && says_nr(&name)) || (label.contains("long exp") && says_nr(&label))
}

fn means_off(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "off" | "0" | "disable" | "disabled" | "no"
    )
}

/// The body's long exposure noise reduction switch, if it shows one.
pub(crate) fn long_exposure_nr_widget(root: &ConfigWidget) -> Option<&ConfigWidget> {
    let mut all = Vec::new();
    root.walk(&mut all);
    all.into_iter().find(|w| {
        is_long_exposure_nr(w)
            && matches!(
                w.kind,
                CameraWidgetType::Radio | CameraWidgetType::Menu | CameraWidgetType::Toggle
            )
    })
}

/// What turning a long exposure noise reduction switch off takes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum NoiseReductionOff {
    AlreadyOff,
    /// Select this choice of a radio or menu widget.
    Choose(String),
    /// Set the toggle to 0.
    ClearToggle,
    /// The widget offers no choice that means off.
    NoOffChoice,
}

pub(crate) fn noise_reduction_off(widget: &ConfigWidget) -> NoiseReductionOff {
    if widget.value.as_deref().is_some_and(means_off) {
        return NoiseReductionOff::AlreadyOff;
    }
    if widget.kind == CameraWidgetType::Toggle {
        return NoiseReductionOff::ClearToggle;
    }
    match widget.choices.iter().find(|c| means_off(c)) {
        Some(choice) => NoiseReductionOff::Choose(choice.clone()),
        None => NoiseReductionOff::NoOffChoice,
    }
}

/// Whether the switch reads off.
pub(crate) fn reads_off(widget: &ConfigWidget) -> bool {
    widget.value.as_deref().is_some_and(means_off)
}
