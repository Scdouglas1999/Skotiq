# Release Limitation Mirror Checklist

Every limitation and capability gap stated in a release must say the **same
thing** in all four places a user or operator can encounter it. When they
disagree, a user reads "supported" in one place and "unavailable" in another, and
the release looks untrustworthy. This checklist is the gate that keeps them in
sync; run it during release-candidate review.

## The four mirrors

A limitation in the release notes (`docs/release/v<version>.md`) must be mirrored
in **all** of:

1. **`docs/known-limitations.md`** — the accepted-limitations table, with impact,
   workaround, and release-blocker call.
2. **`docs/supported-hardware-by-platform.md`** — the backend-availability /
   device-category tables, and the *Verified Hardware* table when the limitation
   is about a specific device.
3. **In-app Platform Capabilities** — Settings → Connection → Platform
   Capabilities (the `PlatformCapabilityMatrix` in
   `packages/skotiq_core/lib/src/models/backend/platform_capabilities.dart`).
4. **`/api/info` → `platformCapabilities`** — the headless API surface
   (`apps/desktop/lib/headless_api/handlers/system_handlers.dart`), which must
   serve the same matrix as the in-app UI.

The scoped capability statement (the "First public beta — what's verified" block)
must be **word-for-word identical** in the README, the release notes, and the
`## <version> Verified Scope` section of `docs/known-limitations.md`.

## Per-release checklist

For each limitation listed in the release notes, confirm every row:

- [ ] It has a row in `docs/known-limitations.md` with impact + workaround +
      release-blocker decision + owner/tracking pointer.
- [ ] If it is hardware/platform-related, the relevant cell in
      `docs/supported-hardware-by-platform.md` reflects it (and a *Verified
      Hardware* row exists or is explicitly marked not-verified).
- [ ] The in-app Platform Capabilities matrix marks the same backend/device as
      `unsupported` / `capability-gated` with a user-facing reason.
- [ ] `/api/info`'s `platformCapabilities` returns the same verdict as the UI.
- [ ] The scoped-capability block matches the README / release notes verbatim.
- [ ] Unsupported controls are **disabled or fail with an explicit reason** — not
      a silent no-op (see `docs/no-fake-hardware-policy.md`).
- [ ] Anything affecting mount safety, unattended-imaging safety, data loss,
      credential exposure, or install/upgrade integrity is treated as a release
      blocker unless the release removes that workflow from scope.

If any mirror disagrees, the release candidate is **not ready** — fix the
disagreement, do not ship the inconsistency.

## How to verify the live-API mirror

The two document mirrors are diffable by eye. The two runtime mirrors are
checkable against a running instance:

```bash
# in-app vs API: the API matrix should equal what the Platform Capabilities
# screen renders. Against a running headless instance (token required):
curl -s -H "Authorization: Bearer $SKOTIQ_TOKEN" \
  http://<host>:8080/api/info | jq '.platformCapabilities'
```

Compare each backend/device verdict against the in-app Platform Capabilities
screen and against the two docs. They must agree.

## Quick doc cross-check

The backend-availability rows in the two docs should not drift apart. A coarse
text diff catches obvious divergence (it is a sanity check, not a parser):

```bash
grep -E '^\| (ASCOM COM|ASCOM Alpaca|INDI|Native SDK|Simulator)' \
  docs/known-limitations.md docs/supported-hardware-by-platform.md
```

Read the two blocks side by side; every backend's per-platform verdict
(Available / Unsupported / Capability-gated) must match.
