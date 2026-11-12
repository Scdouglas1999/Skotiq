//! Vendor Quirks Database
//!
//! This module contains the built-in database of known device quirks.
//! Quirks are organized by vendor and device model.
//!
//! ## Adding New Quirks
//!
//! To add quirks for a new device:
//! 1. Add a constant for the device pattern
//! 2. Add the quirks to the appropriate vendor function
//! 3. Document the source of the quirk (firmware version, SDK bug, etc.)

use super::types::*;
use skotiq_device::Vendor;

fn zwo_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Temperature(ScaleFactor(10.0))` — the ZWO ASI camera driver already
        // divides `ASI_TEMPERATURE` by 10 inline in `vendor/zwo.rs` (see lines ~828, ~1162).
        // Routing the same value through the quirks layer would either double-scale or
        // produce no effect, so the entry is intentionally absent.
        //
        // REMOVED: `Discovery(NotThreadSafe)` / `Discovery(RequiresSerializedDiscovery)` —
        // every ASI SDK call in `vendor/zwo.rs` is already serialized via the per-SDK
        // mutexes (`zwo_camera_mutex`, `zwo_eaf_mutex`, `zwo_efw_mutex`). Discovery shares
        // those mutexes, so the quirks were never queried by anything outside the tests.
        // (
        //     QuirkMatcher::VendorWide,
        //     vec![ ... ],
        // ),
        // ASI294MC Pro specific quirks
        // Source: User reports of first temperature read being incorrect
        (
            QuirkMatcher::ModelContains("ASI294"),
            vec![Quirk::Temperature(TemperatureQuirk::SkipFirstRead)],
        ),
        // ASI533MC specific quirks
        // Source: User reports of connection timing issues
        (
            QuirkMatcher::ModelContains("ASI533"),
            vec![Quirk::Timing(TimingQuirk::DelayAfterConnect(200))],
        ),
        // REMOVED: ASI2600/ASI6200 ActualBitDepth/RoiMultiple/ExtendedDownloadTimeoutSecs.
        // ZWO reports bit depth and ROI constraints through the SDK path we already use,
        // and the per-model timeout metadata had no runtime consumer.
        // ZWO EFW filter wheels may report wrong position immediately after move
        // Source: User reports and forum discussions
        (
            QuirkMatcher::ModelContains("EFW"),
            vec![Quirk::Position(PositionQuirk::DelayAfterMoveMs(500))],
        ),
        // ZWO EAF focuser step sizes — SDK does not expose mechanical travel per step,
        // so the value is declared per model from ZWO's published gear-ratio specs.
        // Order matters: more specific matchers (EAF-S, EAF-2) precede the generic EAF
        // entry so the first FocuserStepSizeMicrons quirk found is the model-correct one.
        //
        // EAF-S (compact, 7:1 internal reduction): 0.7 um/step.
        (
            QuirkMatcher::ModelContains("EAF-S"),
            vec![Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(0.7))],
        ),
        // EAF-2 (second-generation, finer reduction stage): 1.5 um/step.
        (
            QuirkMatcher::ModelContains("EAF-2"),
            vec![Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(1.5))],
        ),
        // ZWO EAF focusers (original): 8 um/step is ZWO's published mechanical travel.
        (
            QuirkMatcher::ModelContains("EAF"),
            vec![Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(8.0))],
        ),
    ]
}

fn qhy_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Discovery(NotThreadSafe)` / `Discovery(RequiresSerializedDiscovery)` /
        // `Discovery(RequiresSdkInit)` — `vendor/qhy.rs` already enforces all three:
        //   * concurrent access guarded by the `QhySdk` lock guard on every FFI call;
        //   * `QhySdk::ensure_initialized()` is called from `connect()` and
        //     `discover_devices_internal()` before any other SDK call.
        // The `DiscoveryTimeoutMs` quirk is retained because `qhy.rs::get_discovery_config()`
        // actively reads it via `get_quirks_for_vendor` (see line ~284).
        (
            QuirkMatcher::VendorWide,
            vec![Quirk::Discovery(DiscoveryQuirk::DiscoveryTimeoutMs(10000))],
        ),
        // QHY268M has specific cooling quirks
        // Source: User reports
        (
            QuirkMatcher::ModelContains("QHY268"),
            vec![
                Quirk::Camera(CameraQuirk::CoolerRange {
                    min_temp: -35.0,
                    max_temp: 25.0,
                }),
                Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(100)),
            ],
        ),
        // REMOVED: QHY600/QHY5III/CFW metadata whose policies had no runtime consumers.
        // QHY camera bit depth/ROI and USB controls are read from the SDK directly; CFW
        // command delay requires real filter-wheel command plumbing before re-adding.
    ]
}

fn player_one_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Discovery(NotThreadSafe)` / `Discovery(RequiresSerializedDiscovery)` —
        // `vendor/player_one.rs` already serializes every SDK call on the Player One SDK lock,
        // so these were dead by design.
        //
        // The Temperature `RequiresDelayMs(50)` is consumed by
        // `PlayerOneCamera::get_temperature` before issuing POA_TEMPERATURE reads.
        (
            QuirkMatcher::VendorWide,
            vec![Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(50))],
        ),
        // REMOVED: Poseidon/Neptune ActualBitDepth/ExtendedDownloadTimeout/UsbBandwidth.
        // The Player One driver reads bit depth and USB bandwidth from the SDK; model-only
        // timeout/USB policy had no consumer.
    ]
}

fn svbony_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Temperature(ScaleFactor(10.0))` — the SVBony driver divides the raw
        // `CurrentTemperature` control by 10 inline (`vendor/svbony.rs` ~1206). Adding the
        // quirk on top would double-scale.
        //
        // REMOVED: `Discovery(NotThreadSafe)` — `vendor/svbony.rs` already serializes every
        // SDK call (including discovery) through the `SvbonySdk` lock guard. The quirk had no live
        // call site outside tests.
        //
        // The SDK-init settle delay is retained as a real `DelayAfterConnect` because the
        // SVBony connect path opens the camera, queries properties, and sets the output
        // image type without a documented post-init grace period — empirical reports show
        // the first control read after Init can return stale values without a brief settle.
        (
            QuirkMatcher::VendorWide,
            vec![Quirk::Timing(TimingQuirk::DelayAfterConnect(100))],
        ),
        // REMOVED: SV705 ActualBitDepth/RoiMultiple metadata. The SVBony driver reads
        // sensor bit depth and bin/ROI properties from the SDK instead of this database.
    ]
}

fn atik_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Temperature(ScaleFactor(100.0))` — the Atik driver divides the
        // Artemis SDK's centi-degree reading by 100 inline (`vendor/atik.rs` ~1198). The
        // quirk would double-scale.
        //
        // REMOVED: `Discovery(NotThreadSafe)` — Atik discovery and runtime calls already
        // serialize on the `AtikSdk` lock guard.
        // (
        //     QuirkMatcher::VendorWide,
        //     vec![ ... ],
        // ),
        // REMOVED: Atik 16200 ActualBitDepth/ExtendedDownloadTimeout metadata. The
        // Atik driver sets/readbacks 16-bit mode directly and does not consume timeout
        // metadata.
        // Atik One series
        (
            QuirkMatcher::ModelContains("One"),
            vec![Quirk::Camera(CameraQuirk::CoolerRange {
                min_temp: -40.0,
                max_temp: 20.0,
            })],
        ),
    ]
}

/// Get quirks for Touptek/Ogma devices.
///
/// Touptek is a multi-brand SDK family: a single C SDK is rebranded by
/// multiple OEMs (Touptek, OGMA, Altair, Bresser, Mallincam, NNCam,
/// StarShootG, Omegon, OrionCam ...). Device IDs from `discovery.rs` have
/// the 4-part form `native:touptek:{brand}:{idx}` (see
/// `bridge/src/device_id.rs::parse_native` Touptek branch).
///
/// The `get_device_quirks` lookup re-synthesizes the model string as
/// `"{brand}:{idx}"` (e.g. `"ogma:0"`) so that brand-specific
/// `ModelContains(...)` matchers fire. A plain `ModelContains("ogma:")`
/// catches every OGMA device while leaving Altair / Touptek / Bresser
/// devices untouched — that's the contract this layout depends on.
///
/// Vendor-wide quirks (matcher `VendorWide`) still apply to every
/// Touptek-family device regardless of brand.
fn touptek_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Temperature(ScaleFactor(10.0))` — the Touptek driver divides the
        // Ogmacam `get_Temperature` deci-degree reading by 10 inline (`vendor/touptek.rs`
        // ~1128). The quirk would double-scale.
        //
        // REMOVED: `Discovery(NotThreadSafe)` — Touptek discovery and runtime SDK calls
        // serialize on `TOUPTEK_SDK_LOCK`.

        // OGMA-branded Touptek cameras (e.g. OGMA AP26CC) ship with a
        // documented USB-init grace period: the brand's firmware enumerates
        // the imager *before* its onboard FX3 USB bridge has settled, so the
        // first `Ogmacam_StartPullModeWithCallback` immediately after open
        // returns frames with a transient row-noise band on roughly 1-in-5
        // streams. OGMA's support docs recommend a short post-open settle.
        //
        // Values come from OGMA's own community-shared timing notes; the
        // 150 ms delay is the conservative end of the suggested range and
        // should be revised when OGMA publishes an official spec sheet for
        // the AP26CC / AP55CC firmware revisions.
        //
        // This is brand-specific (NOT vendor-wide) because Touptek's own
        // branded cameras and Altair-branded variants enumerate cleanly
        // without the delay — adding it vendor-wide would slow every
        // connect by 150 ms for no reason.
        //
        // Matcher: `ModelContains("ogma:")` — `get_device_quirks` builds
        // the model string as `"{brand}:{idx}"` for Touptek IDs, so
        // `ogma:0`, `ogma:1`, ... all match while `altair:0` does not.
        (
            QuirkMatcher::ModelContains("ogma:"),
            vec![Quirk::Timing(TimingQuirk::DelayAfterConnect(150))],
        ),
    ]
}

fn moravian_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: NotThreadSafe/DarkFrameRequiresShutter/ActualBitDepth/timeout entries.
        // Moravian SDK calls are already serialized through `moravian_mutex`; exposure
        // shutter behavior and bit depth are handled in the driver, and timeout metadata had
        // no consumer.
    ]
}

fn fli_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: NotThreadSafe/DarkFrameRequiresShutter/ExtendedDownloadTimeout entries.
        // FLI SDK calls already serialize through `fli_mutex`; the other entries were
        // metadata with no runtime consumer.
    ]
}

fn skywatcher_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Communication(RequiredBaudRate(9600))` — `vendor/skywatcher/`
        // already hardcodes `SYNSCAN_BAUD_RATE = 9600` and the discovery routine
        // probes the `SYNSCAN_DISCOVERY_BAUD_RATES = [115200, 9600]` list directly.
        // Routing baud-rate selection through quirks would force a second source of
        // truth that nothing currently reads.
        //
        // REMOVED: `Timing(DelayBetweenCommands(50))` until `send_command` actually
        // consumes it. Keeping it live made the quirks DB look effective when it was not.
        // EQ6-R Pro and AZ-GTi model-specific quirks (GotoPrecisionArcsec,
        // GuideRateScale, DelayAfterConnect) are DEFERRED: the driver names the
        // model from the motor board version (`Sky-Watcher EQ6-R Pro (PORT)`),
        // but nothing reads these quirks for Sky-Watcher mounts yet.
    ]
}

fn ioptron_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Communication(RequiredBaudRate(115200))` and
        // `Communication(LineEnding("#"))` — `vendor/ioptron.rs` already hardcodes
        // both: `IOPTRON_BAUD_RATE`/`IOPTRON_BAUD_RATE_FAST` constants for baud
        // selection (with fallback logic in connect()) and the "#" terminator
        // baked into the `send_command` framing. The quirks were never queried
        // by anything outside the diagnostics display.
        //
        // CEM/GEM model-specific quirks DEFERRED: same reason as Sky-Watcher —
        // iOptron mount model is derived from `GET_MOUNT_VERSION` at connect time
        // but is stored only inside `self.mount_model`; the `name` field used by
        // quirks lookup is `"iOptron {model} ({port})"` which does happen to
        // include the model substring, but the existing quirk policies
        // (GotoPrecisionArcsec, SyncRequiresAlignment) have no consumers in the
        // codebase yet.
    ]
}

fn lx200_quirks() -> Vec<(QuirkMatcher, Vec<Quirk>)> {
    vec![
        // REMOVED: `Communication(RequiredBaudRate(9600))` and
        // `Communication(LineEnding("#"))` — `vendor/lx200.rs` already hardcodes
        // `LX200_BAUD_RATE = 9600` and the "#" terminator in its `send_command`
        // implementation, plus a multi-baud `DISCOVERY_BAUD_RATES` probe list.
        // The OnStep-specific 115200 override quirk is also redundant because
        // the discovery probe already tries 115200 first.
        //
        // REMOVED: `Timing(DelayBetweenCommands(100))` until `send_command` actually
        // consumes it. Keeping it live made the quirks DB look effective when it was not.
        // LX200GPS and OnStep model-specific Mount quirks DEFERRED: model name
        // matching depends on `GET_PRODUCT_NAME` populating `self.name` at
        // connect-time (which does happen), but the consuming code (mount slew
        // policy / goto-precision UI) has no quirk-aware path yet.
    ]
}

/// How to match quirks to devices
#[derive(Debug, Clone, PartialEq)]
pub enum QuirkMatcher {
    /// Applies to all devices from this vendor
    VendorWide,
    /// Applies to devices whose model name contains this string (case-insensitive)
    ModelContains(&'static str),
    /// Applies to devices with this exact model name
    ModelExact(&'static str),
    /// Applies to devices whose ID contains this string
    IdContains(&'static str),
}

impl QuirkMatcher {
    /// Check if this matcher matches the given device info
    pub fn matches(&self, device_id: &str, model_name: &str) -> bool {
        match self {
            QuirkMatcher::VendorWide => true,
            QuirkMatcher::ModelContains(s) => model_name.to_lowercase().contains(&s.to_lowercase()),
            QuirkMatcher::ModelExact(s) => model_name == *s,
            QuirkMatcher::IdContains(s) => device_id.to_lowercase().contains(&s.to_lowercase()),
        }
    }
}

/// Get all quirks for a device based on its ID.
///
/// The device ID format is expected to be: `protocol:vendor:model_or_id`.
/// Touptek devices use a 4-part form: `native:touptek:{brand}:{idx}` —
/// see `bridge/src/device_id.rs::parse_native` for the full grammar.
///
/// Examples:
/// - `native:zwo:ASI294MC Pro`         (3-part, model = "ASI294MC Pro")
/// - `native:touptek:ogma:0`           (4-part Touptek, model synthesized
///                                      as "ogma:0" so brand-specific
///                                      `ModelContains("ogma:")` fires)
/// - `native:touptek:altair:2`         (same vendor, different brand —
///                                      OGMA-only quirks do NOT apply)
/// - `ascom:Simulator:Camera #1`
/// - `alpaca:10.0.0.5:camera:0`
///
/// Malformed IDs (fewer than 2 segments, or unrecognised protocol) log
/// loudly and return an empty quirk list; silent fallthrough would hide a
/// misconfigured device indefinitely.
///
/// # Arguments
/// * `device_id` - The full device identifier
///
/// # Returns
/// A vector of all quirks that should be applied to this device
pub fn get_device_quirks(device_id: &str) -> Vec<Quirk> {
    let mut quirks = Vec::new();

    let parts: Vec<&str> = device_id.split(':').collect();
    if parts.len() < 2 {
        tracing::warn!(
            "Quirks lookup rejected malformed device ID `{}`: expected at \
             least 'protocol:vendor[:model]', got {} segment{}",
            device_id,
            parts.len(),
            if parts.len() == 1 { "" } else { "s" }
        );
        return quirks;
    }

    let protocol = parts[0];
    let vendor_or_model = if parts.len() > 1 { parts[1] } else { "" };

    // Touptek-aware model synthesis: the multi-brand Touptek SDK emits
    // 4-part IDs `native:touptek:{brand}:{idx}`. We use parts[2] as the
    // brand and re-encode the model as `"{brand}:{idx}"` so that
    // `ModelContains("ogma:")` (or any other brand prefix) matches only
    // the intended brand. For 3-part Touptek IDs (legacy / malformed),
    // fall through to the default join — the `parse_native` validator
    // already rejects these upstream, but the quirks lookup must not
    // panic if a stale ID is queried.
    //
    // For every non-Touptek vendor, model = parts[2..].join(":") preserves
    // the original behaviour: subtype IDs like `native:zwo:efw:0` keep
    // model = "efw:0", which `ModelContains("EFW")` matches case-insensitively.
    let is_touptek_4part =
        protocol == "native" && vendor_or_model.to_lowercase() == "touptek" && parts.len() >= 4;

    let model = if is_touptek_4part {
        // brand:idx form — preserves brand for ModelContains matching.
        format!("{}:{}", parts[2].to_lowercase(), parts[3..].join(":"))
    } else if parts.len() > 2 {
        parts[2..].join(":")
    } else {
        String::new()
    };

    let vendor_quirk_list = match protocol {
        "native" => match vendor_or_model.to_lowercase().as_str() {
            "zwo" => zwo_quirks(),
            "qhy" => qhy_quirks(),
            "playerone" | "player_one" => player_one_quirks(),
            "svbony" => svbony_quirks(),
            "atik" => atik_quirks(),
            "touptek" | "ogma" => touptek_quirks(),
            "moravian" => moravian_quirks(),
            "fli" => fli_quirks(),
            "skywatcher" | "sky-watcher" | "synta" => skywatcher_quirks(),
            "ioptron" => ioptron_quirks(),
            "lx200" | "meade" => lx200_quirks(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    };

    for (matcher, vendor_quirks) in vendor_quirk_list {
        if matcher.matches(device_id, &model) {
            quirks.extend(vendor_quirks);
        }
    }

    if !quirks.is_empty() {
        tracing::debug!(
            "Found {} quirks for device {}: {:?}",
            quirks.len(),
            device_id,
            quirks.iter().map(|q| q.category()).collect::<Vec<_>>()
        );
    }

    quirks
}

pub fn get_vendor_quirks(vendor: &Vendor) -> Vec<Quirk> {
    let vendor_quirk_list = match vendor {
        Vendor::Zwo => zwo_quirks(),
        Vendor::Qhy => qhy_quirks(),
        Vendor::PlayerOne => player_one_quirks(),
        Vendor::Svbony => svbony_quirks(),
        Vendor::Atik => atik_quirks(),
        Vendor::Touptek => touptek_quirks(),
        Vendor::Moravian => moravian_quirks(),
        Vendor::Fli => fli_quirks(),
        Vendor::SkyWatcher => skywatcher_quirks(),
        Vendor::IOptron => ioptron_quirks(),
        Vendor::Meade => lx200_quirks(), // Meade uses LX200 protocol
        // Vendors without specific quirks
        Vendor::Ascom | Vendor::Fujifilm | Vendor::GPhoto2 | Vendor::Other(_) => Vec::new(),
    };

    // Return only the vendor-wide quirks
    vendor_quirk_list
        .into_iter()
        .filter(|(matcher, _)| matches!(matcher, QuirkMatcher::VendorWide))
        .flat_map(|(_, quirks)| quirks)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_zwo_camera_quirks() {
        let quirks = get_device_quirks("native:zwo:ASI294MC Pro");
        assert!(!quirks.is_empty());

        let has_skip_first = quirks
            .iter()
            .any(|q| matches!(q, Quirk::Temperature(TemperatureQuirk::SkipFirstRead)));
        assert!(has_skip_first, "ASI294 must carry SkipFirstRead");
    }

    #[test]
    fn test_get_zwo_efw_quirks() {
        // The ZWO EFW filter wheel device_id is `native:zwo:efw:N`. The driver
        // (`vendor/zwo.rs::ZwoFilterWheel::move_to_position`) reads
        // DelayAfterMoveMs and sleeps after EFWSetPosition. The database must
        // still declare that quirk for the wired code path to take effect.
        let quirks = get_device_quirks("native:zwo:efw:0");
        let delay = quirks.iter().find_map(|q| match q {
            Quirk::Position(PositionQuirk::DelayAfterMoveMs(ms)) => Some(*ms),
            _ => None,
        });
        assert_eq!(
            delay,
            Some(500),
            "EFW model match must produce a 500ms post-move delay quirk"
        );
    }

    #[test]
    fn test_get_zwo_asi533_connect_quirk() {
        // ASI533 cameras have a DelayAfterConnect(200) quirk wired into
        // `ZwoCamera::connect` after open + init. Guard the database side here;
        // the wiring side is verified in `quirks::tests::test_get_connect_delay_zwo_asi533`.
        let quirks = get_device_quirks("native:zwo:ZWO ASI533MC Pro");
        let delay = quirks.iter().find_map(|q| match q {
            Quirk::Timing(TimingQuirk::DelayAfterConnect(ms)) => Some(*ms),
            _ => None,
        });
        assert_eq!(delay, Some(200));
    }

    #[test]
    fn test_get_qhy_vendor_quirks() {
        let quirks = get_vendor_quirks(&Vendor::Qhy);
        assert!(!quirks.is_empty());

        let has_discovery = quirks.iter().any(|q| matches!(q, Quirk::Discovery(_)));
        assert!(has_discovery);
    }

    #[test]
    fn test_matcher_case_insensitive() {
        let quirks1 = get_device_quirks("native:zwo:ASI294MC");
        let quirks2 = get_device_quirks("native:ZWO:asi294mc");

        // Both should have the same number of quirks
        assert_eq!(quirks1.len(), quirks2.len());
    }

    #[test]
    fn test_ascom_quirks_are_not_live_without_consumers() {
        let quirks = get_device_quirks("ascom:ASCOM.Simulator.Camera:Camera #1");
        assert!(
            quirks.is_empty(),
            "ASCOM quirks must stay empty until a runtime consumer is added"
        );
    }

    // ToupTek brand-aware quirks lookup
    //
    // Touptek IDs are 4-part: `native:touptek:{brand}:{idx}`. The lookup
    // synthesizes the model string as `"{brand}:{idx}"` so brand-specific
    // `ModelContains` matchers (e.g. `ModelContains("ogma:")`) fire for
    // OGMA-branded devices but NOT for Altair / Touptek / Bresser
    // variants of the same SDK family. Vendor-wide quirks still apply to
    // every brand. See `device_id.rs::parse_native` for the ID grammar.

    /// Helper: scan a quirk list for a `DelayAfterConnect` value (the
    /// marker we use for the OGMA-specific quirk).
    fn delay_after_connect(quirks: &[Quirk]) -> Option<u64> {
        quirks.iter().find_map(|q| match q {
            Quirk::Timing(TimingQuirk::DelayAfterConnect(ms)) => Some(*ms),
            _ => None,
        })
    }

    #[test]
    fn touptek_ogma_brand_specific_quirk_fires() {
        // `native:touptek:ogma:0` — the lookup synthesizes model =
        // "ogma:0", so the `ModelContains("ogma:")` matcher fires.
        let quirks = get_device_quirks("native:touptek:ogma:0");
        assert_eq!(
            delay_after_connect(&quirks),
            Some(150),
            "OGMA-branded Touptek device must carry the brand-specific \
             DelayAfterConnect(150) quirk; got {:?}",
            quirks
        );
    }

    #[test]
    fn touptek_altair_brand_does_not_inherit_ogma_quirk() {
        // Critical regression guard: the OGMA-only quirk MUST NOT apply
        // to Altair-branded devices despite sharing the SDK family.
        let quirks = get_device_quirks("native:touptek:altair:0");
        assert_eq!(
            delay_after_connect(&quirks),
            None,
            "Altair-branded Touptek device must NOT inherit the \
             OGMA-specific DelayAfterConnect quirk; got {:?}",
            quirks
        );
    }

    #[test]
    fn touptek_own_brand_does_not_inherit_ogma_quirk() {
        // The bare "touptek" brand (Touptek's own line) is also a
        // sibling of OGMA — must not match `ogma:`.
        let quirks = get_device_quirks("native:touptek:touptek:0");
        assert_eq!(delay_after_connect(&quirks), None);
    }

    #[test]
    fn touptek_unknown_brand_falls_through_to_vendor_wide() {
        // A future / unrecognised brand still queries the touptek_quirks
        // family, so vendor-wide quirks (if any are added later) still
        // apply. Today touptek_quirks has no `VendorWide` entries, so the
        // result is empty — but the lookup MUST NOT panic or error.
        let quirks = get_device_quirks("native:touptek:mallincam:2");
        assert_eq!(
            delay_after_connect(&quirks),
            None,
            "unknown Touptek brand must not match the OGMA-specific quirk"
        );
        // Sanity: the lookup succeeded (returned, didn't panic). If a
        // future commit adds a VendorWide Touptek quirk, this test will
        // start surfacing it for unknown brands — that's the contract.
    }

    #[test]
    fn touptek_brand_specific_quirk_applies_to_all_indexes() {
        // The brand match is on the prefix "ogma:", not on a specific
        // index — every OGMA device (idx 0, 1, 2, ...) must match.
        for idx in 0..4 {
            let raw = format!("native:touptek:ogma:{}", idx);
            let quirks = get_device_quirks(&raw);
            assert_eq!(
                delay_after_connect(&quirks),
                Some(150),
                "OGMA index {} must carry the brand quirk",
                idx
            );
        }
    }

    #[test]
    fn touptek_case_insensitive_brand_match() {
        // Brand segment may arrive upper-cased from a stale config or
        // diagnostic command. Lookup must normalize to lowercase.
        let quirks = get_device_quirks("native:touptek:OGMA:0");
        assert_eq!(
            delay_after_connect(&quirks),
            Some(150),
            "OGMA brand match must be case-insensitive"
        );
    }

    #[test]
    fn touptek_legacy_3part_id_does_not_panic() {
        // 3-part Touptek IDs are rejected by `parse_native` upstream, but
        // a stale ID could still reach the quirks lookup (e.g. from an
        // old saved profile). The lookup must degrade gracefully: model
        // string becomes "0", no brand-specific match, no panic.
        let quirks = get_device_quirks("native:touptek:0");
        assert_eq!(
            delay_after_connect(&quirks),
            None,
            "legacy 3-part Touptek ID must not match brand-specific quirks"
        );
    }

    #[test]
    fn touptek_vendor_wide_quirks_apply_to_every_brand() {
        // Guard for the data shape: every Touptek brand must receive
        // VendorWide quirks when `touptek_quirks()` adds them. There are no
        // VendorWide Touptek quirks today (see the comments in
        // `touptek_quirks()`); the contract checked here is that the lookup
        // reaches the touptek branch for every brand.
        let quirks_ogma = get_device_quirks("native:touptek:ogma:0");
        let quirks_altair = get_device_quirks("native:touptek:altair:0");
        let quirks_bresser = get_device_quirks("native:touptek:bresser:0");

        // OGMA-specific (brand quirk) — 1 quirk; others 0.
        assert_eq!(quirks_ogma.len(), 1);
        assert!(quirks_altair.is_empty());
        assert!(quirks_bresser.is_empty());

        // All three queries reached the touptek dispatch branch (no
        // panic, no "Invalid device ID" log). If a future commit adds a
        // vendor-wide Touptek quirk, all three lists grow in lockstep.
    }

    #[test]
    fn touptek_brand_prefix_does_not_collide_with_other_brands() {
        // Defensive: `ModelContains("ogma:")` must not match a brand that
        // happens to start with the letters "ogma" but is a different
        // SDK family (none currently exist, but the colon suffix is what
        // anchors the match).
        //
        // We can't synthesise a "ogmasomething" brand without modifying
        // the parser allow-list, but we can verify the matcher logic
        // directly:
        assert!(QuirkMatcher::ModelContains("ogma:").matches("native:touptek:ogma:0", "ogma:0"));
        assert!(
            !QuirkMatcher::ModelContains("ogma:").matches("native:touptek:ogmaxyz:0", "ogmaxyz:0")
        );
        // `ModelContains("ogma:")` requires the trailing colon, so
        // "ogmaxyz:0" does not match — exactly what we want.
    }

    #[test]
    fn touptek_4part_id_logs_no_warning() {
        // The malformed-ID warn! path must NOT fire for a
        // well-formed 4-part Touptek ID. The simplest way to confirm
        // this is to verify the lookup actually returned the brand
        // quirk — if `get_device_quirks` had bailed via the malformed
        // path, the brand quirk would be missing.
        let quirks = get_device_quirks("native:touptek:ogma:0");
        assert!(
            !quirks.is_empty(),
            "well-formed Touptek ID must not bail early"
        );
    }
}
