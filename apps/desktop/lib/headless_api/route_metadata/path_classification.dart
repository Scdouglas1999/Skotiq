/// Path classification: rate-limit tier, audit action, auth scope and
/// resource key for a given (method, path).
library;

import 'rate_limiting.dart';
import 'route_tables.dart';

EndpointRateLimit? endpointRateLimitFor({
  required String method,
  required String path,
}) {
  final normalizedMethod = method.toUpperCase();
  if (!rateLimitedMethods.contains(normalizedMethod) &&
      !rateLimitedReadPaths.contains(path)) {
    return null;
  }

  if (highRiskControlPaths.contains(path) ||
      _isMosaicPanelUploadPath(path) ||
      _isMosaicAssemblePath(path) ||
      _isMosaicForceReleasePath(path) ||
      _isMosaicOutputDownloadPath(path) ||
      _isCoImagingContributePath(path)) {
    return const EndpointRateLimit(
      maxRequests: highRiskControlRateLimitMaxRequests,
      window: defaultControlRateLimitWindow,
    );
  }

  if (controlPathPrefixes.any(path.startsWith) ||
      rateLimitedReadPaths.contains(path) ||
      rateLimitedPairingPaths.contains(path)) {
    return const EndpointRateLimit(
      maxRequests: defaultControlRateLimitMaxRequests,
      window: defaultControlRateLimitWindow,
    );
  }

  return null;
}

String? highRiskAuditActionFor({required String method, required String path}) {
  if (method.toUpperCase() == 'GET' && path == '/api/files/browse') {
    return 'file_browse';
  }

  // log-file downloads are audited so an operator can trace
  // who pulled a log archive after an incident. Treated like
  // `/api/files/browse`: read-only but sensitive enough to warrant
  // an audit row. The route uses a `<filename>` parameter so we
  // normalise the path before lookup.
  if (method.toUpperCase() == 'GET') {
    if (_isLogDownloadPath(path)) {
      return 'log_download';
    }
    // The darkroom peer-delivery artifact route streams a published master off
    // the appliance, so it is audited for the same reason as the mosaic output
    // download below: an operator can trace who pulled the night's masters
    // after an incident.
    if (_isDeliveryArtifactPath(path)) {
      return 'darkroom_artifact_download';
    }
  }

  // DELETE /api/system/update/staged is destructive but uses the
  // DELETE method. The remaining update audit actions live in
  // `highRiskAuditActions` below and are matched via the POST branch.
  if (method.toUpperCase() == 'DELETE' && path == '/api/system/update/staged') {
    return 'update_discard_staged';
  }

  // every DELETE on the calibration surface is destructive and
  // worth auditing. The parameterised path (`/api/calibration/darks/123`)
  // is matched here on both the templated and instantiated forms; the
  // templated path appears in the route enumeration list while the
  // instantiated path appears at request time.
  if (method.toUpperCase() == 'DELETE') {
    if (_isCalibrationDarkPath(path)) return 'calibration_dark_delete';
    if (_isCalibrationFlatPath(path)) return 'calibration_flat_delete';
    if (_isCalibrationDefectMapPath(path)) {
      return 'calibration_defect_map_delete';
    }
    // DELETE /api/catalog/<name> removes a star/DSO catalog
    // from disk. Plate solving stops working until the catalog is
    // re-downloaded, so this is destructive enough to audit.
    if (_isCatalogNamedPath(path)) return 'catalog_delete';
  }

  if (method.toUpperCase() != 'POST') {
    return null;
  }

  // per-row thumbnail regeneration. Templated path is
  // `/api/images/<imageId>/regenerate-thumbnail`; instantiated paths
  // carry a numeric id. Audited (but not in the high-risk rate tier)
  // because it does a one-shot FFI re-encode per call.
  if (_isRegenerateThumbnailPath(path)) {
    return 'image_regenerate_thumbnail';
  }

  // collaborative-mosaic data egress + heavy compute. The panel upload
  // ships a full-resolution master off the device to a remote hub, and
  // assemble kicks off a native gnomonic stitch — both warrant an audit
  // row recording who triggered them. The project id / panel index are
  // parameterised so they are matched via the path helpers rather than the
  // concrete `highRiskAuditActions` table.
  if (_isMosaicPanelUploadPath(path)) {
    return 'mosaic_panel_upload';
  }
  if (_isMosaicAssemblePath(path)) {
    return 'mosaic_assemble';
  }
  if (_isMosaicForceReleasePath(path)) {
    return 'mosaic_force_release';
  }
  // the finished-mosaic download pulls hub-served bytes and writes them to the
  // appliance filesystem, so it is audited (an operator can trace who pulled a
  // mosaic output after an incident) and throttled in the high-risk tier.
  if (_isMosaicOutputDownloadPath(path)) {
    return 'mosaic_output_download';
  }

  // live co-imaging data egress: sub-complete + contribute fold this rig's
  // additive sums off-device to a remote hub (and sub-complete also drives heavy
  // native fusion), so both are audited — an operator can trace which co-imaging
  // contributions left the appliance after an incident — and throttled in the
  // high-risk tier.
  if (_isCoImagingContributePath(path)) {
    return 'coimaging_sub_contribute';
  }

  return highRiskAuditActions[path];
}

/// matches the parameterised
/// `/api/images/<imageId>/regenerate-thumbnail` route and its concrete
/// request paths (`/api/images/42/regenerate-thumbnail`). Both the
/// templated form (route-enumeration list) and the instantiated form
/// (request-time) are accepted.
bool _isRegenerateThumbnailPath(String path) {
  if (path == '/api/images/<imageId>/regenerate-thumbnail') return true;
  if (!path.startsWith('/api/images/')) return false;
  return path.endsWith('/regenerate-thumbnail');
}

/// matches the parameterised
/// `/api/darkroom/delivery/artifact/<jobId>/<artifactId>` route and its
/// concrete request paths (`/api/darkroom/delivery/artifact/7/abc123`). Both
/// the templated form (route-enumeration list) and the instantiated form
/// (request-time) are accepted. The two trailing segments are required, so the
/// sibling `manifest/` and `ack/` routes do not match.
bool _isDeliveryArtifactPath(String path) {
  const prefix = '/api/darkroom/delivery/artifact/';
  if (!path.startsWith(prefix)) return false;
  final tail = path.substring(prefix.length);
  final segments = tail.split('/');
  return segments.length == 2 &&
      segments.every((segment) => segment.isNotEmpty);
}

/// matches the parameterised `/api/logs/files/<filename>/download`
/// route and its concrete request paths (`/api/logs/files/skotiq.log/
/// download`). We accept both the templated form (used by the
/// route-enumeration list) and the instantiated form (used at request
/// time).
bool _isLogDownloadPath(String path) {
  if (path == '/api/logs/files/<filename>/download') return true;
  if (!path.startsWith('/api/logs/files/')) return false;
  return path.endsWith('/download');
}

/// matches `/api/calibration/darks/<id>` (and the templated
/// `<id>` form used in the route enumeration). Used by the DELETE audit
/// branch. Returns false for the collection root `/api/calibration/darks`
/// because DELETE there is not a valid route.
bool _isCalibrationDarkPath(String path) {
  if (path == '/api/calibration/darks/<id>') return true;
  if (!path.startsWith('/api/calibration/darks/')) return false;
  final tail = path.substring('/api/calibration/darks/'.length);
  // Reject sub-resources like `/upload` or `/find-match`.
  return !tail.contains('/');
}

bool _isCalibrationFlatPath(String path) {
  if (path == '/api/calibration/flats/<id>') return true;
  if (!path.startsWith('/api/calibration/flats/')) return false;
  final tail = path.substring('/api/calibration/flats/'.length);
  return !tail.contains('/');
}

bool _isCalibrationDefectMapPath(String path) {
  if (path == '/api/calibration/defect-maps/<id>') return true;
  if (!path.startsWith('/api/calibration/defect-maps/')) return false;
  final tail = path.substring('/api/calibration/defect-maps/'.length);
  return !tail.contains('/');
}

/// matches `/api/catalog/<name>` (and the templated `<name>`
/// form used in the route enumeration). Used by the DELETE audit and
/// admin-scope branches. Excludes the sibling `status` / `available` /
/// `download` / `upload` / `verify` / `reload` paths because those are
/// concrete and live in their own tables.
bool _isCatalogNamedPath(String path) {
  if (path == '/api/catalog/<name>') return true;
  if (!path.startsWith('/api/catalog/')) return false;
  final tail = path.substring('/api/catalog/'.length);
  if (tail.contains('/')) return false;
  const concreteEndpoints = {
    'status',
    'available',
    'download',
    'upload',
    'verify',
    'reload',
  };
  return !concreteEndpoints.contains(tail);
}

/// matches the parameterised
/// `/api/mosaic/projects/<projectId>/panels/<panelIndex>/upload` route and
/// its concrete request paths
/// (`/api/mosaic/projects/7/panels/3/upload`). This ships a full-resolution
/// integrated panel master off the device to a remote third-party hub, so it
/// is audited (data egress) and throttled in the high-risk tier. We accept
/// both the templated form (route-enumeration list) and the instantiated form
/// (request time).
bool _isMosaicPanelUploadPath(String path) {
  if (path == '/api/mosaic/projects/<projectId>/panels/<panelIndex>/upload') {
    return true;
  }
  if (!path.startsWith('/api/mosaic/projects/')) return false;
  return path.contains('/panels/') && path.endsWith('/upload');
}

/// matches the parameterised `/api/mosaic/projects/<projectId>/assemble`
/// route and its concrete request paths (`/api/mosaic/projects/7/assemble`).
/// Assemble kicks off a heavy native gnomonic stitch over every panel master,
/// so it is audited and throttled in the high-risk tier to deny a CPU-
/// exhaustion DoS. Accepts both the templated and instantiated forms.
bool _isMosaicAssemblePath(String path) {
  if (path == '/api/mosaic/projects/<projectId>/assemble') return true;
  if (!path.startsWith('/api/mosaic/projects/')) return false;
  return path.endsWith('/assemble');
}

/// matches the parameterised `/api/mosaic/projects/<projectId>/output` route
/// and its concrete request paths (`/api/mosaic/projects/7/output`). The
/// download pulls the finished mosaic FITS from the hub and writes it to the
/// appliance, so it is audited (egress + disk write) and throttled in the
/// high-risk tier. Accepts both the templated and instantiated forms.
bool _isMosaicOutputDownloadPath(String path) {
  if (path == '/api/mosaic/projects/<projectId>/output') return true;
  if (!path.startsWith('/api/mosaic/projects/')) return false;
  return path.endsWith('/output');
}

/// matches the parameterised
/// `/api/mosaic/projects/<projectId>/panels/<panelIndex>/force-release` route
/// and its concrete request paths
/// (`/api/mosaic/projects/7/panels/3/force-release`). Owner/admin eviction of a
/// squatting claim or a poisoned upload is a destructive recovery action, so it
/// is audited (who evicted which panel) and throttled in the high-risk tier
/// alongside assemble. Accepts both the templated and instantiated forms.
bool _isMosaicForceReleasePath(String path) {
  if (path ==
      '/api/mosaic/projects/<projectId>/panels/<panelIndex>/force-release') {
    return true;
  }
  if (!path.startsWith('/api/mosaic/projects/')) return false;
  return path.contains('/panels/') && path.endsWith('/force-release');
}

/// matches the parameterised live co-imaging data-egress endpoints
/// `/api/coimaging/sessions/<sessionId>/sub-complete` and
/// `/api/coimaging/sessions/<sessionId>/contribute` (and their concrete request
/// paths, e.g. `/api/coimaging/sessions/abc123/sub-complete`). Both fold this
/// rig's additive sums off the device to a remote hub — sub-complete also drives
/// heavy native fusion — so they are audited (egress) and throttled in the
/// high-risk tier to bound an unattended contribute loop. Accepts both the
/// templated form (route-enumeration list) and the instantiated form (request
/// time).
bool _isCoImagingContributePath(String path) {
  if (path == '/api/coimaging/sessions/<sessionId>/sub-complete' ||
      path == '/api/coimaging/sessions/<sessionId>/contribute') {
    return true;
  }
  if (!path.startsWith('/api/coimaging/sessions/')) return false;
  return path.endsWith('/sub-complete') || path.endsWith('/contribute');
}

/// Whether [path] is in the high-risk control allow-list (used by CORS
/// policy and rate-limit tier selection). Why exposed: the CORS middleware
/// needs to apply a stricter origin allow-list rule for these endpoints.
bool isHighRiskControlPath(String path) {
  return highRiskControlPaths.contains(path) ||
      _isMosaicPanelUploadPath(path) ||
      _isMosaicAssemblePath(path) ||
      _isMosaicForceReleasePath(path) ||
      _isMosaicOutputDownloadPath(path) ||
      _isCoImagingContributePath(path);
}

bool isPublicEndpoint({required String method, required String path}) {
  final normalizedMethod = method.toUpperCase();
  final normalizedPath = _normalizePath(path);
  return normalizedMethod == 'GET' && normalizedPath == '/api/info';
}

String requiredAuthScopeNameForEndpoint({
  required String method,
  required String path,
}) {
  final normalizedMethod = method.toUpperCase();
  final normalizedPath = _normalizePath(path);

  if (isPublicEndpoint(method: normalizedMethod, path: normalizedPath)) {
    return 'public';
  }

  // `/api/pairing/active` lists active pairing-session codes, which
  // are credentials in transit. Admin-only across every method so a paired
  // control-scope phone cannot read freshly-minted codes the operator is
  // sharing out-of-band.
  if (pairingActivePaths.contains(normalizedPath)) {
    return 'admin';
  }

  // Host settings. Paired controllers MIRROR these by design — the
  // guiding screen reads settle/dither defaults, the phone-side sequence
  // serializer bakes the host's dither/AF/meridian defaults, and the
  // slave sync re-pulls the snapshot every 30s. Blanket-admin (via
  // `adminOnlyPathPrefixes`) breaks all of that for every default-scope
  // pairing: the phone shows "Guiding defaults unavailable: Access denied"
  // and silently serializes fallback defaults into sequences it starts.
  // Reading host settings is a CONTROL-level capability, not a view-level
  // one, and the payload is why: `exportRemoteSettings()` carries the
  // operator's Discord webhook URL, their Pushover key and user, the update
  // server URL, and absolute host filesystem paths (image output, ASTAP,
  // reject folder). A webhook URL is a bearer credential in its own right, so
  // a read-only viewer — the phone by the bed, a shared run-watch link — has
  // no business reading this. Control is the floor, not the ceiling: every
  // mutation stays admin, and the Home Assistant sub-route carries a bearer
  // token and stays admin for ALL methods.
  //
  // A view-scope client that asks anyway gets the standard scope refusal
  // naming `settings`-behind-`system:control`, and the dashboard states it in
  // the panel rather than painting the values as unknown.
  if (normalizedPath.startsWith('/api/settings')) {
    if (normalizedPath.startsWith('/api/settings/home-assistant')) {
      return 'admin';
    }
    return normalizedMethod == 'GET' ? 'control' : 'admin';
  }

  // Darkroom peer delivery. All three routes are CONTROL, GETs included.
  //
  // The method default would make the two GETs view scope, and what they serve
  // is why that is wrong: the manifest lists every master this job published
  // for a peer with its size and SHA-256, and the artifact route streams those
  // masters byte-for-byte with Range resume. That is the night's output
  // leaving the appliance. A read-only credential — the phone by the bed, a
  // shared run-watch link — has no business pulling it, on exactly the
  // principle that made GET /api/settings control scope above.
  //
  // Control is the floor, not the ceiling: collecting a night is what a paired
  // desktop does with a control credential, so this does not require admin.
  if (normalizedPath.startsWith('/api/darkroom/delivery/')) {
    return 'control';
  }

  if (adminOnlyPathPrefixes.any(normalizedPath.startsWith) ||
      adminOnlyPaths.contains(normalizedPath)) {
    return 'admin';
  }

  // DELETE /api/system/update/staged (destructive — wipes staging
  // tree). All non-GET methods on the update surface are admin so a
  // control-scope token cannot, for example, DELETE the staged update
  // a paired admin operator queued for installation.
  if (normalizedPath.startsWith('/api/system/update/') &&
      normalizedMethod != 'GET') {
    return 'admin';
  }

  // calibration library scope.
  //
  //   GET   /api/calibration/...                  → view
  //   POST  /api/calibration/darks/upload          → admin (file upload)
  //   POST  /api/calibration/darks/backfill-sizes  → admin (mutating sweep)
  //   POST  /api/calibration/darks/{maintenance}   → admin (files/heavy I/O)
  //   POST  /api/calibration/.../* (others)        → control
  //   DELETE /api/calibration/...                  → admin (destructive)
  if (normalizedPath.startsWith('/api/calibration/')) {
    if (normalizedMethod == 'GET') {
      return 'view';
    }
    if (normalizedMethod == 'DELETE') {
      return 'admin';
    }
    if (normalizedMethod == 'POST') {
      if (normalizedPath == '/api/calibration/darks/upload' ||
          normalizedPath == '/api/calibration/darks/backfill-sizes' ||
          normalizedPath == '/api/calibration/darks/create-master' ||
          normalizedPath == '/api/calibration/darks/clean-orphans' ||
          normalizedPath == '/api/calibration/darks/clear' ||
          normalizedPath == '/api/calibration/darks/delete-group') {
        return 'admin';
      }
      return 'control';
    }
    // Fall through to default control for any other mutating method.
  }

  // v46: unified Calibration Library Manager scope. Mirrors the per-table
  // calibration surface above, but the prefix is hyphenated so it does NOT
  // match the `/api/calibration/` block.
  //
  //   GET    /api/calibration-library            → view (list)
  //   POST   /api/calibration-library/match      → control (read-only preview)
  //   PUT    /api/calibration-library/.../tags   → control (annotate)
  //   DELETE /api/calibration-library/...        → admin (destructive)
  if (normalizedPath == '/api/calibration-library' ||
      normalizedPath.startsWith('/api/calibration-library/')) {
    if (normalizedMethod == 'GET') {
      return 'view';
    }
    if (normalizedMethod == 'DELETE') {
      return 'admin';
    }
    return 'control';
  }

  // catalog management scope.
  //
  //   GET    /api/catalog/status        → view
  //   GET    /api/catalog/available     → view
  //   POST   /api/catalog/download      → admin (already in adminOnlyPaths)
  //   POST   /api/catalog/upload        → admin
  //   POST   /api/catalog/verify        → admin
  //   POST   /api/catalog/reload        → admin
  //   DELETE /api/catalog/<name>        → admin
  //
  // The named DELETE is parameterised so the `adminOnlyPaths` set
  // can't cover it; we resolve it via the path matcher here.
  if (normalizedPath.startsWith('/api/catalog/')) {
    if (normalizedMethod == 'DELETE' && _isCatalogNamedPath(normalizedPath)) {
      return 'admin';
    }
    // Concrete admin-only POSTs are caught by the `adminOnlyPaths`
    // check above. GET status/available falls through to view.
  }

  final auditAction = highRiskAuditActionFor(
    method: normalizedMethod,
    path: normalizedPath,
  );
  if (auditAction == 'file_browse' ||
      auditAction?.startsWith('backup_') == true) {
    return 'admin';
  }

  if (normalizedMethod == 'GET' || normalizedMethod == 'WS') {
    return 'view';
  }

  return 'control';
}

/// Resource axis (string key) the fine-grained auth grant model tags an
/// endpoint with. Returns the canonical resource name (see
/// `headlessResourceName` in auth_policy.dart) so the policy layer can resolve
/// it to a `HeadlessResource` without route_metadata depending on auth_policy.
///
/// Coarse `view`/`control` tokens cover EVERY resource, so this tagging only
/// changes behaviour for fine-grained tokens. Anything unmapped falls back to
/// `system`, which a fine-grained token must hold explicitly — fail closed.
String resourceKeyForEndpoint({required String method, required String path}) {
  final normalizedPath = _normalizePath(path);

  // Info / status surface (public + read-only system probes).
  if (normalizedPath == '/api/info' ||
      normalizedPath == '/api/status' ||
      normalizedPath == '/api/openapi.json') {
    return 'info';
  }

  for (final entry in resourcePrefixKeys.entries) {
    if (normalizedPath.startsWith(entry.key)) {
      return entry.value;
    }
  }

  // Calibration library (hyphenated) shares the calibration resource but does
  // not match the `/api/calibration/` prefix above.
  if (normalizedPath == '/api/calibration-library' ||
      normalizedPath.startsWith('/api/calibration-library/')) {
    return 'calibration';
  }

  return 'system';
}

String _normalizePath(String path) {
  if (path.startsWith('/')) {
    return path;
  }
  return '/$path';
}
