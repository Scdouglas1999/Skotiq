# iOS publish checklist — Skotiq Mobile

A tick-box checklist for taking `apps/mobile` from a repo checkout to an
App Store release. The deep how-to lives in
[`docs/ios-release-setup.md`](../ios-release-setup.md) (referenced per item
as "runbook §N") — this file is the ordered list you actually work through
on release day, plus the App-Review-specific material that doc does not
cover.

**Identity (already wired in the repo):**

| Item | Value | Where it lives |
|---|---|---|
| Bundle ID | `com.skotiq.mobile` | `apps/mobile/ios/Runner.xcodeproj/project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER`) |
| App Group | `group.com.skotiq.app` | both entitlements files |
| Debug/Profile entitlements | `aps-environment=development` | `apps/mobile/ios/Runner/Runner.entitlements` |
| Release entitlements | `aps-environment=production` | `apps/mobile/ios/Runner/RunnerRelease.entitlements` |
| mDNS service browsed | `_skotiq._tcp` | `Info.plist` `NSBonjourServices` |

## Phase 1 — Apple Developer account (one-time)

- [ ] Paid Apple Developer Program membership active ($99/yr). A free team
      cannot ship App Groups, Push, or Critical Alerts — all used here
      (runbook §0).
- [ ] App ID registered for `com.skotiq.mobile` with
      capabilities: **Push Notifications**, **App Groups**.
- [ ] App Group `group.com.skotiq.app` created in the portal and
      attached to the App ID and every extension App ID (runbook §4d).
- [ ] **Critical Alerts entitlement requested from Apple** — this is a
      manual grant via the request form, often takes days/weeks; start it
      FIRST (runbook §5, `apps/mobile/ios/CRITICAL_ALERTS_SETUP.md`).
      Until granted, iOS silently downgrades the safety alerts
      (weather-unsafe, guiding-lost, mount-disconnect) to normal
      interruption level — the build still works, so this is easy to miss.
- [ ] APNs **token key (.p8)** minted and stored in the secrets vault —
      this is the *server-side* half; see
      [`cellular-push-setup.md`](cellular-push-setup.md) and runbook §3.

## Phase 2 — Mac build environment

- [ ] Xcode 15+, CocoaPods, Flutter 3.44+ (runbook §0 bootstrap commands).
- [ ] Open `apps/mobile/ios/Runner.xcworkspace` (never the bare
      `.xcodeproj`).
- [ ] Signing team selected on Runner + all extension targets (runbook §1).
- [ ] Extension targets created in Xcode if this Mac hasn't built them
      before: Live Activity widget, watch complication, App Intents
      (runbook §4a–4c — these are Xcode-GUI-only steps; the Swift sources
      are in the repo under `apps/mobile/ios/Skotiq*`).

## Phase 3 — Signing and entitlements sanity (the silent killers)

- [ ] `CODE_SIGN_ENTITLEMENTS` per configuration: Debug/Profile →
      `Runner/Runner.entitlements`, **Release →
      `Runner/RunnerRelease.entitlements`**. iOS does NOT auto-rewrite
      `development` → `production`; shipping the dev entitlements file in
      a Release archive yields sandbox-only APNs tokens that production
      APNs rejects with `BadDeviceToken`, silently killing every cellular
      safety push (runbook §6, and the long comments inside both
      entitlements files).
- [ ] Verify the archive's embedded entitlements before upload:
      `codesign -d --entitlements - <archived .app>` must show
      `aps-environment = production` and the critical-alerts key.
- [ ] Provisioning profiles include Push + App Group + (once granted)
      Critical Alerts (runbook §6).

## Phase 4 — Build + on-device verification

- [ ] `flutter build ipa --release` from `apps/mobile` (runbook §7).
- [ ] On a real device against a real (or LAN dev) server, verify:
  - [ ] discovery finds the server (mDNS `_skotiq._tcp` + UDP beacon),
  - [ ] the **Local Network permission prompt** appears on first discovery
        and the app behaves sanely if denied (manual IP entry path),
  - [ ] pairing completes; TLS fingerprint pinning accepted,
  - [ ] APNs registration: server log shows
        `POST /api/push/register-token` with `platform=apns`
        (handler: `apps/desktop/lib/headless_api/routes/push_routes.dart`),
  - [ ] a test critical alert breaks through a Focus mode (only after the
        Apple grant + user opt-in),
  - [ ] Live Activity appears during a sequence; watch complication
        updates.

## Phase 5 — TestFlight

- [ ] Upload via Xcode Organizer or `xcrun altool`/Transporter
      (runbook §8).
- [ ] Export-compliance question: the app uses only standard TLS/ATS
      encryption → "standard encryption, exempt" (set
      `ITSAppUsesNonExemptEncryption=false` in the App Store Connect
      record or Info.plist to skip the per-build question).
- [ ] Internal testing round: at minimum one full simulated overnight run
      with the phone on cellular (Wi-Fi off) to prove APNs production
      delivery end-to-end.
- [ ] External TestFlight (beta review): provide the same review notes as
      Phase 6 — external TestFlight builds go through a light review that
      can trip on the local-network usage just like the full review.

## Phase 6 — App Store review submission

App-Review materials specific to this app — paste-ready justifications:

- [ ] **Review notes — local network + Bonjour.** Reviewers cannot reach
      a telescope server, so explain and provide a path:

      > Skotiq Mobile is a companion/remote-control app for the
      > Skotiq astrophotography server, which runs on the user's own
      > computer or Raspberry Pi on the same LAN. Local Network access and
      > Bonjour (`_skotiq._tcp`) are used solely to discover and
      > connect to that server; no third-party devices are scanned and no
      > data leaves the local network except optional push notifications
      > the user's own server sends via APNs. The app is fully unusable
      > without a server, by design.

      Strongly recommended: include a **demo video** showing
      discovery → pairing → live sequence dashboard, since reviewers won't
      have hardware. If a public demo/simulator server mode exists by
      release time, give its address in the notes instead.
- [ ] **Camera permission justification** (`NSCameraUsageDescription` is
      already in `Info.plist`): camera is used *only* to scan the pairing
      QR code shown by the desktop app. State exactly that in the review
      notes; do not say "AR" or anything broader.
- [ ] Remaining usage strings ship in `Info.plist` and must match reality
      in the review notes: photo library (save/manage captured images),
      location (celestial position calculations), local network +
      Bonjour (above). Critical alerts (if granted) deserve one line too:
      "safety alerts for unattended telescope operation (storm/rain,
      equipment failure) — user opt-in."
- [ ] Background modes (`remote-notification`, `fetch`) are
      review-sensitive: justify as "APNs-triggered refresh of sequence
      status / safety alerts during unattended overnight imaging."
- [ ] Screenshots: 6.7" + 6.1" iPhone, 12.9" iPad (the app supports iPad
      orientations per `Info.plist`).
- [ ] Privacy "nutrition label": no tracking, no third-party analytics;
      data stays between the app and the user's own server. Push tokens
      are stored on the user's own server only (`device_push_tokens`
      table) — that still counts as "Device ID" collection? No — it is
      not linked to identity and not used for tracking; declare "Data Not
      Collected" only if genuinely no analytics SDKs are linked. Verify
      `apps/mobile/pubspec.yaml` for analytics deps before declaring.
- [ ] Age rating, support URL, marketing URL, privacy policy URL.

## Phase 7 — Post-approval

- [ ] Phased release on; monitor crash reports in Xcode Organizer.
- [ ] Tag the release; archive the dSYMs.
- [ ] Confirm production APNs delivery from a field server (not the office
      LAN) within the first day — `BadDeviceToken` spikes in the server
      log (`apps/desktop` log: APNs sender warnings) are the canary for an
      entitlements/profile mix-up.
