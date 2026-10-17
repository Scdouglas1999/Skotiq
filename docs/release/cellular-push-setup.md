# Cellular push setup — FCM service account + APNs .p8

How to mint the two cloud credentials that let a Skotiq server (desktop
GUI or headless appliance) reach a phone over **cellular** — i.e. when the
phone is asleep at home, far from the rig's LAN — and exactly where they
plug into the code that already ships.

## How the code finds the credentials (read this first)

The loader is
`packages/skotiq_remote_protocol/lib/src/push/push_config.dart`
(`PushConfig.load`). Resolution order:

1. `SKOTIQ_PUSH_CONFIG` env var → absolute path to a
   `push_config.json`;
2. `<application-support>/Skotiq/push_config.json` — on the systemd /
   Pi appliance `HOME` is pinned to `/var/lib/skotiq`, so this is
   `/var/lib/skotiq/.local/share/<app-support>/Skotiq/push_config.json`
   (easier: just set `SKOTIQ_PUSH_CONFIG=/etc/skotiq/push_config.json`
   in `/etc/skotiq/headless.env` — the example file has the line
   commented out);
3. absent/malformed → `PushConfig.disabled`. The server runs fine; phones
   still get LAN UDP + WebSocket pushes, just nothing over cellular.

Wiring points that consume it:

* headless: `apps/desktop/lib/main_headless.dart` ("Phase D" block) →
  `HeadlessApiServer.wireRemotePushDelivery`
  (`apps/desktop/lib/headless_api_server.dart`, ~line 668) →
  `buildRemotePushDelivery` in
  `packages/skotiq_remote_protocol/lib/src/push/remote_push_delivery.dart`,
  which constructs `FcmRemotePushDelivery` and/or `ApnsRemotePushDelivery`
  inside a `CompositeRemotePushDelivery`;
* GUI desktop: same wiring from `apps/desktop/lib/desktop_app_bootstrap.dart`.

Phone tokens arrive via `POST /api/push/register-token`
(`apps/desktop/lib/headless_api/routes/push_routes.dart` →
`handlers/push_handlers.dart`) with body `{deviceId, platform, token}`,
`platform` ∈ `fcm` (Android) / `apns` (iOS), and are upserted into the
`device_push_tokens` table of the pairing DB. Per-device mute/enable
preferences live in `device_push_prefs`
(`GET/PUT /api/push/preferences`). Only currently-paired devices can
register, and a device can only touch its own row.

**Silent-degradation gotcha:** `PushConfig.validated()` disables any
channel whose referenced secret file is missing or whose APNs fields are
incomplete — *without crashing*. After any config change, check the
startup log line: `Cellular push delivery wired (cloud channel
configured)` vs `(mock — no cloud credentials)`.

## `push_config.json` — full schema

Field names are exact (from `push_config.dart`):

```json
{
  "mock": false,
  "fcm": {
    "enabled": true,
    "serviceAccountPath": "/etc/skotiq/secrets/firebase-service-account.json"
  },
  "apns": {
    "enabled": true,
    "p8KeyPath": "/etc/skotiq/secrets/AuthKey_AB12CD34EF.p8",
    "keyId": "AB12CD34EF",
    "teamId": "TEAM123456",
    "bundleId": "com.skotiq.mobile",
    "useSandbox": false
  }
}
```

* `mock: true` forces the local recording delivery even with cloud
  secrets present (dev only — logs "would-send" frames instead of
  sending).
* `bundleId` is sent as the `apns-topic` header and **must** be the iOS
  app's bundle id: `com.skotiq.mobile`.
* `useSandbox` selects `api.sandbox.push.apple.com` vs
  `api.push.apple.com` (see `ApnsRemotePushDelivery` in
  `remote_push_delivery.dart`). It must match the app build's
  `aps-environment` entitlement: Debug/Profile builds
  (`Runner.entitlements`, `development`) → `useSandbox: true`;
  TestFlight/App Store builds (`RunnerRelease.entitlements`,
  `production`) → `useSandbox: false`. A mismatch = `BadDeviceToken` on
  every send.

## Part A — Firebase service-account JSON (Android / FCM)

1. <https://console.firebase.google.com> → create (or open) the project
   backing the Android app. Add the Android app with package name from
   `apps/mobile/android/app/build.gradle` (`applicationId`) and place the
   generated `google-services.json` per standard Flutter/Firebase setup —
   that file is the *phone-side* half and is separate from this server
   credential.
2. Project settings (gear) → **Service accounts** → *Generate new private
   key* → downloads a JSON file. This is the server credential.
   * The code (`FcmServiceAccount.fromJson` in
     `remote_push_delivery.dart`) requires `project_id`, `client_email`,
     `private_key` (and honours `token_uri`); a key generated this way
     always has them.
   * Sends go to the FCM **v1** endpoint
     `https://fcm.googleapis.com/v1/projects/<project_id>/messages:send`
     with an OAuth2 token minted from the key, scope
     `https://www.googleapis.com/auth/firebase.messaging`. No "Cloud
     Messaging API (Legacy)" toggle needed — v1 is on by default.
3. If the IAM role was stripped down, the service account needs
   `roles/firebase.messaging` (Firebase Cloud Messaging API Admin is what
   the console grants by default).
4. Install on the appliance:

   ```sh
   sudo install -d -m 0750 -g skotiq /etc/skotiq/secrets
   sudo install -m 0640 -g skotiq firebase-service-account.json \
     /etc/skotiq/secrets/firebase-service-account.json
   ```

   (group `skotiq`, because the daemon runs as that user; never
   world-readable — this key can send pushes to all your users.)

## Part B — APNs token key `.p8` (iOS)

1. <https://developer.apple.com/account> → **Certificates, Identifiers &
   Profiles → Keys → +**.
2. Name it (e.g. `Skotiq APNs`), tick **Apple Push Notifications
   service (APNs)**, Continue, Register.
3. **Download the `.p8` — one chance only.** Apple never re-serves it;
   losing it means revoking and re-issuing. Record:
   * **Key ID** — 10 chars, shown on the key page (also in the filename
     `AuthKey_<KeyID>.p8`) → `apns.keyId`;
   * **Team ID** — 10 chars, top-right of the membership page →
     `apns.teamId` (used as the JWT `iss`; the sender re-mints the ES256
     JWT every ~40 min, see `_jwtTtl` in `remote_push_delivery.dart`).
4. One key serves both sandbox and production hosts, and any number of
   apps in the team — no per-environment keys needed.
5. Install next to the FCM key with the same ownership/modes
   (`/etc/skotiq/secrets/AuthKey_<KeyID>.p8`).

## Part C — plug in and verify

1. Write `/etc/skotiq/push_config.json` (schema above), `chmod 0640`,
   group `skotiq`.
2. Point the env at it — in `/etc/skotiq/headless.env`:

   ```sh
   SKOTIQ_PUSH_CONFIG=/etc/skotiq/push_config.json
   ```

   (Docker: set the same env var and bind-mount the config + secrets, or
   drop them inside the `skotiq-data` volume.)
3. `sudo systemctl restart skotiq-headless`, then check
   `journalctl -u skotiq-headless` for
   `Cellular push delivery wired (cloud channel configured)`.
4. Pair a phone, confirm the server logs the
   `POST /api/push/register-token` upsert, then trigger a test
   notification (e.g. the notification test action in app settings, or
   start/abort a dummy sequence). Phone on **cellular, Wi-Fi off** for a
   true end-to-end check.
5. Failure modes worth knowing:
   * `BadDeviceToken` (APNs 400) → sandbox/production mismatch, see the
     `useSandbox` note above. Stale/`Unregistered` (410) tokens are pruned
     automatically (`StalePushTokenSink`); config-fault rejections are
     deliberately NOT pruned, so they keep appearing in the log until
     fixed.
   * `(mock — no cloud credentials)` at startup → `validated()` zeroed a
     channel: a path in `push_config.json` doesn't exist *from the
     daemon's view* (remember `ProtectSystem=strict` — `/etc/skotiq`
     is readable, but a path under e.g. `/root` is not), or an `apns`
     field is empty.

## Security notes

* Both files are send-capable, long-lived secrets. Keep them out of git,
  out of backups that leave the site unencrypted, mode `0640
  root:skotiq`.
* Rotation: FCM — generate a new service-account key, swap the file,
  restart, then delete the old key in the Google console. APNs — issue a
  second key, swap, restart, revoke the old one in the portal (revoking
  first = push outage).
