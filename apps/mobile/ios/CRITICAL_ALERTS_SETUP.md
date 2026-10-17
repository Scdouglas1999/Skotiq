# iOS Critical Alerts setup

Skotiq Mobile uses iOS Critical Alerts for a small, well-defined set of
safety notifications that must wake an operator who has gone to sleep next
to a running rig. Apple gates Critical Alerts behind a special entitlement,
`com.apple.developer.usernotifications.critical-alerts`, which is **not**
self-serve. Apple must approve a written request before the entitlement
can be added to the developer account's provisioning profile.

This document records the project-side wiring already in place plus the
manual steps you (the developer) still need to perform once.

---

## What Critical Alerts do

A notification posted with `UNNotificationInterruptionLevel.critical` —
which corresponds in Dart to `InterruptionLevel.critical` on
`DarwinNotificationDetails` — bypasses:

- the ringer / silent switch,
- Do Not Disturb,
- Focus modes,
- Sleep schedule quiet hours.

It plays a sound (defaults to the system critical-alert sound) at the
volume the user set in **Settings → Notifications → Skotiq → Critical
Alerts**, which is independent of the system ringer volume. Without the
entitlement, iOS silently ignores the `critical` interruption level and
the notification falls back to the next-lowest level — meaning a sleeping
user with Focus or DnD enabled will not be woken when their mount runs
away or weather turns unsafe.

---

## Where the project uses Critical Alerts

The mobile app fires `InterruptionLevel.critical` from exactly four sites
in `apps/mobile/lib/services/notification_service.dart`:

| Method                          | Trigger                                                          |
| ------------------------------- | ---------------------------------------------------------------- |
| `notifySafety`                  | Safety monitor tripped (clouds, rain, wind, dome closed, etc.)   |
| `notifyMountParked`             | Mount parked mid-sequence (runaway protection, emergency stop)   |
| `notifyGuidingLost`             | Guide star lost during a long exposure                           |
| `notifyEquipmentDisconnected`   | Camera / mount / focuser / filter wheel disconnected mid-session |

Every other notification kind (sequence-complete, low battery, exposure
failed, autofocus failed, target completed, meridian flip, push from
desktop) uses default interruption level and does **not** require the
entitlement.

---

## What's already wired in the repo

1. **Entitlements file** — `apps/mobile/ios/Runner/Runner.entitlements`
   contains
   ```xml
   <key>com.apple.developer.usernotifications.critical-alerts</key>
   <true/>
   ```
   so signing tools will request the entitlement from any provisioning
   profile that lists it. Builds will still succeed without Apple's grant;
   iOS just downgrades the alert level at runtime.

2. **Permission request** — `MobileNotificationService.initialize()`
   passes `requestCriticalPermission: true` to `DarwinInitializationSettings`
   and additionally calls
   `IOSFlutterLocalNotificationsPlugin.requestPermissions(critical: true)`
   so the user is prompted for Critical Alert authorization on first
   launch (the prompt only appears once Apple has granted the entitlement
   on the provisioning profile — before that, the call is a silent no-op).

3. **Authorization state for the UI** —
   `MobileNotificationService.refreshCriticalAlertsAuthorization()` re-reads
   the current authorization state via `checkPermissions().isCriticalEnabled`
   and exposes it through `iosCriticalAlertsAuthorizedProvider`
   (`packages/skotiq_app/lib/widgets/ios_background_banner.dart`).
   `IosBackgroundBanner` switches its copy based on that state so the
   operator can see at a glance whether safety alerts will wake the
   device.

---

## What you still have to do — one-time steps

### A) Wire the entitlement into the Xcode target

The pbxproj file does not yet reference `Runner.entitlements`. You need
to add it through Xcode so the project file is updated cleanly (editing
`project.pbxproj` by hand is fragile and breaks signing). Steps:

1. Open `apps/mobile/ios/Runner.xcworkspace` in Xcode.
2. In the project navigator, select the **Runner** project, then the
   **Runner** target.
3. Go to **Signing & Capabilities**.
4. Click **+ Capability** in the upper-left of the tab.
5. Search for **Push Notifications** and double-click to add it (this is a
   prerequisite — the Critical Alerts checkbox lives inside it on newer
   Xcode versions). Skip if already present.
6. Click **+ Capability** again and search for **Notifications** /
   **Background Modes** if not present. (On modern Xcode versions Critical
   Alerts is exposed directly inside the entitlements editor.)
7. Either tick the **Critical Alerts** checkbox in the capabilities pane
   (newer Xcode), OR confirm Xcode has linked the existing
   `Runner.entitlements` file to the target. After saving, the target's
   build settings should show
   `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` in
   `project.pbxproj`.
8. Verify by re-opening `apps/mobile/ios/Runner/Runner.entitlements` —
   the `com.apple.developer.usernotifications.critical-alerts` key should
   already be there from this commit.
9. Commit the modified `project.pbxproj`.

### B) Request the Critical Alerts entitlement from Apple

Apple requires a written justification per app, submitted through the
"Request Critical Alerts Entitlement" form linked from
<https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>.
You must use the developer account that owns the App Store Connect record
for Skotiq Mobile (currently bundle id
`com.skotiq.mobile`).

**Submission text** (paste this into the justification field verbatim):

> Skotiq is an unattended astrophotography control app. Imaging
> sessions run for 4-12 hours overnight while the operator sleeps.
> Critical Alerts are used exclusively for: weather safety
> (clouds/rain/wind sensors), mount runaway / emergency stop, USB device
> disconnects during exposure, and guide-star loss during long exposures.
> Each event represents a session-ending failure that requires immediate
> human intervention to prevent equipment damage or data loss. Critical
> Alerts allow these notifications to bypass Do Not Disturb so an operator
> who has gone to sleep next to a running rig will be woken when the rig
> stops responding.

Approval typically takes 1–4 weeks. Apple may request additional context
or sample screenshots of the in-app safety screens; if so, point them at
the dashboard's weather/safety panel and the sequencer's safety-monitor
configuration screen.

### C) Once Apple grants the entitlement

1. Apple sends an email approving the request. The entitlement is added
   to your developer account at the team level.
2. In **Certificates, Identifiers & Profiles** (developer.apple.com),
   open the App ID for `com.skotiq.mobile` and enable
   **Critical Alerts** under the Notifications capability. Save.
3. **Regenerate** your provisioning profiles — both App Store and any
   ad-hoc / development profiles you use. The Critical Alerts entitlement
   only flows through profiles regenerated AFTER step 2.
4. In Xcode, either let automatic signing fetch the new profile, or
   download and install it manually.
5. Build a new IPA. The entitlement is now embedded.

### D) Local development before the grant arrives

The Critical Alerts entitlement only takes effect against a properly
signed build whose provisioning profile carries the entitlement. For
day-to-day development:

- **Simulator** ignores entitlements entirely. `InterruptionLevel.critical`
  silently downgrades. This is normal — don't waste time debugging it.
- **Development on a physical device** before Apple grants the
  entitlement: builds still succeed, but Critical Alerts will not wake
  the device. The in-app banner (see `IosBackgroundBanner`) will show
  the "not granted" copy. This is the correct behaviour to ship to
  TestFlight reviewers; do not paper over it.
- **Development on a physical device** after Apple grants the
  entitlement: regenerate the development provisioning profile (step C2),
  then a fresh local install will surface the Critical Alerts permission
  prompt on first launch.

---

## Future work (not required for )

- **Live Activities (`NSSupportsLiveActivities` + Activity implementation)**
  would surface live sequence progress on the lock screen alongside any
  Critical Alerts. The `Info.plist` does not currently declare
  `UIBackgroundModes` or `NSSupportsLiveActivities`; this is intentional
  scope for a later milestone.
- **Provisional notifications** (`requestProvisionalPermission: true`)
  could be added so non-safety notifications appear silently in
  Notification Center without requiring an alert prompt up-front. Not in
  scope for the Critical Alerts work.
