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
}
