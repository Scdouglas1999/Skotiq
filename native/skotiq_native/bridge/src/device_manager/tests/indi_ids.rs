use super::*;

// INDI device-id parsing parity
//
// Every INDI branch under `device_manager/ops/` parses device ids through
// `DeviceManager::parse_indi_device_id`, never a local `device_id.split(':')`.
// These pin the inputs where hand-rolled copies disagree: how many segments
// count as valid, and whether the port reaches the `indi_clients` key parsed
// or as raw text.

/// A device name containing colons is not truncated: everything after the port
/// belongs to the device name.
#[test]
fn indi_id_keeps_a_device_name_that_contains_colons() {
    let (host, port, device_name) =
        DeviceManager::parse_indi_device_id("indi:localhost:7624:ZWO CCD: ASI2600MM")
            .expect("a colon in the device name is legal");
    assert_eq!(host, "localhost");
    assert_eq!(port, 7624);
    assert_eq!(device_name, "ZWO CCD: ASI2600MM");
}

/// The `indi_clients` map is keyed on the port the connect path parsed, so a
/// reader carrying the raw text through would look up "localhost:07624" and
/// miss a client registered as "localhost:7624". Both sides go through the
/// parser and produce the same key.
#[test]
fn indi_server_key_is_the_parsed_port_not_the_raw_text() {
    let (host, port, _) = DeviceManager::parse_indi_device_id("indi:localhost:07624:Camera")
        .expect("a zero-padded port is still a port");
    assert_eq!(format!("{host}:{port}"), "localhost:7624");
}

/// A non-numeric port, an empty host and an empty device name each name
/// nothing that could be connected, so each is rejected.
#[test]
fn indi_id_rejects_ids_that_name_nothing_connectable() {
    for id in [
        "indi:localhost:not-a-port:Camera",
        "indi::7624:Camera",
        "indi:localhost:7624:",
        "indi:localhost:7624",
        "indi:",
        "alpaca:localhost:11111:0",
    ] {
        assert!(
            DeviceManager::parse_indi_device_id(id).is_err(),
            "{id} must not parse as an INDI device id"
        );
    }
}
