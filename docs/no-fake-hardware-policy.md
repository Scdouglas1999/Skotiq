# No Fake Hardware Policy

Skotiq controls real telescopes, mounts, cameras, and observatory
roofs, often unattended. A control system that quietly invents data, or quietly
substitutes a simulator for a missing device, is worse than one that stops:
it hides a fault behind plausible-looking numbers until the optics are pointed
at the Sun or the rig is left open under rain. So Skotiq treats fabricated
hardware behavior as a defect, not a convenience.

This page states that as four enforced rules. Each rule is paired with the
real code path it is held to. Where the code only partially enforces a rule
today, this page says so rather than overclaiming.

## 1. A missing native bridge fails loud

If the native bridge or a backend is not present, Skotiq surfaces a clear
error instead of degrading to fabricated data. The FFI boundary is explicitly
"never panic, never fake" — every fallible call returns a typed
`SkotiqError` rather than a placeholder value
(`native/skotiq_native/bridge/src/error.rs`, header comment "Safe: Never
panic — this is the FFI boundary"). On the Dart side the default backend for a
client that has not connected to a real engine is `DisconnectedBackend`, whose
every operation calls `_throwNotConnected()` and raises a
`ConnectionException` — it never returns mock results
(`packages/skotiq_core/lib/src/backend/disconnected_backend.dart`, class
doc: "the app never attempts to … ensuring … clear, user-friendly
exceptions"). There is no silent path from "bridge unavailable" to "looks
connected."

**How it's enforced:** `error.rs` typed-error boundary;
`disconnected_backend.dart` `_throwNotConnected()` / `ConnectionException`.

## 2. Simulators are explicit, never a silent fallback

Simulation is always an opt-in, named state — never something Skotiq slips
into because real hardware was missing. In production appliance builds the
sequencer refuses to enter simulation mode at all:
`sequencer_set_simulation_mode(true)` returns
`SkotiqError::NotSupported` whenever `!cfg!(debug_assertions)`
(`native/skotiq_native/bridge/src/sequencer_api.rs`, comment
"Production/release artifacts must not execute simulated hardware paths"). The
headless API translates that refusal into an explicit, actionable response
rather than an opaque failure — error code `simulation_mode_unavailable` with
the message that "production appliances run real hardware only"
(`apps/desktop/lib/headless_api/handlers/sequencer_handlers.dart`,
`handleSequencerSetSimulationMode`). The Platform Capabilities matrix likewise
marks the in-app simulator backend `capability-gated` and notes its
availability is "workflow-specific," not a universal fallback
(`packages/skotiq_core/lib/src/models/backend/platform_capabilities.dart`).

**How it's enforced:** `sequencer_api.rs`
`sequencer_set_simulation_mode` debug-assertions gate; `sequencer_handlers.dart`
`simulation_mode_unavailable`.

## 3. Unsupported hardware is disabled or fails with an explicit reason

A capability that a platform or driver does not provide is either gated off in
the UI or returns a stated reason. Driver-backend availability per OS is a
static matrix — for example ASCOM COM is Windows-only with the explicit
`unsupportedReason` "ASCOM COM requires Windows COM drivers and is not
available on Linux or macOS," and the native SDK backend is `capability-gated`
on installed drivers
(`packages/skotiq_core/lib/src/models/backend/platform_capabilities.dart`,
`PlatformCapabilityMatrix`). That matrix is served to remote clients at
`/api/info` under `platformCapabilities`
(`apps/desktop/lib/headless_api/handlers/system_handlers.dart`), so a tablet
can disable controls it knows the appliance cannot drive. At the device level,
capability checks answer "yes" only on explicit evidence:
`DeviceApiVersion::supports_action` returns true only when the action is
listed, and `supports_version` returns false when the version is unknown
(`native/skotiq_native/bridge/src/device.rs`).

This is the policy the code is held to, not a claim of perfection. A known bug
class exists where some headless ASCOM writes returned `ok` while no-oping;
that is being fixed and tracked. The intent the code is held to is: an
unsupported control is disabled or fails with a reason — never a silent no-op
that reports success.

**How it's enforced:** `platform_capabilities.dart`
`PlatformCapabilityMatrix` + `unsupportedReason`; `/api/info`
`platformCapabilities` in `system_handlers.dart`; `device.rs`
`supports_action` / `supports_version`.

## 4. Safety-critical unknowns fail closed

When the answer to "is it safe to keep imaging?" is unknown, Skotiq treats
it as unsafe and drives the rig to a safe state. The sequencer's
`WeatherUnsafe` trigger fires when EITHER the hardware safety monitor reports
unsafe OR the pushed weather verdict is `Some(true)`; an abstaining verdict
(`None`) or a SAFE verdict can only ever make the rig safer, never suppress a
hardware-unsafe reading (`native/skotiq_native/sequencer/src/triggers.rs`,
`WeatherUnsafe` arm). A pushed UNSAFE verdict is fail-closed: if the feed goes
silent the verdict is deliberately NOT auto-cleared, and the poll loop emits a
loud warning so an indefinite hold is never silent
(`triggers.rs`, `weather_verdict_last_update` doc). Unknown dome shutter state
is likewise treated as unsafe (`triggers.rs`: "Unknown shutter state is treated
unsafe (fail-closed)"). The executor then enforces the verdict by driving the
single safe-state sweep — park the mount, close the cover, then verify the dome
shutter actually reached Closed, recording an error (and paging the operator)
if it cannot be confirmed
(`native/skotiq_native/sequencer/src/device_ops.rs`,
`park_and_close_safe_state`). The same fail-closed default is selectable
operationally via `SafetyFailMode::FailClosed`
(`native/skotiq_native/bridge/src/sequencer_api.rs`).

**How it's enforced:** `triggers.rs` `WeatherUnsafe` OR-of-unsafe +
stale-verdict hold + unknown-shutter-unsafe; `device_ops.rs`
`park_and_close_safe_state`; `sequencer_api.rs` `SafetyFailMode::FailClosed`.

## Related documentation

This policy is also reflected in `docs/known-limitations.md` (whose acceptance
rules require that "unsupported controls are disabled or fail with an explicit
reason" and "safety-critical workflows fail closed") and in
`docs/supported-hardware-by-platform.md`, which publishes the conservative
per-platform backend support matrix the capability gating in Rule 3 is built
on.
