# Android Background Push (FCM) — Provisioning

The entire FCM path is built and dormant. Android builds compile and run
with **zero** Firebase configuration: `PushBridge.kt` reports
`fcm_unconfigured` and the app falls back to LAN-only alerting (the UDP
receiver, foreground + same network). Off-LAN / backgrounded alerting on
Android lights up when you drop in two files — no code changes.

## What exists already

| Layer | Component | Status |
| --- | --- | --- |
| Server sender | `FcmRemotePushDelivery` (FCM v1 API, service-account JWT) | built + unit-tested |
| Server config | `PushConfig.load` → `<appSupport>/Skotiq/push_config.json` | built |
| Token registry | `POST /api/push/register-token` with `platform=fcm` | built |
| Android client | `PushBridge.kt` + `SkotiqPushService.kt` over the `skotiq/push` channel | built, dormant |
| Dart flow | `push_registration_service.dart` (registers on pair/connect/foreground) | built + unit-tested |

Background pushes render with **no client display code**: the server sends a
`notification` payload targeting the `skotiq_critical` channel, which
`PushBridge` creates at startup. Foreground FCM messages are deliberately
dropped — the LAN receiver already covers foreground alerting (mirrors iOS).

## Provisioning steps (owner)

1. Create a Firebase project (console.firebase.google.com) and add an
   Android app with package name `com.skotiq.mobile`.
2. Download `google-services.json` into `apps/mobile/android/app/`.
   The Gradle build detects it and applies the Google-services plugin
   automatically (see the conditional in `app/build.gradle.kts`); rebuild the
   APK. Without the file the plugin is skipped and the build stays green.
3. In Firebase console → Project settings → Service accounts, generate a
   service-account private-key JSON and copy it to the imaging host.
4. On the imaging host, create (or extend) the push config at
   `<appSupport>/Skotiq/push_config.json`
   (or point `SKOTIQ_PUSH_CONFIG` at it):

   ```json
   {
     "fcm": {
       "enabled": true,
       "serviceAccountPath": "/absolute/path/to/service-account.json"
     }
   }
   ```

5. Restart the headless server, re-open the app while paired (registration
   fires on connect), and send a test alert
   (`POST /api/logs/test-entry` exercises the notification plumbing).

## Verification status

Verified without a Firebase project: the APK builds with the scaffold and no
`google-services.json`; the dormant no-op path (clean `fcm_unconfigured`
log, no crash); the Dart registration wire contract (`platform=fcm`, bearer
auth, deviceId, token rotation) via unit tests; the server sender via its
existing suite. **End-to-end delivery through real FCM is unverified until a
real project is provisioned** — verify on a physical device (emulators
without Google Play services cannot receive FCM).
