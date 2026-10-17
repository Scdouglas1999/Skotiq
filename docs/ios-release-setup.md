# Skotiq Mobile — iOS release setup (Mac + Apple Developer steps)

This document is the human runbook for everything that **cannot** be done from
the Linux build agent and must be done on a Mac with Xcode and a paid Apple
Developer account. The repository already contains a fully-configured Xcode
project plus all the iOS/Dart code; this file lists the GUI steps that finish
the build, sign it, and ship it.

**Bundle id:** `com.skotiq.mobile`
**App Group:** `group.com.skotiq.app`
**Workspace to open:** `apps/mobile/ios/Runner.xcworkspace` (always the
*workspace*, never the bare `.xcodeproj` — CocoaPods integrates through it).

> What the agent already did (no Mac needed, validated by review):
> - `Info.plist`: added `UIBackgroundModes` (`remote-notification`, `fetch`).
>   Live Activities keys, Bonjour, and usage strings were already present.
> - `Runner/Runner.entitlements`: added `aps-environment = development`, the
>   App Group `group.com.skotiq.app`, and kept the existing Critical Alerts
>   key. Used by the **Debug** and **Profile** configs.
> - `Runner/RunnerRelease.entitlements`: a sibling file identical except
>   `aps-environment = production`. Used by the **Release** config. iOS does NOT
>   auto-rewrite `development`->`production`, so the production value must live
>   in a real file that the Release config signs against (see §6).
> - `project.pbxproj`: set `CODE_SIGN_ENTITLEMENTS` per Runner build config —
>   `Runner/Runner.entitlements` for Debug + Profile,
>   `Runner/RunnerRelease.entitlements` for Release. These are the only
>   build-setting edits; the pbxproj stays structurally intact.
> - `AppDelegate.swift`: APNs registration + token forwarding over the
>   `skotiq/push` MethodChannel, plus foreground critical-alert
>   presentation.
> - Dart: `apps/mobile/lib/services/push_registration_service.dart` POSTs the
>   APNs token to the desktop's `POST /api/push/register-token` (`platform=apns`),
>   wired into the connect flow in `mobile_connection_ops.dart`.

---

## 0. Prerequisites

- A Mac with **Xcode 15+** and command-line tools.
- A **paid Apple Developer Program** membership ($99/yr). The free/personal
  team **cannot** ship App Groups, Push Notifications, or Critical Alerts — all
  three are used by this app.
- CocoaPods installed (`sudo gem install cocoapods` or via Homebrew).
- The repo checked out, with Flutter 3.44+ on PATH.

First-time bootstrap on the Mac:

```sh
cd apps/mobile
flutter pub get
flutter precache --ios
cd ios && pod install && cd -
```

`flutter build ios` regenerates `Flutter/Generated.xcconfig` and runs
`pod install`, so the project opens clean.

---

## 1. Signing team (required for any device build)

The pbxproj intentionally ships with `CODE_SIGN_STYLE = Automatic` and **no**
`DEVELOPMENT_TEAM` — the team is machine/account specific and must be set in the
GUI so it does not leak into the repo.

1. Open `apps/mobile/ios/Runner.xcworkspace`.
2. Select the **Runner** project → **Runner** target → **Signing &
   Capabilities**.
3. Pick your **Team** from the dropdown. Leave **Automatically manage signing**
   checked.
4. Confirm the **Bundle Identifier** reads `com.skotiq.mobile`
   (or change it to one your team owns, and update it everywhere noted below).

Repeat the Team selection on every target you create in the sections that
follow (extensions inherit nothing automatically).

---

## 2. Capabilities on the Runner target

The entitlements **file** is already linked (the agent set
`CODE_SIGN_ENTITLEMENTS`). You still add the capabilities in the GUI so Xcode
registers them against the App ID in the developer portal and regenerates the
provisioning profile.

On **Runner → Signing & Capabilities → + Capability**, add:

1. **Push Notifications** — this is what makes `aps-environment` meaningful and
   enables APNs token issuance. Without it the device never gets a token.
2. **Background Modes** — tick **Remote notifications** and **Background fetch**
   (these mirror the `UIBackgroundModes` already in `Info.plist`).
3. **App Groups** — add `group.com.skotiq.app`. If the group does not exist
   yet, click the **+** inside the App Groups editor to create it; this also
   creates it in the developer portal.

The **Critical Alerts** entitlement is special — see §5. It will show as
present in the entitlements file but Apple must grant it before it does
anything.

After saving, re-open BOTH `Runner.entitlements` and
`RunnerRelease.entitlements` and confirm these keys survive in each:
`aps-environment`, `com.apple.security.application-groups`,
`com.apple.developer.usernotifications.critical-alerts`. The only intended
difference between the two files is `aps-environment` (`development` in
`Runner.entitlements`, `production` in `RunnerRelease.entitlements`).

> Capability edits in the GUI rewrite whichever entitlements file is bound to
> the **currently selected scheme/configuration**. Adding a capability while the
> active config is Debug touches `Runner.entitlements` only; switch the scheme
> to Release (Edit Scheme → Run → Build Configuration → Release, or use the
> Archive configuration) and add it again so `RunnerRelease.entitlements` gets
> the same capability. Easiest: add every capability once per config, then
> diff the two files — they must match except for the `aps-environment` value.

---

## 3. APNs server-side key (one-time, for the desktop)

The phone token is useless unless the desktop can authenticate to APNs to send
the push. The desktop's remote-push delivery
(`packages/skotiq_remote_protocol/lib/src/push/remote_push_delivery.dart`)
expects an APNs **token-based** auth key (`.p8`).

1. In <https://developer.apple.com> → **Certificates, Identifiers & Profiles**
   → **Keys** → **+**.
2. Name it `Skotiq APNs`, enable **Apple Push Notifications service (APNs)**,
   and **Continue → Register**.
3. **Download** the `.p8` (you can only download it once). Note the **Key ID**
   and your **Team ID**.
4. Configure the desktop push config with the `.p8` path, Key ID, Team ID, and
   the app's **Topic** = the bundle id `com.skotiq.mobile`. See
   `packages/skotiq_remote_protocol/lib/src/push/push_config.dart` for the
   field names the desktop reads.

> APNs environment: development tokens (from a development build) only work
> against the APNs **sandbox** host; App Store / TestFlight builds use the
> **production** host. The `aps-environment` value is fixed per build
> configuration by the entitlements file that config signs against — Debug and
> Profile ship `development` (`Runner.entitlements`), Release ships `production`
> (`RunnerRelease.entitlements`). iOS does NOT auto-flip it from the
> provisioning profile (see §6). The desktop delivery must target the APNs host
> matching the build that produced the token (sandbox for dev/Profile builds,
> production for Release/TestFlight/App Store builds).

---

## 4. Create the extension targets (Live Activity, Watch, App Intents)

The Swift sources exist on disk but are **not** Xcode targets yet. The build
agent deliberately did **not** add them — adding native targets is the kind of
pbxproj surgery that corrupts the project file. Create them in the GUI.

### 4a. Live Activity widget extension

Source: `apps/mobile/ios/SkotiqLiveActivity/` (`*.swift` + `Info.plist`,
already `com.apple.widgetkit-extension`).

1. **File → New → Target… → iOS → Widget Extension.**
2. Product Name: `SkotiqLiveActivity`. Project: `Runner`. **Include Live
   Activity: checked.** Include Configuration App Intent: unchecked.
3. Delete the boilerplate Swift + `Info.plist` Xcode generates inside the new
   group (keep the repo files).
4. **Add Files to "Runner"…** the three repo files
   (`SkotiqLiveActivityAttributes.swift`,
   `SkotiqLiveActivityWidget.swift`, `Info.plist`) with **target =
   SkotiqLiveActivity only**, **Copy items if needed = unchecked**.
5. Build Settings → set `INFOPLIST_FILE` to
   `SkotiqLiveActivity/Info.plist`.
6. Set the **Team** and ensure the deployment target is **iOS 16.2+** (the
   `ActivityContent` API the widget uses is 16.2-gated — matching the host's
   `@available(iOS 16.2, *)` guards in `AppDelegate.swift`).
7. `SkotiqLiveActivityAttributes` must be in **both** the Runner target and
   the extension target (the host requests the activity, the widget renders it).
   Add the attributes file to Runner's target membership too.

### 4b. watchOS app + complication

Follow the existing, detailed runbook verbatim:
**`apps/mobile/ios/SkotiqWatchComplication/SETUP.md`** (§1–7). It covers the
watch app shell, the widget extension, attaching the repo Swift files, and the
App Group on all watch targets. Nothing here supersedes it.

### 4c. App Intents (Siri) extension

Source: `apps/mobile/ios/SkotiqAppIntents/`
(`SkotiqAppIntents.swift` + `Info.plist`). Modern AppIntents do **not** use
the legacy `NSExtension` entry point — the framework auto-discovers `AppIntent`
types.

Two supported options:

- **Simplest — in-app intents (recommended):** add
  `SkotiqAppIntents.swift` directly to the **Runner** target (target
  membership checkbox). No separate extension target is needed; Siri/Shortcuts
  discover the intents from the app binary. Skip the extension.
- **Or a dedicated App Intents Extension:** **File → New → Target… → iOS → App
  Intents Extension**, name it `SkotiqAppIntents`, then add the repo Swift
  file (target = extension only) and set its `INFOPLIST_FILE`.

Either way, the extension/app must have the **App Group**
`group.com.skotiq.app` capability — `SkotiqAppIntents.swift` reads the
shared `UserDefaults(suiteName:)` and fails loudly without it.

### 4d. App Group on every extension

For each new target (Live Activity, Watch app, Watch complication, App Intents
if a separate target): **Signing & Capabilities → + Capability → App Groups →**
add `group.com.skotiq.app`. The host writes snapshots there; the extensions
read them. A missing group is a loud runtime failure by design.

---

## 5. Critical Alerts entitlement (Apple grant required)

Critical Alerts bypass Do Not Disturb / Focus / the silent switch to wake a
sleeping operator. The entitlement key is already in `Runner.entitlements`, but
**Apple must approve a written request** before it does anything.

The full runbook — including the verbatim justification text to paste into
Apple's form, the App ID capability toggle, and the "regenerate profiles after
the grant" step — lives in
**`apps/mobile/ios/CRITICAL_ALERTS_SETUP.md`** (§B, §C). Follow it.

Until granted, builds still succeed; iOS silently downgrades the alert level.
The in-app `IosBackgroundBanner` shows the "not granted" copy — ship that
honestly to TestFlight reviewers.

---

## 6. Provisioning profiles

With automatic signing, Xcode regenerates profiles as you add capabilities. If
you sign manually, after **any** capability change (Push, App Groups, Critical
Alerts grant) you must:

1. In the developer portal, open the App ID `com.skotiq.mobile`
   and confirm **Push Notifications**, **App Groups**, and (once granted)
   **Critical Alerts** are enabled.
2. **Regenerate** all distribution and development profiles — the entitlements
   only flow through profiles regenerated *after* the capability is enabled.
3. Repeat for each extension's App ID (Live Activity, Watch, App Intents) — each
   gets its own App ID and profile.

### `aps-environment`: per-configuration, NOT auto-rewritten

A common myth is that Xcode rewrites `aps-environment` from `development` to
`production` when you archive with a distribution profile. **It does not.** The
embedded `aps-environment` entitlement is taken **verbatim** from the
entitlements file that the active build configuration's `CODE_SIGN_ENTITLEMENTS`
points at. The provisioning profile must *permit* the value (a distribution
profile's `aps-environment` allows `production`), but it does not *change* the
value your binary ships.

This repo handles it with two entitlements files, bound per configuration in
`project.pbxproj`:

| Build configuration | `CODE_SIGN_ENTITLEMENTS` | `aps-environment` |
| --- | --- | --- |
| Debug | `Runner/Runner.entitlements` | `development` (sandbox) |
| Profile | `Runner/Runner.entitlements` | `development` (sandbox) |
| Release | `Runner/RunnerRelease.entitlements` | `production` |

Consequences:

- **Archive / TestFlight / App Store** builds use the **Release** configuration,
  so they sign against `RunnerRelease.entitlements` and ship
  `aps-environment=production`. The desktop must send those tokens via the APNs
  **production** host. If a Release build shipped `development`, the production
  host would reject every token with `BadDeviceToken` and all cellular safety
  pushes would silently fail.
- **`flutter run` / dev device installs** use the **Debug** configuration and
  ship `development`, so they keep working against the APNs **sandbox** host.
  This is why `Runner.entitlements` must NOT be hard-coded to `production`.
- Do not collapse the two files back into one. A single `development` file
  breaks production push; a single `production` file breaks dev installs.

---

## 7. Build, run, and verify

```sh
cd apps/mobile
flutter build ios --release          # device archive build
# or, on a connected device for dev:
flutter run --release -d <device-id>
```

Smoke tests (need a physical device — the Simulator has no APNs and ignores
entitlements):

- **APNs token registration:** pair the phone with a desktop, then connect.
  Watch the Xcode console / `os_log` for `[PushRegistration] Registered APNs
  token with <host>:<port>`. Cross-check the desktop log for `registered apns
  token for device=<id>` from `PushHandlers`.
- **Foreground critical alert:** with the app open, trigger a safety event on
  the desktop; the banner + sound should present. The host `AppDelegate`
  re-claims the `UNUserNotificationCenter` delegate (so the plugin's delegate
  does not shadow it) and forces `.sound` for REMOTE/APNs pushes, while
  forwarding LOCAL notifications back to `flutter_local_notifications`. Verify a
  **remote** (cellular/APNs) critical alert plays sound while foregrounded, and
  that tapping a **local** notification still routes into the app (the plugin's
  tap handler must still fire — that path is forwarded, not stolen).
- **Background/asleep critical alert:** lock the phone, take it off the LAN
  (cellular only), trigger a safety event; the APNs push should wake it (needs
  the Critical Alerts grant + the desktop APNs key from §3).
- **Live Activity:** start a sequence; confirm the lock-screen / Dynamic Island
  activity appears (needs §4a + iOS 16.2+).
- **Watch complication / Siri intents:** per their SETUP docs.

---

## 8. TestFlight / App Store submission

1. **Xcode → Product → Archive** (scheme: Runner, Any iOS Device).
2. In the Organizer, **Distribute App → App Store Connect → Upload**. Let Xcode
   manage signing, or pick your distribution profile.
3. In **App Store Connect**:
   - Create the app record (bundle id `com.skotiq.mobile`) if it
     does not exist.
   - Fill in the privacy nutrition labels — note the app uses **Local Network**,
     **Camera** (QR), **Photos** (save), and **Location** (celestial calc); the
     usage strings are already in `Info.plist`.
   - For Critical Alerts review, point reviewers at the dashboard's
     weather/safety panel and the sequencer safety-monitor config (Apple often
     asks for screenshots — see `CRITICAL_ALERTS_SETUP.md`).
4. Submit the build to **TestFlight** (internal first), then to App Review.

---

## Appendix — channel / endpoint contract (for reference)

| Piece | Where |
| --- | --- |
| APNs registration + token forward | `apps/mobile/ios/Runner/AppDelegate.swift` (`skotiq/push`, methods `registerForRemoteNotifications` / `getApnsToken`; host→Dart `onApnsToken` / `onApnsRegistrationError`) |
| Dart token POST | `apps/mobile/lib/services/push_registration_service.dart` → `POST /api/push/register-token` body `{deviceId, platform:"apns", token}` |
| Connect-flow wiring | `apps/mobile/lib/main_parts/mobile_connection_ops.dart` (`_registerPushTokenIfIos`) |
| Server endpoint | `apps/desktop/lib/headless_api/handlers/push_handlers.dart` (`handleRegisterToken`; accepts `platform ∈ {fcm, apns}`) |
| Entitlements (Debug/Profile, `aps-environment=development`) | `apps/mobile/ios/Runner/Runner.entitlements` |
| Entitlements (Release, `aps-environment=production`) | `apps/mobile/ios/Runner/RunnerRelease.entitlements` |
| Background modes | `apps/mobile/ios/Runner/Info.plist` (`UIBackgroundModes`) |
| Critical Alerts runbook | `apps/mobile/ios/CRITICAL_ALERTS_SETUP.md` |
| Watch setup | `apps/mobile/ios/SkotiqWatchComplication/SETUP.md` |

> Platform string note: the server validates `platform` against `{'fcm',
> 'apns'}`, **not** `{'ios','android'}`. iOS registers as **`apns`**. The
> `deviceId` MUST be the same id the device paired with
> (`MobilePairingService.deviceId()`), or the server returns `404
> unknown_device`.
