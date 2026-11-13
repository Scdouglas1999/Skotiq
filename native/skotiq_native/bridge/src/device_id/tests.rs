use super::*;
use crate::device_id::cache::parse_device_id_cached;

/// Readers of a parse that only these tests need; the app reads `connection_info`.
impl ParsedDeviceId {
    /// Get the raw device ID string
    fn raw(&self) -> &str {
        &self.raw_id
    }

    /// Get the ASCOM ProgID if this is an ASCOM device
    fn ascom_prog_id(&self) -> Option<&str> {
        match &self.connection_info {
            ConnectionInfo::Ascom { prog_id } => Some(prog_id),
            _ => None,
        }
    }

    /// Get INDI connection info if this is an INDI device
    fn indi_info(&self) -> Option<(&str, u16, &str)> {
        match &self.connection_info {
            ConnectionInfo::Indi {
                host,
                port,
                device_name,
            } => Some((host, *port, device_name)),
            _ => None,
        }
    }

    /// Get native vendor and device ID if this is a native device.
    ///
    /// Returns `(vendor, device_id, device_index)`. For 4-part subtype
    /// or Touptek-brand IDs, prefer the dedicated accessors below — the
    /// `device_id` returned here is the trailing payload only (the
    /// brand / subtype segment is already stripped).
    fn native_info(&self) -> Option<(&str, &str, Option<i32>)> {
        match &self.connection_info {
            ConnectionInfo::Native {
                vendor,
                device_id,
                device_index,
                ..
            } => Some((vendor, device_id, *device_index)),
            _ => None,
        }
    }

    /// Get the native vendor token, lower-cased and validated against
    /// the vendor catalog. `None` for non-native IDs.
    fn native_vendor(&self) -> Option<&str> {
        match &self.connection_info {
            ConnectionInfo::Native { vendor, .. } => Some(vendor.as_str()),
            _ => None,
        }
    }

    /// Get the Touptek brand and discovery index for IDs of the form
    /// `native:touptek:{brand}:{idx}`. Returns `None` for non-Touptek
    /// IDs and for malformed Touptek IDs whose index is non-numeric
    /// (the parser already rejects the latter, but the accessor is
    /// defensive against future encoding changes).
    fn touptek_info(&self) -> Option<(&str, usize)> {
        match &self.connection_info {
            ConnectionInfo::Native {
                vendor,
                device_id,
                vendor_brand: Some(brand),
                ..
            } if vendor == "touptek" => device_id
                .parse::<usize>()
                .ok()
                .map(|idx| (brand.as_str(), idx)),
            _ => None,
        }
    }

    /// Get the ZWO accessory subtype (`eaf` or `efw`) and trailing
    /// payload for 4-part ZWO IDs of the form `native:zwo:eaf:{n}`.
    /// Returns `None` for the composite form `native:zwo_eaf:{n}` —
    /// callers must check `native_vendor()` separately for that
    /// encoding.
    fn zwo_subtype(&self) -> Option<(&str, &str)> {
        match &self.connection_info {
            ConnectionInfo::Native {
                vendor,
                device_id,
                device_subtype: Some(sub),
                ..
            } if vendor == "zwo" => Some((sub.as_str(), device_id.as_str())),
            _ => None,
        }
    }

    /// Get the QHY CFW subtype payload for 4-part QHY IDs
    /// (`native:qhy:cfw:{camera_id}`). Returns `None` for the composite
    /// form `native:qhy_cfw:{camera_id}`.
    fn qhy_subtype(&self) -> Option<(&str, &str)> {
        match &self.connection_info {
            ConnectionInfo::Native {
                vendor,
                device_id,
                device_subtype: Some(sub),
                ..
            } if vendor == "qhy" => Some((sub.as_str(), device_id.as_str())),
            _ => None,
        }
    }

    /// Get the FLI accessory subtype (`focuser` or `fw`) and trailing
    /// payload for 4-part FLI IDs (`native:fli:focuser:{path}`).
    /// Returns `None` for the composite form
    /// (`native:fli_focuser:{path}`).
    fn fli_subtype(&self) -> Option<(&str, &str)> {
        match &self.connection_info {
            ConnectionInfo::Native {
                vendor,
                device_id,
                device_subtype: Some(sub),
                ..
            } if vendor == "fli" => Some((sub.as_str(), device_id.as_str())),
            _ => None,
        }
    }
}

#[test]
fn test_parse_ascom() {
    let parsed = ParsedDeviceId::parse("ascom:ASCOM.Camera.Simulator").unwrap();
    assert_eq!(parsed.driver_type, DriverType::Ascom);
    assert_eq!(parsed.ascom_prog_id(), Some("ASCOM.Camera.Simulator"));
}

#[test]
fn test_parse_alpaca() {
    let parsed = ParsedDeviceId::parse("alpaca:http://192.168.1.100:11111:camera:0").unwrap();
    assert_eq!(parsed.driver_type, DriverType::Alpaca);
    let (proto, host, port, dtype, dnum) = parsed.alpaca_info().unwrap();
    assert_eq!(proto, "http");
    assert_eq!(host, "192.168.1.100");
    assert_eq!(port, 11111);
    assert_eq!(dtype, "camera");
    assert_eq!(dnum, 0);
    assert_eq!(
        parsed.alpaca_base_url(),
        Some("http://192.168.1.100:11111"),
        "base_url must not duplicate the port (FB-/FB-)"
    );
}

/// Canonical Alpaca discovery IDs must round-trip with a single port and a
/// parsed device number — the shape a mis-split parser gets wrong.
#[test]
fn test_parse_alpaca_canonical_discovery_ids() {
    let cases = [
        (
            "alpaca:http://192.168.1.8:11111:camera:0",
            "http",
            "192.168.1.8",
            11111_u16,
            "camera",
            0_u32,
            "http://192.168.1.8:11111",
        ),
        (
            "alpaca:https://alpaca.example.com:11111:telescope:1",
            "https",
            "alpaca.example.com",
            11111,
            "telescope",
            1,
            "https://alpaca.example.com:11111",
        ),
        (
            "alpaca:http://localhost:11111:filterwheel:2",
            "http",
            "localhost",
            11111,
            "filterwheel",
            2,
            "http://localhost:11111",
        ),
        (
            "alpaca:http://host:11111:camera:0",
            "http",
            "host",
            11111,
            "camera",
            0,
            "http://host:11111",
        ),
    ];

    for (raw, proto, host, port, dtype, dnum, base_url) in cases {
        let parsed = ParsedDeviceId::parse(raw)
            .unwrap_or_else(|e| panic!("expected `{}` to parse: {}", raw, e));
        assert_eq!(parsed.driver_type, DriverType::Alpaca, "{}", raw);
        let (p, h, pt, dt, dn) = parsed.alpaca_info().unwrap();
        assert_eq!(p, proto, "protocol for {}", raw);
        assert_eq!(h, host, "host for {}", raw);
        assert_eq!(pt, port, "port for {}", raw);
        assert_eq!(dt, dtype, "device_type for {}", raw);
        assert_eq!(dn, dnum, "device_num for {}", raw);
        assert_eq!(
            parsed.alpaca_base_url(),
            Some(base_url),
            "base_url for {}",
            raw
        );
    }
}

#[test]
fn test_parse_alpaca_bad_device_number() {
    assert!(ParsedDeviceId::parse("alpaca:http://host:11111:camera:notanum").is_err());
}

#[test]
fn test_parse_indi() {
    let parsed = ParsedDeviceId::parse("indi:localhost:7624:ZWO CCD ASI120").unwrap();
    assert_eq!(parsed.driver_type, DriverType::Indi);
    let (host, port, device_name) = parsed.indi_info().unwrap();
    assert_eq!(host, "localhost");
    assert_eq!(port, 7624);
    assert_eq!(device_name, "ZWO CCD ASI120");
}

#[test]
fn test_parse_native() {
    let parsed = ParsedDeviceId::parse("native:zwo:0").unwrap();
    assert_eq!(parsed.driver_type, DriverType::Native);
    let (vendor, device_id, device_index) = parsed.native_info().unwrap();
    assert_eq!(vendor, "zwo");
    assert_eq!(device_id, "0");
    assert_eq!(device_index, Some(0));
}

#[test]
fn test_invalid_empty() {
    assert!(ParsedDeviceId::parse("").is_err());
}

#[test]
fn test_invalid_ascom_no_dot() {
    assert!(ParsedDeviceId::parse("ascom:NoDotProgId").is_err());
}

#[test]
fn test_invalid_alpaca_bad_port() {
    assert!(ParsedDeviceId::parse("alpaca:http://host:notaport:camera:0").is_err());
}

// Multi-segment native ID round-trip tests
//
// Every observed `format!("native:...")` site in `discovery.rs` and
// the per-vendor modules is exercised here. If a vendor agent adds a
// new prefix without a row in `skotiq_native::catalog::FAMILIES`, one of
// these tests fails and the bug is caught at `cargo test` time
// instead of at user-machine "Unknown vendor" startup.

fn assert_native_roundtrip(raw: &str, expected_vendor: &str) {
    let parsed = ParsedDeviceId::parse(raw)
        .unwrap_or_else(|e| panic!("expected `{}` to parse, got: {}", raw, e));
    assert_eq!(parsed.raw(), raw, "raw_id must survive parse for `{}`", raw);
    assert_eq!(
        parsed.native_vendor(),
        Some(expected_vendor),
        "vendor mismatch for `{}`",
        raw
    );
}

#[test]
fn native_zwo_camera_3part() {
    assert_native_roundtrip("native:zwo:0", "zwo");
    let parsed = ParsedDeviceId::parse("native:zwo:7").unwrap();
    let (_, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(dev, "7");
    assert_eq!(idx, Some(7));
    assert!(parsed.zwo_subtype().is_none());
}

#[test]
fn native_zwo_eaf_4part_subtype_form() {
    // Vendor-module emit: `native:zwo:eaf:N`
    assert_native_roundtrip("native:zwo:eaf:0", "zwo");
    let parsed = ParsedDeviceId::parse("native:zwo:eaf:3").unwrap();
    let (sub, payload) = parsed.zwo_subtype().expect("zwo_subtype must surface");
    assert_eq!(sub, "eaf");
    assert_eq!(payload, "3");
    let (_, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(dev, "3");
    assert_eq!(idx, Some(3));
}

#[test]
fn native_zwo_efw_4part_subtype_form() {
    assert_native_roundtrip("native:zwo:efw:0", "zwo");
    let parsed = ParsedDeviceId::parse("native:zwo:efw:1").unwrap();
    let (sub, payload) = parsed.zwo_subtype().unwrap();
    assert_eq!(sub, "efw");
    assert_eq!(payload, "1");
}

#[test]
fn native_zwo_eaf_composite_form() {
    // Discovery-emit: `native:zwo_eaf:N` — composite token, no
    // subtype field set.
    assert_native_roundtrip("native:zwo_eaf:0", "zwo_eaf");
    let parsed = ParsedDeviceId::parse("native:zwo_eaf:0").unwrap();
    assert!(parsed.zwo_subtype().is_none());
    let (_, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(dev, "0");
    assert_eq!(idx, Some(0));
}

#[test]
fn native_zwo_efw_composite_form() {
    assert_native_roundtrip("native:zwo_efw:0", "zwo_efw");
}

#[test]
fn native_qhy_camera_3part() {
    // QHY camera IDs are typically "ModelName-SerialNumber",
    // i.e. non-numeric — `device_index` must be `None`.
    let parsed = ParsedDeviceId::parse("native:qhy:QHY600M-12345").unwrap();
    let (vendor, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(vendor, "qhy");
    assert_eq!(dev, "QHY600M-12345");
    assert_eq!(idx, None);
    // Plain numeric form too:
    let parsed2 = ParsedDeviceId::parse("native:qhy:0").unwrap();
    let (_, _, idx2) = parsed2.native_info().unwrap();
    assert_eq!(idx2, Some(0));
}

#[test]
fn native_qhy_cfw_4part_subtype_form() {
    assert_native_roundtrip("native:qhy:cfw:QHY600M-12345", "qhy");
    let parsed = ParsedDeviceId::parse("native:qhy:cfw:CAM_A").unwrap();
    let (sub, payload) = parsed.qhy_subtype().expect("qhy_subtype must surface");
    assert_eq!(sub, "cfw");
    assert_eq!(payload, "CAM_A");
}

#[test]
fn native_qhy_cfw_composite_form() {
    assert_native_roundtrip("native:qhy_cfw:CAM_A", "qhy_cfw");
    let parsed = ParsedDeviceId::parse("native:qhy_cfw:CAM_A").unwrap();
    assert!(parsed.qhy_subtype().is_none());
}

#[test]
fn native_atik_efw_forms() {
    assert_native_roundtrip("native:atik:efw:0", "atik");
    let parsed = ParsedDeviceId::parse("native:atik:efw:3").unwrap();
    let (vendor, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(vendor, "atik");
    assert_eq!(dev, "3");
    assert_eq!(idx, Some(3));

    assert_native_roundtrip("native:atik_efw:0", "atik_efw");
}

#[test]
fn native_fli_camera_3part_with_path() {
    // FLI uses sanitized device path as ID; path-safe form may
    // contain underscores from `/` or `\` substitution.
    let parsed = ParsedDeviceId::parse("native:fli:_dev_fliusb0").unwrap();
    let (vendor, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(vendor, "fli");
    assert_eq!(dev, "_dev_fliusb0");
    assert_eq!(idx, None);
}

#[test]
fn native_fli_focuser_4part_subtype_form() {
    assert_native_roundtrip("native:fli:focuser:_dev_fliusb0", "fli");
    let parsed = ParsedDeviceId::parse("native:fli:focuser:_dev_fliusb0").unwrap();
    let (sub, payload) = parsed.fli_subtype().unwrap();
    assert_eq!(sub, "focuser");
    assert_eq!(payload, "_dev_fliusb0");
}

#[test]
fn native_fli_fw_4part_subtype_form() {
    assert_native_roundtrip("native:fli:fw:_dev_fliusb0", "fli");
    let parsed = ParsedDeviceId::parse("native:fli:fw:_dev_fliusb0").unwrap();
    let (sub, payload) = parsed.fli_subtype().unwrap();
    assert_eq!(sub, "fw");
    assert_eq!(payload, "_dev_fliusb0");
}

#[test]
fn native_fli_focuser_composite_form() {
    assert_native_roundtrip("native:fli_focuser:_dev_fliusb0", "fli_focuser");
    assert_native_roundtrip("native:fli_fw:_dev_fliusb0", "fli_fw");
}

#[test]
fn native_touptek_4part_brand_form() {
    // Multi-brand SDK: brand identifies which library to load.
    assert_native_roundtrip("native:touptek:ogma:0", "touptek");
    let parsed = ParsedDeviceId::parse("native:touptek:ogma:0").unwrap();
    let (brand, idx) = parsed.touptek_info().expect("touptek_info must surface");
    assert_eq!(brand, "ogma");
    assert_eq!(idx, 0);
    // Other brands the SDK supports:
    for brand in &["altair", "nncam", "starshootg", "touptek"] {
        let raw = format!("native:touptek:{}:2", brand);
        let parsed = ParsedDeviceId::parse(&raw).unwrap();
        let (b, idx) = parsed.touptek_info().unwrap();
        assert_eq!(b, *brand);
        assert_eq!(idx, 2);
    }
}

#[test]
fn native_touptek_3part_is_rejected() {
    // A 3-part Touptek must not silently fall through — the bridge dispatch
    // needs the brand segment.
    let err = ParsedDeviceId::parse("native:touptek:0").unwrap_err();
    let msg = format!("{}", err);
    assert!(
        msg.contains("Touptek"),
        "expected Touptek-specific error, got: {}",
        msg
    );
}

#[test]
fn native_playerone_3part() {
    // Discovery emits `playerone` (no underscore).
    assert_native_roundtrip("native:playerone:0", "playerone");
    let parsed = ParsedDeviceId::parse("native:playerone:0").unwrap();
    let (_, _, idx) = parsed.native_info().unwrap();
    assert_eq!(idx, Some(0));
    assert_native_roundtrip("native:playerone_pw:42", "playerone_pw");
}

#[test]
fn native_player_one_underscore_form() {
    // Dispatch keys on `player_one`; both spellings round-trip.
    assert_native_roundtrip("native:player_one:0", "player_one");
}

#[test]
fn native_svbony_atik_moravian_3part() {
    assert_native_roundtrip("native:svbony:0", "svbony");
    assert_native_roundtrip("native:atik:1", "atik");
    assert_native_roundtrip("native:moravian:0", "moravian");
}

#[test]
fn native_fujifilm_serial_id() {
    // Fujifilm emits `native:fujifilm:{serial_or_name}`; serials
    // are non-numeric so device_index is None.
    let parsed = ParsedDeviceId::parse("native:fujifilm:7CB12345").unwrap();
    let (vendor, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(vendor, "fujifilm");
    assert_eq!(dev, "7CB12345");
    assert_eq!(idx, None);
    // The body's lens, as a focuser, carries the same serial.
    assert_native_roundtrip("native:fujifilm_lens:7CB12345", "fujifilm_lens");
}

#[test]
fn native_gphoto2_5part() {
    // gPhoto2 ID: `native:gphoto2:{idx}:{port_hex}:{model}`.
    // Default branch collapses everything after the vendor into
    // `device_id` — `bridge/src/devices.rs` re-splits it for
    // its own dispatch.
    let raw = "native:gphoto2:0:7573623a3030312c303034:Canon EOS R6";
    let parsed = ParsedDeviceId::parse(raw).unwrap();
    assert_eq!(parsed.native_vendor(), Some("gphoto2"));
    let (_, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(dev, "0:7573623a3030312c303034:Canon EOS R6");
    assert_eq!(idx, None);
    assert_eq!(parsed.raw(), raw);
}

#[test]
fn native_skywatcher_4part_serial_mount() {
    // Serial-mount form: `native:skywatcher:{port}:{baud}`.
    // device_id collapses port + baud — call site already splits.
    let parsed = ParsedDeviceId::parse("native:skywatcher:COM3:9600").unwrap();
    let (vendor, dev, idx) = parsed.native_info().unwrap();
    assert_eq!(vendor, "skywatcher");
    assert_eq!(dev, "COM3:9600");
    assert_eq!(idx, None);
}

#[test]
fn native_skywatcher_udp_form() {
    // `vendor/skywatcher.rs:215` emits `native:skywatcher:{ip}:{port}`
    let parsed = ParsedDeviceId::parse("native:skywatcher:192.168.4.1:11880").unwrap();
    let (vendor, dev, _) = parsed.native_info().unwrap();
    assert_eq!(vendor, "skywatcher");
    assert_eq!(dev, "192.168.4.1:11880");
}

#[test]
fn native_ioptron_4part_serial_mount() {
    let parsed = ParsedDeviceId::parse("native:ioptron:COM4:9600").unwrap();
    let (vendor, dev, _) = parsed.native_info().unwrap();
    assert_eq!(vendor, "ioptron");
    assert_eq!(dev, "COM4:9600");
}

#[test]
fn native_lx200_family_serial_mounts() {
    // discovery.rs emits one of: lx200, meade, onstep, losmandy,
    // 10micron — each followed by `{port}:{baud}`.
    for vendor in &["lx200", "meade", "onstep", "losmandy", "10micron"] {
        let raw = format!("native:{}:COM3:9600", vendor);
        assert_native_roundtrip(&raw, vendor);
        let parsed = ParsedDeviceId::parse(&raw).unwrap();
        let (_, dev, _) = parsed.native_info().unwrap();
        assert_eq!(dev, "COM3:9600");
    }
}

#[test]
fn native_builtin_guider_3part() {
    // `bridge/src/builtin_guider.rs` exposes
    // `native:builtin_guider:multi_star`.
    assert_native_roundtrip("native:builtin_guider:multi_star", "builtin_guider");
}

#[test]
fn native_unknown_vendor_is_rejected() {
    // Unknown vendors must not silently fall through.
    let err = ParsedDeviceId::parse("native:notarealvendor:0").unwrap_err();
    let msg = format!("{}", err);
    assert!(
        msg.contains("notarealvendor") || msg.contains("Unknown native vendor"),
        "expected unknown-vendor error, got: {}",
        msg
    );
}

#[test]
fn native_empty_device_id_is_rejected() {
    // `native:zwo:` has a vendor but no payload.
    assert!(ParsedDeviceId::parse("native:zwo:").is_err());
}

#[test]
fn native_subtype_empty_payload_is_rejected() {
    // `native:zwo:eaf:` claims a subtype but no payload — must
    // fail rather than fabricate device_id="".
    assert!(ParsedDeviceId::parse("native:zwo:eaf:").is_err());
}

#[test]
fn native_supported_vendors_constant_is_exhaustive() {
    // Smoke-test that every token in the registry parses for at
    // least one minimal payload. Catches typos / dead entries in
    // the vendor catalog.
    for vendor in &skotiq_native::catalog::id_tokens() {
        // Touptek requires a brand segment; supply one.
        let raw = if vendor == "touptek" {
            "native:touptek:ogma:0".to_string()
        } else {
            format!("native:{}:0", vendor)
        };
        ParsedDeviceId::parse(&raw)
            .unwrap_or_else(|e| panic!("registered vendor `{}` failed to parse: {}", vendor, e));
    }
}

#[test]
fn test_cached_parse_returns_same_result() {
    // First call should be a cache miss
    let parsed1 = parse_device_id_cached("ascom:ASCOM.Telescope.Simulator").unwrap();

    // Second call should be a cache hit with identical result
    let parsed2 = parse_device_id_cached("ascom:ASCOM.Telescope.Simulator").unwrap();

    assert_eq!(parsed1.raw_id, parsed2.raw_id);
    assert_eq!(parsed1.driver_type, parsed2.driver_type);
}

#[test]
fn test_cache_handles_invalid_ids() {
    // Invalid IDs should not be cached (they return errors)
    let result = parse_device_id_cached("");
    assert!(result.is_err());

    let result = parse_device_id_cached("invalid:format");
    assert!(result.is_err());
}
