//! INDI XML parsing helpers and the parser depth-stack context.

use super::*;

pub(super) fn parse_indi_number_attribute(
    attribute: &'static str,
    device: &str,
    property: &str,
    element: &str,
    value: &str,
) -> Option<f64> {
    match value.parse::<f64>() {
        Ok(parsed) => Some(parsed),
        Err(err) => {
            tracing::warn!(
                "Ignoring malformed INDI number attribute {}='{}' for {}.{}.{}: {}",
                attribute,
                value,
                device,
                property,
                element,
                err
            );
            None
        }
    }
}

pub(super) fn parse_indi_usize_attribute(
    attribute: &'static str,
    device: &str,
    property: &str,
    element: &str,
    value: &str,
) -> Option<usize> {
    match value.parse::<usize>() {
        Ok(parsed) => Some(parsed),
        Err(err) => {
            tracing::warn!(
                "Ignoring malformed INDI integer attribute {}='{}' for {}.{}.{}: {}",
                attribute,
                value,
                device,
                property,
                element,
                err
            );
            None
        }
    }
}

pub(super) fn parse_indi_number_value(
    device: &str,
    property: &str,
    element: &str,
    value: &str,
) -> Option<f64> {
    match value.parse::<f64>() {
        Ok(parsed) => Some(parsed),
        Err(err) => {
            tracing::warn!(
                "Ignoring malformed INDI number value '{}' for {}.{}.{}: {}",
                value,
                device,
                property,
                element,
                err
            );
            None
        }
    }
}

pub(super) fn parse_indi_light_state_value(
    device: &str,
    property: &str,
    element: &str,
    value: &str,
) -> Option<i32> {
    match value.parse::<i32>() {
        Ok(parsed) => Some(parsed),
        Err(err) => {
            tracing::warn!(
                "Ignoring malformed INDI light state value '{}' for {}.{}.{}: {}",
                value,
                device,
                property,
                element,
                err
            );
            None
        }
    }
}
/// Kind of an open XML element on the parser depth stack.
///
/// Why: differentiating `*Vector` containers from leaf elements lets us emit the right
/// follow-up event when the frame closes (e.g. `PropertyUpdated` on `setVector` close)
/// and lets `Event::End` validation decide which mismatch is actually fatal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum XmlContextKind {
    /// `defNumberVector`/`defSwitchVector`/`defTextVector`/`defLightVector`/`defBLOBVector`.
    DefVector,
    /// `setNumberVector`/`setSwitchVector`/`setTextVector`/`setLightVector`/`setBLOBVector`
    /// or `newNumberVector` etc.
    SetOrNewVector,
    /// `defNumber`/`defSwitch`/`defText`/`defLight`/`defBLOB` element inside a `def*Vector`.
    DefElement,
    /// `oneNumber`/`oneSwitch`/`oneText`/`oneLight` element inside a `set*`/`new*` vector.
    OneElement,
    /// `oneBLOB` — handled separately because it carries `format`/`size` attributes that
    /// the BLOB receiver path needs to keep alive across the `Text` event.
    OneBlob,
    /// `getProperties`, `enableBLOB`, `delProperty`, `message`, root-level wrappers, etc.
    /// We track them so depth bookkeeping stays correct, but they don't carry parser state.
    Other,
}

/// One frame of the INDI XML parser depth stack.
///
/// Why: INDI bursts arrive as nested elements
/// (`<defNumberVector device="…" name="…"> <defNumber name="…">42</defNumber> … </defNumberVector>`).
/// A malformed or truncated stream with mismatched tags must not silently shift element text
/// onto the wrong (device, property). Each frame remembers the qualified tag name (so `End`
/// can verify it matches the popped frame) plus the device/property/element identifiers
/// that were established when the frame opened. On pop we restore those identifiers from
/// the new top of the stack so sibling `Text`/`Start` events resume against the correct
/// parent context.
#[derive(Debug, Clone)]
pub(super) struct XmlContext {
    pub(super) kind: XmlContextKind,
    /// The exact bytes of the opening tag's qualified name. Used to check for unbalanced
    /// `End` events; we keep it as a `Vec<u8>` because INDI XML stays ASCII.
    pub(super) tag: Vec<u8>,
    pub(super) device: Option<String>,
    pub(super) property: Option<String>,
    pub(super) element: Option<String>,
}

impl XmlContext {
    pub(super) fn new(kind: XmlContextKind, tag: &[u8]) -> Self {
        Self {
            kind,
            tag: tag.to_vec(),
            device: None,
            property: None,
            element: None,
        }
    }
}

/// Refresh the flat `current_*` mirrors from the depth stack.
///
/// Why: the existing parser body reads `current_device`/`current_property`/`current_element`
/// directly in dozens of places. Rather than threading a stack lookup through every match
/// arm, we keep those locals as derived projections of the top-of-stack frame and recompute
/// them whenever a frame is pushed or popped.
pub(super) fn refresh_xml_context_mirrors(
    stack: &[XmlContext],
    current_device: &mut String,
    current_property: &mut String,
    current_element: &mut String,
) {
    current_device.clear();
    current_property.clear();
    current_element.clear();
    for frame in stack {
        if let Some(d) = &frame.device {
            current_device.clear();
            current_device.push_str(d);
        }
        if let Some(p) = &frame.property {
            current_property.clear();
            current_property.push_str(p);
        }
        if let Some(e) = &frame.element {
            current_element.clear();
            current_element.push_str(e);
        }
    }
}

/// Classify an INDI XML tag name into a context kind.
pub(super) fn classify_indi_tag(name: &[u8]) -> XmlContextKind {
    if name.starts_with(b"def") && name.ends_with(b"Vector") {
        XmlContextKind::DefVector
    } else if (name.starts_with(b"set") || name.starts_with(b"new")) && name.ends_with(b"Vector") {
        XmlContextKind::SetOrNewVector
    } else if name == b"oneBLOB" {
        XmlContextKind::OneBlob
    } else if name.starts_with(b"def") {
        XmlContextKind::DefElement
    } else if name.starts_with(b"one") {
        XmlContextKind::OneElement
    } else {
        XmlContextKind::Other
    }
}
pub(super) fn parse_switch_rule(rule: &str) -> IndiSwitchRule {
    match rule {
        "OneOfMany" => IndiSwitchRule::OneOfMany,
        "AtMostOne" => IndiSwitchRule::AtMostOne,
        "AnyOfMany" => IndiSwitchRule::AnyOfMany,
        "OneOfManyZeroOff" => IndiSwitchRule::OneOfManyZeroOff,
        other => {
            tracing::warn!(
                "Unknown INDI switch rule '{}'; treating as OneOfMany",
                other
            );
            IndiSwitchRule::OneOfMany
        }
    }
}

pub(super) fn switch_rule_requires_exclusive_vector(rule: Option<IndiSwitchRule>) -> bool {
    matches!(
        rule,
        Some(IndiSwitchRule::OneOfMany)
            | Some(IndiSwitchRule::AtMostOne)
            | Some(IndiSwitchRule::OneOfManyZeroOff)
    )
}

/// Get current time in milliseconds since UNIX epoch
pub(crate) fn current_time_ms() -> u64 {
    use std::time::SystemTime;
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        // Why: `duration_since(UNIX_EPOCH)` only fails for pre-1970
        // clocks; this timestamp feeds keepalive-tracking counters that are monotonic-difference
        // comparisons, so a zero baseline merely defers the first keepalive by one cycle —
        // not a correctness invariant. u128 -> u64 saturates per Rust 1.45 spec; u64::MAX
        // milliseconds is year ~584M, so saturation only happens after a clock-bug.
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// Zero-allocation lookup helpers for HashMap with tuple keys
// std::collections::HashMap requires owned keys for lookups via .get(),
// which forces allocating Strings from &str just to perform a lookup.
// These helpers iterate the map and compare borrowed keys directly,
// avoiding the allocation. INDI property maps are small (typically <150 entries)
// so the linear scan is not a concern vs. the allocation savings on every
// property read in the polling hot path.

/// Look up a value in a HashMap<(String, String), V> using borrowed &str keys
pub(super) fn map_get_2<'a, V>(
    map: &'a HashMap<(String, String), V>,
    k1: &str,
    k2: &str,
) -> Option<&'a V> {
    map.iter()
        .find(|((a, b), _)| a.as_str() == k1 && b.as_str() == k2)
        .map(|(_, v)| v)
}

/// Look up a mutable value in a HashMap<(String, String), V> using borrowed &str keys
pub(super) fn map_get_mut_2<'a, V>(
    map: &'a mut HashMap<(String, String), V>,
    k1: &str,
    k2: &str,
) -> Option<&'a mut V> {
    map.iter_mut()
        .find(|((a, b), _)| a.as_str() == k1 && b.as_str() == k2)
        .map(|(_, v)| v)
}

/// Check if a HashMap<(String, String), V> contains a key using borrowed &str keys
pub(super) fn map_contains_2<V>(map: &HashMap<(String, String), V>, k1: &str, k2: &str) -> bool {
    map.iter()
        .any(|((a, b), _)| a.as_str() == k1 && b.as_str() == k2)
}

/// Look up a value in a HashMap<(String, String, String), V> using borrowed &str keys
pub(super) fn map_get_3<'a, V>(
    map: &'a HashMap<(String, String, String), V>,
    k1: &str,
    k2: &str,
    k3: &str,
) -> Option<&'a V> {
    map.iter()
        .find(|((a, b, c), _)| a.as_str() == k1 && b.as_str() == k2 && c.as_str() == k3)
        .map(|(_, v)| v)
}

/// Helper to get attribute from XML event
pub(super) fn get_attribute(e: &quick_xml::events::BytesStart, name: &str) -> Option<String> {
    e.attributes()
        .filter_map(|a| a.ok())
        .find(|a| a.key.as_ref() == name.as_bytes())
        .map(|a| String::from_utf8_lossy(&a.value).to_string())
}

pub(super) fn parse_state(s: &str) -> IndiPropertyState {
    match s {
        "Idle" => IndiPropertyState::Idle,
        "Ok" => IndiPropertyState::Ok,
        "Busy" => IndiPropertyState::Busy,
        "Alert" => IndiPropertyState::Alert,
        _ => IndiPropertyState::Idle,
    }
}

pub(super) fn parse_perm(s: &str) -> IndiPermission {
    match s.to_lowercase().as_str() {
        "ro" => IndiPermission::ReadOnly,
        "wo" => IndiPermission::WriteOnly,
        "rw" => IndiPermission::ReadWrite,
        _ => IndiPermission::ReadWrite,
    }
}

/// Validate BLOB format and detect actual format from data
pub(super) fn detect_blob_format(data: &[u8]) -> Option<&'static str> {
    if data.len() >= 6 && &data[0..6] == b"SIMPLE" {
        Some(".fits")
    } else if data.len() >= 8 && data[0..8] == [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A] {
        Some(".png")
    } else if data.len() >= 3 && data[0..3] == [0xFF, 0xD8, 0xFF] {
        Some(".jpeg")
    } else if data.len() >= 4
        && &data[0..4] == b"RIFF"
        && data.len() >= 12
        && &data[8..12] == b"WEBP"
    {
        Some(".webp")
    } else if data.len() >= 4 && data[0..4] == [0x1F, 0x8B, 0x08, 0x00] {
        Some(".gz")
    } else if data.len() >= 2 && data[0..2] == [0x50, 0x4B] {
        Some(".zip")
    } else {
        None
    }
}

pub(super) fn validate_blob_format(declared_format: &str, data: &[u8]) -> String {
    let detected = detect_blob_format(data).unwrap_or(declared_format);

    // Log warning if formats don't match
    if !declared_format.is_empty() && detected != declared_format {
        tracing::debug!(
            "BLOB format mismatch: declared '{}', detected '{}'",
            declared_format,
            detected
        );
    }

    detected.to_string()
}

pub(super) fn resolve_blob_format(declared_format: Option<&str>, data: &[u8]) -> String {
    match declared_format {
        Some(format) => validate_blob_format(format, data),
        None => detect_blob_format(data)
            .map(str::to_string)
            .unwrap_or_else(|| ".blob".to_string()),
    }
}

/// Compare protocol versions (returns true if server >= required)
pub(super) fn is_version_compatible(server: &str, required: &str) -> bool {
    let parse_version = |v: &str| -> (u32, u32) {
        let parts: Vec<&str> = v.split('.').collect();
        // Why: malformed/missing version-component digits default to 0,
        // which makes a malformed INDI server-version report as "1.0" baseline and
        // legitimately FAIL the `>= required` compatibility gate at the caller. Zero is
        // the correct "treat as ancient" fallback for compatibility comparisons.
        let major = parts.first().and_then(|s| s.parse().ok()).unwrap_or(0);
        let minor = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
        (major, minor)
    };

    let (server_major, server_minor) = parse_version(server);
    let (req_major, req_minor) = parse_version(required);

    server_major > req_major || (server_major == req_major && server_minor >= req_minor)
}
