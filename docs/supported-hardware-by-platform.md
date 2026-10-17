# Supported Hardware By Platform

This page describes public-release hardware support by driver backend and
platform. It is intentionally conservative: a backend being available means
Skotiq can attempt discovery and connection on that platform. Individual
devices can still expose narrower capabilities after connection.

The same backend availability is surfaced in-app under
Settings > Connection > Platform Capabilities and through
`/api/info.platformCapabilities` in headless mode.

## Verified Hardware (4.1.0)

This table records devices that have actually been run against Skotiq, and at
what level — **separate from, and narrower than, the backend-availability tables
below.** A device appearing in a backend column below means Skotiq can
*attempt* it; a row here means it was *exercised*. Code presence never implies
support. Source: [`release-evidence/4.1.0.md`](release-evidence/4.1.0.md) (rig
test, 2026-06-17, shipped 4.1.0 Windows binary).

| Device | Backend | OS | Driver/SDK | Tested workflow | Release status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| ZWO ASI1600 (camera) | ASCOM COM | Windows 10/11 | Vendor ASCOM driver | Desktop GUI: full. Headless: connect, status, 16 MP capture, JPEG, cooling | Verified (desktop); headless capture verified, long-session stability **in hardening** | Driver degraded over a long headless session (B18); fix implemented, runtime-pending on rig |
| ZWO EAF (focuser) | ASCOM COM | Windows 10/11 | Vendor ASCOM driver | Connect, telemetry, single absolute moves | Verified | Rapid back-to-back moves wedged the driver headless (B6); single moves with settle are clean |
| ZWO EFW (filter wheel) | ASCOM COM | Windows 10/11 | Vendor ASCOM driver | Connect, 8 named slots read | Partial | Headless set-position is a no-op (B5); fix implemented, runtime-pending |
| PegasusAstro NYX-101 (mount) | ASCOM COM / native serial | Windows 10/11 | ASCOM + OnStep/LX200 | Desktop GUI connect works | **Not verified headless** | Headless connect fails `0x80020009` (B2); fix implemented, runtime-pending |
| PHD2 (guider) | PHD2 process | Windows 10/11 | PHD2 | Connect | Partial | Connect verified; a full guide+dither loop was not exercised in this evidence pass |
| ASTAP (plate solver) | Local solver | Windows 10/11 | ASTAP | Async solve + graceful no-solution | Verified | Invoked as an async job (~7.4 s) |

The desktop GUI path is the verified one; the headless gaps above are
headless-mode COM-session issues, not device or pipeline faults. Until the
headless fixes are runtime-confirmed on the rig, treat **unattended headless
acquisition** as experimental. Linux and macOS have no hardware rows yet.

## Driver Backend Availability

| Driver backend | Windows | Linux | macOS | Notes |
| --- | --- | --- | --- | --- |
| ASCOM COM | Available | Unsupported | Unsupported | Requires Windows COM and locally installed ASCOM Platform/device drivers. |
| ASCOM Alpaca | Available | Available | Available | Network API for ASCOM-compatible devices and bridges. Device capability gaps are reported by the Alpaca server. |
| INDI | Available | Available | Available | Requires a reachable INDI server. Feature depth depends on the INDI driver and device property support. |
| Native SDK | Capability-gated | Capability-gated | Capability-gated | Depends on user-installed vendor libraries and OS driver support. Official artifacts do not redistribute vendor SDK binaries. |
| Simulator | Capability-gated | Capability-gated | Capability-gated | Workflow-specific; use ASCOM, Alpaca, or INDI simulator drivers for hardware-like smoke tests unless an in-app simulator path is explicitly enabled. |

## Device Category Coverage

| Device category | ASCOM COM | Alpaca | INDI | Native SDK | Release expectation |
| --- | --- | --- | --- | --- | --- |
| Camera | Windows | All desktop platforms | INDI server platforms | Vendor/OS gated | Discovery and capture must report explicit errors when a device or SDK is unavailable. |
| Mount | Windows | All desktop platforms | INDI server platforms | Limited native protocols | Slew, sync, park, unpark, and tracking controls must be capability-gated per connected driver. |
| Focuser | Windows | All desktop platforms | INDI server platforms | Not a standalone public guarantee | Native focuser SDK work may exist internally, but release support should rely on ASCOM, Alpaca, or INDI unless verified. |
| Filter wheel | Windows | All desktop platforms | INDI server platforms | Not a standalone public guarantee | Native filter wheel SDK work may exist internally, but release support should rely on ASCOM, Alpaca, or INDI unless verified. |
| Rotator | Windows | All desktop platforms | INDI server platforms | Not currently a native guarantee | Controls must be disabled or fail explicitly if the driver lacks rotation support. |
| Guider | PHD2 integration and driver-dependent devices | PHD2 integration and driver-dependent devices | PHD2 integration and driver-dependent devices | Not currently a native guarantee | PHD2 is the primary release path for guiding workflows. |
| Dome | Windows | All desktop platforms | INDI server platforms | Not currently a native guarantee | Dome movement and slaving must be tested per driver before release sign-off. |
| Weather/safety | Windows ObservingConditions and safety drivers | All desktop platforms when provided by Alpaca | Driver-dependent and not fully parity-verified | Not currently a native guarantee | Weather safety must fail closed when unavailable or stale. |
| Switch/cover/calibrator | Windows where driver exposes device | All desktop platforms when provided by Alpaca | Driver-dependent and not fully parity-verified | Not currently a native guarantee | Power and cover controls are high-risk and must be explicitly audited per device. |

## Native SDK Notes

Native camera SDK support is gated by the libraries bundled for each release and
by the vendor's operating-system support. Do not treat a vendor name in the code
base as a public support guarantee until the release candidate has verified:

- the SDK library is present in the package for that OS and CPU architecture
- discovery succeeds with the intended hardware or vendor simulator
- connect, capture, download, abort, cooling, gain, offset, and cleanup paths
  behave correctly
- redistribution notices or agreements are in place where required

Known release-planning gaps from the hardware audit:

- Canon/Nikon DSLR native control is not a public-release guarantee.
- Native focuser and filter-wheel devices should not be advertised unless their
  standalone discovery and connection paths have been verified.
- ZWO native support on Apple Silicon depends on vendor SDK architecture
  availability and may require Rosetta or a non-native fallback.
- QHY native support should remain easy to disable or bypass because SDK
  discovery and stability can vary by installation.
- INDI weather and switch parity is not fully verified and may require Alpaca
  bridges for release-critical observatory safety.

## Linux Packaging And Permissions

Linux support must be treated as package- and host-specific until the external
Linux release build evidence is attached. A Linux artifact can only claim
hardware support when the release evidence records:

- required native shared libraries bundled with the package or listed as
  runtime dependencies
- USB/serial permission setup for the target host, including `udev rules`,
  `dialout`, `plugdev`, and `video` group membership where applicable
- INDI server package/source, driver names, and whether the server was local or
  remote during the smoke pass
- any vendor SDK packages, redistribution notes, and architecture constraints
  for ZWO, QHY, Player One, ToupTek, Moravian, Atik, and DSLR/gphoto2 paths
- the exact device, simulator, or loopback path used for discovery, connect,
  capture/control, and cleanup validation

Do not promote a Linux-native SDK or USB device path from capability-gated to
supported based only on code presence. The package must prove the relevant
library loads, permissions allow device access, and the runtime smoke exercised
the supported workflow from the shipped artifact.

The Skotiq systemd/Pi appliance installs
`99-skotiq-astro.rules` as a baseline permission layer for common astronomy
USB vendors and USB-serial adapters. Those rules intentionally grant `0660`
access to the `skotiq` group rather than upstream-style world-writable
device nodes. They do not replace vendor firmware packages, INDI driver
packages, or redistributable native SDK libraries.

Linux release bundles can include redistributable vendor SDK libraries by
setting `SKOTIQ_VENDOR_LIB_DIR` when running `scripts/docker_build_linux.sh`;
matching `.so`/`.so.*` files are copied into `bundle/lib`. Native SDK loaders
search the executable directory and `bundle/lib` before system library paths,
so the same artifact can run on a clean Raspberry Pi when the required
libraries are legally bundled. If a vendor SDK must be installed separately,
record the package/source and architecture in release evidence.

The official 5.0.0 GitHub artifacts do not use this custom packaging option and
contain no vendor SDK binaries.

## Release Verification Gate

Before a public release, run a hardware or simulator-backed smoke pass for every
backend and device category claimed in scope. Record unsupported items in the
release notes and make sure they match:

- this page
- `docs/production-readiness/feature-parity-matrix.md`
- in-app Platform Capabilities
- `/api/info.platformCapabilities`

If those four artifacts disagree, treat the release candidate as not ready.
