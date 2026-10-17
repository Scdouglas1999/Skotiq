# Skotiq Constellation hub

The **Constellation** pillar of Skotiq 5.0: a self-hostable, multi-tenant
community service that fuses **additive sky-atlas tile contributions** from many
imagers into shared, deeper stacks.

It is the natural extension of the keystone's core property. Skotiq's
integrated master proves that a per-pixel weighted mean decomposes into six
running sums (`sum_w`, `sum_w2`, `sum_wx`, `sum_wx2`, `coverage`, `rejected`)
that are **exactly additive across disjoint batches**. The keystone lifts that to
HEALPix tiles (`sky_atlas.rs`); this hub lifts it to *people*: if your tile sums
and my tile sums live on the same grid, `merged = mine + yours` is the correct
deeper stack — computed without re-reading a single sub. The hub is where those
sums meet.

The hub is **pure Dart**. It runs anywhere a Dart runtime and the system
`libsqlite3` do, with no Flutter and no cloud lock-in. There is no proprietary
backend: anyone can run their own hub for an imaging club, a dark-sky site, or
the whole community.

## What it does

- **Identity & auth.** Token-based accounts with PBKDF2-HMAC-SHA256 password
  hashing and SHA-256 server identity (the same crypto discipline as
  `skotiq_remote_protocol`). Bearer tokens carry `read` / `contribute` /
  `admin` scopes. Only token *hashes* are ever stored.
- **Shared, cone-addressable targets.** The swarm converges on one shared stack
  per object instead of fragmenting.
- **Server-side fusion.** Contributors upload their serialized `.nst` tile delta
  (the keystone's additive accumulator bytes). The hub fuses them with the
  **same additive co-add** the keystone uses — re-implemented in pure Dart and
  bit-compatible with the `NST1` format for `clip == None`.
- **Trust & robust rejection.** Each contributor carries a reputation/trust
  weight (earned from historical residuals + acceptance ratio). Trust scales a
  contributor's weighted sums in the merge, and a robust per-tile sigma gate
  rejects gross outliers outright — so **one bad contributor cannot poison a
  shared stack**.
- **Exact retraction.** Because the running sums are linear, a contribution can
  be subtracted out exactly, returning the tile to the depth it had before.
- **Follow-the-night.** A scheduler endpoint returns which shared targets are
  dark for a contributor right now and most in need of photons, plus an
  exclusive per-target handoff claim so the swarm hands a target west across the
  globe as it sets.
- **Operational discipline.** Structured JSON error envelope, per-identity rate
  limiting, and an append-only audit log — mirroring
  `apps/desktop/lib/headless_api_server.dart`.

## Running it

### From source

```sh
cd server/skotiq_hub
dart pub get
dart run bin/server.dart --secret "$(openssl rand -hex 32)" \
  --db ./hub.db --atlas-root ./atlas --port 8088
```

On first start the hub mints a bootstrap **admin** account derived from the
server secret and prints how to log in. If you omit `--secret`, a persistent
random secret is generated next to the database (`hub.db.secret`) so the
fingerprint and admin login survive restarts.

### Docker

```sh
docker build -t skotiq-hub server/skotiq_hub
docker run -d --name skotiq-hub -p 8088:8088 \
  -e SKOTIQ_HUB_SECRET=change-me \
  -v skotiq-hub-state:/data skotiq-hub
```

State (the sqlite DB and the fused tile sidecars) lives under `/data`.

## Configuration

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--port` | `SKOTIQ_HUB_PORT` | `8088` | Listen port |
| `--bind` | `SKOTIQ_HUB_BIND` | `0.0.0.0` | Bind address |
| `--db` | `SKOTIQ_HUB_DB` | `/data/hub.db` | sqlite file (`:memory:` for tests) |
| `--atlas-root` | `SKOTIQ_HUB_ATLAS_ROOT` | `/data/atlas` | Fused tile sidecar store |
| `--secret` | `SKOTIQ_HUB_SECRET` | generated | Fingerprint + admin bootstrap secret |
| `--name` | `SKOTIQ_HUB_NAME` | "Skotiq Constellation Hub" | Hub name in `/v1/info` |
| `--closed-signup` | `SKOTIQ_HUB_CLOSED_SIGNUP` | `false` | Require admin to create accounts |

## REST API (base path `/v1`)

All bodies are JSON except tile blobs (binary `application/octet-stream`, the
`.nst` payload). Errors use `{ "error": { "code", "message" }, "requestId" }`.

```
GET    /v1/info
POST   /v1/accounts                 { publicKey, displayName, password? }
POST   /v1/sessions                 { publicKey, password }            (login)
GET    /v1/tiles/{tileId}?order=9&finalized=true        [read]
POST   /v1/tiles/{tileId}/contributions?order=9         [contribute]  (binary .nst)
DELETE /v1/contributions/{contributionId}               [contribute]  (retract)
POST   /v1/targets                  { name, centerRaDeg, centerDecDeg, radiusDeg, priority? }
GET    /v1/follow-the-night?latitudeDeg=&longitudeDeg=&minAltitudeDeg=   [contribute]
GET    /v1/handoff/{targetId}                            [contribute]
POST   /v1/handoff/{targetId}/claim                      [contribute]
POST   /v1/handoff/{targetId}/release                    [contribute]
GET    /v1/audit                                         [admin]
```

A geometry/order/channel mismatch between an upload and the addressed tile is a
`409 Conflict` (the federation grid is non-negotiable). Contribution uploads
return `{ contributionId, accepted, trustApplied, totalFramesAfter,
integrationSecondsAfter, contributorsAfter, quality }`.

## How fusion stays correct

The hub never trusts a contributor's claimed pixels blindly:

1. **Geometry gate.** The uploaded `.nst` must address the same tile id, order,
   and channel count as the shared tile, or the merge is refused (409).
2. **Robust outlier gate.** The contribution's finalized mean is compared,
   over the overlapping covered pixels, to the existing stack via a median/MAD
   sigma test. A gross outlier is rejected and recorded, never folded in.
3. **Trust weighting.** An accepted contribution's weighted sums are scaled by
   the contributor's trust before being added, so a low-reputation contributor
   moves the shared mean less.
4. **Additive merge.** The four weighted sums are added (trust-scaled), the
   coverage/rejection tallies are added, and provenance is unioned — exactly the
   keystone's `merge_tiles`. With `clip == None` this is bit-for-bit identical to
   having folded both contributors' frames into one accumulator, which the test
   suite asserts (`fusion_service_test.dart`, `hub_server_test.dart`).

## Testing

```sh
cd server/skotiq_hub
dart pub get
dart analyze
dart test
```

The integration tests upload two contributions through the full shelf stack and
assert the fused result equals the local co-add of both, plus exact retraction,
outlier rejection, auth scoping, follow-the-night ranking, and exclusive
handoff.
