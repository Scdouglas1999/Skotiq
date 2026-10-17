# SkotiqWatchComplication — Xcode setup

ships the Swift source for an Apple Watch complication, but
WidgetKit complications require a watchOS target in the Xcode project,
which has to be created in the Xcode UI. Editing
`Runner.xcodeproj/project.pbxproj` by hand is fragile and we deliberately
do not do that from the build agent.

Follow these steps once, on a Mac with Xcode 15+, before releasing the
mobile app with watch support.

## 1. Add a watchOS app target

1. Open `apps/mobile/ios/Runner.xcworkspace` in Xcode.
2. **File → New → Target…** → watchOS → **Watch App for iOS App**.
3. Set:
   - **Product Name:** `SkotiqWatch`
   - **Bundle Identifier:** `<your iOS app id>.watchkitapp` (Xcode will
     suggest this automatically based on Runner's bundle id).
   - **Companion iOS App:** `Runner`.
   - **Interface:** SwiftUI.
   - **Language:** Swift.
   - **Include Notification Scene:** unchecked (we route notifications
     through the iOS host, not the watch).
4. When prompted to add the new scheme, accept.

This creates two targets:
- `SkotiqWatch` (the watch app shell — required even though we only
  ship a complication).
- `SkotiqWatch Watch App` (the actual watchOS code).

## 2. Add a watchOS Widget Extension

1. With the workspace open, **File → New → Target…** → watchOS →
   **Widget Extension**.
2. Set:
   - **Product Name:** `SkotiqWatchComplication`
   - **Project:** `Runner`
   - **Embed in Application:** `SkotiqWatch Watch App`
   - **Include Configuration Intent:** unchecked.
   - **Include Live Activity:** unchecked.
3. Delete the boilerplate files Xcode generates inside
   `SkotiqWatchComplication/` (`SkotiqWatchComplication.swift`,
   `SkotiqWatchComplicationBundle.swift`, `Info.plist`,
   `SkotiqWatchComplication.entitlements`).

## 3. Attach the source files in this folder

For each file in `apps/mobile/ios/SkotiqWatchComplication/`:

- `SkotiqWatchComplicationEntry.swift`
- `SkotiqWatchTimelineProvider.swift`
- `SkotiqWatchComplication.swift`
- `Info.plist`

1. In the Project Navigator, right-click on the `SkotiqWatchComplication`
   group → **Add Files to "Runner"…**
2. Select the file.
3. In the dialog:
   - Targets: check **SkotiqWatchComplication only**.
   - "Copy items if needed": leave **unchecked** (the files already live
     in the repo at the right path).

Then in **Build Settings** for `SkotiqWatchComplication`:

- Set `INFOPLIST_FILE` to
  `apps/mobile/ios/SkotiqWatchComplication/Info.plist`.

## 4. App Group entitlement

The complication reads the JSON snapshot from a shared `UserDefaults`
suite keyed by an App Group. Configure the same group id on both
targets.

1. Select the `Runner` target → **Signing & Capabilities** → **+
   Capability** → **App Groups**. Add `group.com.skotiq.app`.
2. Select the `SkotiqWatchComplication` target → **Signing &
   Capabilities** → **+ Capability** → **App Groups**. Add the same
   `group.com.skotiq.app`.
3. (Optional but recommended for parity) Repeat on the
   `SkotiqWatch Watch App` target so future watch-app code can
   read/write the same suite.

The suite name is referenced from Swift as
`skotiqWatchAppGroupSuite` in
`SkotiqWatchTimelineProvider.swift`. If you need to change it,
update that constant **and** the matching Dart constant in
`apps/mobile/lib/services/watch_complication_service.dart`.

## 5. Provisioning

You will need provisioning profiles that include the App Group capability
for all three new targets. The free / personal team profiles do **not**
support App Groups; a paid Apple Developer account is required to ship
this to a device.

## 6. Verifying the build

After the targets and files are wired up:

```sh
cd apps/mobile
flutter build ios --release
```

The watch app + complication build alongside the iOS app. To smoke-test
without a paired watch, run the iOS app on a simulator, trigger any
sequence state change, and confirm that the Xcode console emits no
`[SkotiqWatchComplication] App Group ... unavailable` warnings
(those indicate the App Group entitlement was not applied).

## 7. Binding the complication to a watch face

On the paired Apple Watch, after the watch app installs:

1. Long-press the watch face → **Edit**.
2. Swipe to the **Complications** page.
3. Tap a complication slot → choose **Skotiq**.
4. Repeat for any additional slots (the widget supports `Circular`,
   `Rectangular`, and `Inline` families).

The complication will update automatically when the host iOS app pushes
new state, and at a 60-second floor refresh policy when the host is
suspended.
