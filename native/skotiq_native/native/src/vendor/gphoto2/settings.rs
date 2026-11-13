//! What the driver reads out of a body's libgphoto2 configuration: the ISO
//! speeds it offers and its long exposure noise reduction switch. Pure
//! functions over a snapshot of the widget tree, so they are tested against
//! the trees real bodies present.

use super::exposure::{ShutterSpeeds, SHUTTER_WIDGETS};
use super::utils::{pick_eos_bulb_choices, pick_raw_format_choice};
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

pub(crate) fn widget_named<'a>(root: &'a ConfigWidget, names: &[&str]) -> Option<&'a ConfigWidget> {
    let mut all = Vec::new();
    root.walk(&mut all);
    names
        .iter()
        .find_map(|name| all.iter().find(|w| w.name == *name).copied())
}

/// What a body says about itself in its configuration tree.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct BodyFacts {
    pub(crate) manufacturer: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) serial: Option<String>,
    /// As the body words it ("100%", "50", "Full").
    pub(crate) battery: Option<String>,
    /// Where a capture is stored ("Internal RAM", "Memory card").
    pub(crate) capture_target: Option<String>,
}

pub(crate) fn body_facts(root: &ConfigWidget) -> BodyFacts {
    let text = |names: &[&str]| {
        widget_named(root, names)
            .and_then(|w| w.value.as_deref())
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_string)
    };
    BodyFacts {
        manufacturer: text(&["manufacturer"]),
        model: text(&["cameramodel", "model"]),
        // An unset serial reads as zeros on some bodies; it identifies nothing.
        serial: text(&["serialnumber", "eosserialnumber"])
            .filter(|s| s.chars().any(|c| c != '0' && !c.is_whitespace())),
        battery: text(&["batterylevel"]),
        capture_target: text(&["capturetarget"]),
    }
}

impl BodyFacts {
    /// A capture kept in the camera's memory (not on its card) has to be
    /// deleted after it is read, or the buffer fills and capture stops.
    pub(crate) fn captures_to_ram(&self) -> bool {
        self.capture_target
            .as_deref()
            .is_some_and(|t| t.to_ascii_lowercase().contains("ram"))
    }

    /// The battery charge in percent, when the body words it as a number.
    pub(crate) fn battery_percent(&self) -> Option<u32> {
        let level = self.battery.as_deref()?;
        let digits: String = level.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok().filter(|p| *p <= 100)
    }

    pub(crate) fn is_canon(&self) -> bool {
        self.manufacturer
            .as_deref()
            .is_some_and(|m| m.to_ascii_lowercase().contains("canon"))
    }

    /// Sony ILCE bodies (A7 II, A7 III) take only one capture per PTP
    /// session; the INDI driver closes the session after each one, except on
    /// the A7R IV, where the reset stops further captures
    /// (gphoto_driver.cpp:1441-1445).
    pub(crate) fn needs_session_reset_after_capture(&self) -> bool {
        let sony = self
            .manufacturer
            .as_deref()
            .is_some_and(|m| m.contains("Sony"));
        let model = self.model.as_deref().unwrap_or_default();
        sony && model.contains("ILCE") && !model.contains("7RM4")
    }
}

/// The body's shutter speeds as its first shutter widget lists them now.
pub(crate) fn shutter_speeds(root: &ConfigWidget) -> Option<ShutterSpeeds> {
    let widget = widget_named(root, &SHUTTER_WIDGETS)?;
    Some(ShutterSpeeds::from_choices(
        &widget.name,
        &widget.choices,
        body_facts(root).is_canon(),
    ))
}

/// How this body opens and closes the shutter for bulb.
///
/// Canon's `eosremoterelease` first, as the INDI driver does
/// (gphoto_driver.cpp:1889-1894), else the `bulb` toggle libgphoto2 2.5
/// gives Canon EOS, Nikon, Sony, Fujifilm, Olympus and Panasonic bodies.
/// `gp_camera_trigger_capture` does not hold a shutter open, so a body with
/// neither has no bulb.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BulbWidget {
    /// Opens by selecting `press` ("Press Full"), closes with `release`;
    /// the choice strings differ between libgphoto2 versions.
    EosRemoteRelease { press: String, release: String },
    /// The `bulb` toggle: 1 open, 0 closed.
    BulbToggle,
}

pub(crate) fn bulb_control(root: &ConfigWidget) -> Option<BulbWidget> {
    if let Some(release) =
        widget_named(root, &["eosremoterelease"]).filter(|w| !w.choices.is_empty())
    {
        let (press, release) = pick_eos_bulb_choices(&release.choices);
        return Some(BulbWidget::EosRemoteRelease { press, release });
    }
    widget_named(root, &["bulb"]).map(|_| BulbWidget::BulbToggle)
}

/// The body's ISO widget: its name and the speeds it offers.
pub(crate) fn iso_widget(root: &ConfigWidget) -> Option<&ConfigWidget> {
    widget_named(root, &["iso", "eos-iso"])
}

/// The image-format widget and the RAW choice to force before a capture.
pub(crate) fn raw_format(root: &ConfigWidget) -> Option<(String, Option<String>)> {
    let widget = widget_named(root, &["imageformat", "imagequality"])?;
    Some((widget.name.clone(), pick_raw_format_choice(&widget.choices)))
}
