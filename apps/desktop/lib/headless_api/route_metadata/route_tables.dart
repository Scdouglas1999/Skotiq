/// Const path tables shared by the endpoint classifiers in
/// `path_classification.dart`.
///
/// Deliberately NOT re-exported from `route_metadata.dart`: they are data for
/// the matchers, not part of the route-metadata surface.
library;

/// Ordered prefix → resource-key table for [resourceKeyForEndpoint]. Order
/// matters only where one prefix is a prefix of another; none here are, but the
/// map is iterated in insertion order for determinism.
const Map<String, String> resourcePrefixKeys = {
  '/api/devices/': 'devices',
  '/api/camera/': 'camera',
  '/api/mount/': 'mount',
  '/api/focuser/': 'focuser',
  '/api/filter-wheel/': 'filter-wheel',
  '/api/rotator/': 'rotator',
  '/api/dome/': 'dome',
  '/api/cover/': 'cover',
  '/api/phd2/': 'guiding',
  '/api/guider/': 'guiding',
  '/api/builtin-guider/': 'guiding',
  '/api/guiding/': 'guiding',
  '/api/safety/': 'safety',
  '/api/weather/': 'safety',
  '/api/switch/': 'switch',
  '/api/sequencer/': 'sequencer',
  // DepthLock goals are what a Smart Exposure plan binds to, and the
  // sequencer is what consumes the verdict, so a token trusted to run
  // sequences is exactly the token that may edit the goals it runs against.
  // Without this entry the surface fell through to the `system` catch-all,
  // which would have made a goal edit need an admin-adjacent grant.
  '/api/depthlock/': 'sequencer',
  '/api/framing/': 'framing',
  '/api/calibration/': 'calibration',
  // Collaborative Sky (6.0) routes. Without these entries
  // `/api/mosaic/collaborative/*` and `/api/coimaging/sessions/*` fell through
  // to the `system` catch-all, so a fine-grained token needed `system` (admin-
  // adjacent) to use them and any `system` grant silently gained collaborative
  // access. Tag them with their own resource so a fine-grained token scopes to
  // the collaborative surface, not system administration.
  '/api/mosaic/': 'mosaic',
  '/api/coimaging/': 'coimaging',
  '/api/constellation/': 'constellation',
  // The live collaboration surface (shared-viewer join/leave, broadcast
  // preview, in-session chat + annotations) is a collaborative resource too,
  // so it carries `constellation` and a fine-grained token does not need
  // `system` to run a shared viewing session. (`/api/session-handoff` is
  // deliberately NOT here: it transfers session ownership and stays admin-only
  // via `adminOnlyPaths`, where the resource is irrelevant.)
  '/api/collaboration/': 'constellation',
  // Darkroom peer delivery (7.0). The manifest/artifact/ack surface a paired
  // desktop pulls the night through. Without this entry the three routes fell
  // through to the `system` catch-all.
  '/api/darkroom/': 'darkroom',
  '/api/catalog/': 'catalog',
  '/api/files/': 'filesystem',
  '/api/backup/': 'backup',
  '/api/sync/': 'backup',
  '/api/settings/': 'settings',
  '/api/plugins/': 'plugins',
  '/api/system/': 'system',
};

const rateLimitedMethods = {'POST', 'PUT', 'PATCH', 'DELETE'};

const adminOnlyPathPrefixes = {
  '/api/backup',
  // Cloud sync — POST /api/sync/push uploads the entire configuration
  // bundle off-box, so mutating sync calls are admin-only like backup.
  '/api/sync',
  '/api/files',
  // NOTE: /api/settings is handled explicitly above the prefix check —
  // GET is control-scope (paired controllers mirror host settings by
  // design); mutations and the token-bearing home-assistant sub-route
  // stay admin.
  // plugin management. List (GET /api/plugins) is admin-scope
  // because it exposes installed-plugin metadata that a paired control
  // phone shouldn't see; every mutating method is destructive by design
  // (upload installs code-adjacent assets, delete drops the archive).
  '/api/plugins',
};

const adminOnlyPaths = {
  '/api/self-test',
  '/api/session-handoff',
  // destructive / synthetic log operations. Reading is view
  // scope; mutating is admin only.
  '/api/logs/clear',
  '/api/logs/test-entry',
  // sidecar thumbnail backfill walks every captured-image row
  // and invokes the Rust FFI per missing sidecar. On Pi-class SD storage
  // this can run for several minutes and produce significant I/O — admin
  // scope so a paired control-phone can't accidentally kick off a
  // session-wide rebuild during live capture.
  '/api/images/backfill-thumbnails',
  // OTA update mutating endpoints. The two GET endpoints
  // (`/api/system/version`, `/api/system/update/status`,
  // `/api/system/update/staged`) stay at view scope so a paired phone
  // operator can monitor without being able to trigger a download.
  '/api/system/update/check',
  '/api/system/update/download',
  '/api/system/update/apply',
  '/api/system/update/abort',
  '/api/system/update/rollback',
  // catalog mutating endpoints. Status + available stay at view
  // scope so a paired control phone can render a "catalogs missing"
  // banner; everything that changes state is admin-only.
  '/api/catalog/download',
  '/api/catalog/upload',
  '/api/catalog/verify',
  '/api/catalog/reload',
};

/// pairing-session diagnostic endpoint(s). Admin-only across every
/// method because the response body contains live pairing codes that the
/// operator may be sharing out of band. Keeping the table separate from
/// `adminOnlyPaths` makes it explicit that this set covers GETs too,
/// whereas `adminOnlyPaths` only escalates mutating methods.
const pairingActivePaths = {'/api/pairing/active'};

const controlPathPrefixes = [
  '/api/devices/',
  '/api/camera/',
  '/api/mount/',
  '/api/focuser/',
  '/api/filter-wheel/',
  '/api/rotator/',
  '/api/phd2/',
  '/api/guider/',
  '/api/builtin-guider/',
  '/api/sequencer/',
  '/api/framing/',
  '/api/dome/',
  '/api/safety/',
  '/api/switch/',
  '/api/cover/',
  '/api/backup/',
  '/api/files/',
  // system / OTA update endpoints. Most do nothing destructive
  // on their own but the underlying work is heavy (HTTP fetch, file
  // staging) so we rate-limit them like the rest of the control surface.
  '/api/system/',
  // calibration library mutating endpoints. Rate-limited like
  // the rest of the control surface so a runaway client cannot pummel
  // the DB with delete loops or upload-and-delete cycles.
  '/api/calibration/',
  // unified Calibration Library Manager mutating endpoints (match /
  // accept / publish / retract / tags / delete). The prefix is hyphenated
  // so it does NOT match `/api/calibration/` above; enroll it here so the
  // write surface (including the off-device publish) gets the same
  // per-endpoint window as its per-table counterpart.
  '/api/calibration-library/',
  // collaborative-mosaic mutating endpoints (publish / join / claim /
  // upload / assemble / output). Rate-limited like the rest of the
  // control surface so a `mosaic:control` token cannot hammer the
  // distributed flow. The data-egress panel upload and heavy-compute
  // assemble are escalated to the high-risk tier in `endpointRateLimitFor`
  // via the parameterised matchers below.
  '/api/mosaic/',
  // live co-imaging + the underlying Constellation swarm mutating
  // endpoints (create / join / leave / close / contribute / sub-complete /
  // baton). Rate-limited like the rest of the control surface so an unattended
  // rig's contribute/baton loop is bounded. The data-egress sub-complete +
  // contribute calls (which fold off-device additive sums to a remote hub and
  // drive heavy native fusion) are escalated to the high-risk tier in
  // `endpointRateLimitFor` via `_isCoImagingContributePath` below.
  '/api/coimaging/',
  '/api/constellation/',
  // live collaboration mutating endpoints (viewer join/leave, broadcast
  // preview, chat, annotations). Rate-limited like the rest of the
  // collaborative control surface so a joined viewer cannot flood chat /
  // preview / annotation posts on an unattended rig.
  '/api/collaboration/',
  // planetarium mount-control mutating endpoints (slew-to / sync-to /
  // center-on). Rate-limited like the rest of the control surface; the
  // three motion endpoints are additionally escalated to the high-risk
  // tier via `highRiskControlPaths`.
  '/api/planetarium/',
  // darkroom peer-delivery acknowledgement. Each ack re-reads and re-hashes
  // the published file to compare the desktop's checksum against the rig's
  // own copy, so an unthrottled ack loop is a disk-and-CPU amplifier on
  // Pi-class hardware.
  '/api/darkroom/',
];

const rateLimitedReadPaths = {'/api/files/browse'};

/// Public pairing endpoints that mint pairing codes / session tokens.
///
/// Unauthenticated by design, so the per-token route-class bucket never
/// applies. Enrolling them here caps them under the legacy endpoint window,
/// keyed off the spoof-proof socket peer, so a flood cannot dilute the 6-digit
/// code space or mint session tokens without bound. The control window is far
/// above any legitimate pairing cadence and reuses the existing 429 envelope.
const rateLimitedPairingPaths = {
  '/api/pairing/start',
  '/api/pairing/verify',
  '/api/pairing/lan-claim',
};

const highRiskControlPaths = {
  '/api/devices/connect',
  '/api/devices/disconnect',
  '/api/mount/slew',
  '/api/mount/slew-alt-az',
  '/api/mount/park',
  '/api/mount/unpark',
  '/api/mount/home',
  '/api/mount/find-home',
  '/api/mount/set-park',
  '/api/framing/slew-to-target',
  '/api/framing/center-on-target',
  '/api/framing/park',
  '/api/framing/unpark',
  // planetarium mount control moves real hardware (slew / sync /
  // iterative center), so it sits in the high-risk tier and is audited
  // like the mount/framing motion endpoints.
  '/api/planetarium/slew-to',
  '/api/planetarium/sync-to',
  '/api/planetarium/center-on',
  '/api/dome/open',
  '/api/dome/close',
  '/api/dome/slew',
  '/api/dome/park',
  '/api/backup/restore',
  '/api/backup/upload-restore',
  '/api/sequencer/start',
  '/api/sequencer/stop',
  '/api/sequencer/resume',
  '/api/sequencer/request-meridian-flip',
  // clear permanently deletes log files, test-entry can be
  // abused as a write amplifier; both belong in the high-risk tier
  // so an aggressive client gets throttled to 12 calls/min.
  '/api/logs/clear',
  '/api/logs/test-entry',
  // OTA update apply / rollback / discard. Apply triggers a
  // server-process restart, rollback is destructive, and a malicious
  // client repeatedly hammering these endpoints could DoS the
  // operator. 12 calls/min is plenty for legitimate use.
  '/api/system/update/apply',
  '/api/system/update/rollback',
  '/api/system/update/staged',
  // calibration uploads and the on-disk verifier are destructive
  // / I/O-heavy. The fine-grained DELETE paths are handled via the
  // calibration DELETE branch in `highRiskAuditActionFor` rather than
  // being enumerated here, because each id-bearing instance is unique.
  '/api/calibration/darks/upload',
  '/api/calibration/darks/backfill-sizes',
  // Dark-library maintenance can remove rows/files, while create-master runs
  // heavy native I/O and writes to a caller-selected host path.
  '/api/calibration/darks/create-master',
  '/api/calibration/darks/clean-orphans',
  '/api/calibration/darks/clear',
  '/api/calibration/darks/delete-group',
  // sidecar thumbnail backfill: heavy-I/O FFI walk over every
  // captured-image row. 12 calls/min is plenty for legitimate retries.
  '/api/images/backfill-thumbnails',
  // catalog management. Download triggers a multi-MB HTTPS
  // fetch + decompression + atomic rename; verify computes SHA-256
  // over multi-MB files; both are heavy and should be throttled to
  // 12 calls/min so a misbehaving client cannot pummel the upstream
  // mirrors or the SD card.
  '/api/catalog/download',
  '/api/catalog/upload',
  '/api/catalog/verify',
};

const highRiskAuditActions = {
  '/api/devices/connect': 'device_connect',
  '/api/devices/disconnect': 'device_disconnect',
  '/api/mount/slew': 'mount_slew',
  '/api/mount/slew-alt-az': 'mount_slew_alt_az',
  '/api/mount/park': 'mount_park',
  '/api/mount/unpark': 'mount_unpark',
  '/api/mount/home': 'mount_home',
  '/api/mount/find-home': 'mount_home',
  '/api/mount/set-park': 'mount_set_park',
  '/api/framing/slew-to-target': 'framing_slew_to_target',
  '/api/framing/center-on-target': 'framing_center_on_target',
  '/api/framing/park': 'framing_park',
  '/api/framing/unpark': 'framing_unpark',
  '/api/planetarium/slew-to': 'planetarium_slew_to',
  '/api/planetarium/sync-to': 'planetarium_sync_to',
  '/api/planetarium/center-on': 'planetarium_center_on',
  '/api/dome/open': 'dome_open',
  '/api/dome/close': 'dome_close',
  '/api/dome/slew': 'dome_slew',
  '/api/dome/park': 'dome_park',
  '/api/backup/restore': 'backup_restore',
  '/api/backup/upload-restore': 'backup_upload_restore',
  '/api/sequencer/start': 'sequence_start',
  '/api/sequencer/stop': 'sequence_stop',
  '/api/sequencer/resume': 'sequence_resume',
  '/api/sequencer/request-meridian-flip': 'sequence_request_meridian_flip',
  // destructive log operations. Audit row records who and
  // when, status comes from the response code in the middleware.
  '/api/logs/clear': 'log_clear',
  '/api/logs/test-entry': 'log_test_entry',
  // OTA update audit trail. `update_discard_staged` is matched
  // via the DELETE branch above; the rest are POST.
  '/api/system/update/download': 'update_download',
  '/api/system/update/apply': 'update_apply',
  '/api/system/update/rollback': 'update_rollback',
  // calibration mutating endpoints. `calibration_dark_delete` and
  // friends are matched via the DELETE branch in highRiskAuditActionFor
  // because the id is parameterised. The POST paths are concrete and live
  // in this table.
  '/api/calibration/darks/upload': 'calibration_dark_upload',
  '/api/calibration/darks/backfill-sizes': 'calibration_backfill',
  '/api/calibration/darks/create-master': 'calibration_dark_create_master',
  '/api/calibration/darks/clean-orphans': 'calibration_dark_clean_orphans',
  '/api/calibration/darks/clear': 'calibration_dark_clear',
  '/api/calibration/darks/delete-group': 'calibration_dark_delete_group',
  // catalog mutating endpoints. The DELETE audit action is
  // resolved via `_isCatalogNamedPath` above because the path is
  // parameterised.
  '/api/catalog/download': 'catalog_download',
  '/api/catalog/upload': 'catalog_upload',
  '/api/catalog/verify': 'catalog_verify',
  // thumbnail-cache mutations. The backfill walks every row +
  // invokes the Rust FFI for each missing sidecar (heavy I/O on Pi SD
  // storage); the regenerate endpoint is a per-row escape hatch when a
  // FITS is replaced out-of-band. The regenerate POST is matched via
  // `_isRegenerateThumbnailPath` because the row id is parameterised.
  '/api/images/backfill-thumbnails': 'image_backfill_thumbnails',
};
