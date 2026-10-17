// Pillar C ("Constellation") — the HTTP client for a Skotiq hub.
//
// A Constellation hub is a self-hosted, LAN-or-internet REST service
// (`server/skotiq_hub/`, contract in `docs/skotiq_5_0_contracts.md`)
// that fuses per-tile additive accumulators from many imagers into a community
// co-add.
// This client speaks that wire contract verbatim: a bearer token carries the
// account's `contribute`/`read` scopes, JSON bodies everywhere except the tile
// blobs (the `.skt` accumulator payload travels as `application/octet-stream`),
// and the `order` query parameter pins the HEALPix tiling so a mismatched hub
// is detected up front.
//
// Transport mirrors `webdav_sync_target.dart`: nothing but `package:http`, a
// single `_send` choke point that maps `SocketException`/`ClientException`/
// timeouts onto a typed [ConstellationException], and a `_throwForStatus` that
// classifies the HTTP status. The client is deliberately stateless beyond its
// base URL + token so one instance can be created per hub from a provider.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException, IOSink, SocketException;

import 'package:http/http.dart' as http;

import 'constellation_models.dart';
part 'constellation_client/transport.dart';
part 'constellation_client/io_cleanup.dart';

/// Thin REST client for one Constellation hub (one account / bearer token).
///
/// Every method maps to a single endpoint in the hub contract. Heavy tile
/// transfers ([pushTile] / [pullTile]) stream the `.skt` blob to/from disk so a
/// deep tile never has to be held in memory twice.
class ConstellationClient {
  /// Hub root, e.g. `https://hub.example.org` or `http://192.168.1.20:8088`.
  /// The `/v1` base path is appended internally.
  final Uri hubBaseUrl;

  /// Account bearer token (scopes `contribute` / `read` / `admin`).
  final String bearerToken;

  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;

  /// [client] is injectable for tests (`package:http/testing.dart` MockClient).
  /// When omitted a real client is created and owned here ([close] disposes it).
  ConstellationClient({
    required this.hubBaseUrl,
    required this.bearerToken,
    http.Client? client,
    Duration timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _timeout = timeout;

  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $bearerToken',
  };

  // Endpoints

  /// `GET /v1/info` — hub identity + tiling. Call before contributing so an
  /// order/tile-size mismatch is caught before any blob leaves the device.
  Future<HubInfo> info() async {
    final response = await _send('GET', _v1('info'));
    if (response.statusCode != 200) _throwForStatus(response, 'Hub info');
    return HubInfo.fromJson(_decodeJson(response, 'Hub info'));
  }

  /// `GET /v1/targets` — the swarm's shared-target listing. The browse payload
  /// is not pinned field-for-field by the contract (it is left to the hub), so
  /// the decoded JSON is returned raw (a `List` or a `{ "targets": [...] }`
  /// envelope) for [ConstellationService] to map into [SharedTarget]s.
  Future<Object?> browseRaw() async {
    final response = await _send('GET', _v1('targets'));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Browse shared targets');
    }
    try {
      return jsonDecode(response.body);
    } on FormatException catch (e) {
      throw ConstellationException(
        'Browse shared targets returned malformed JSON: $e',
        kind: ConstellationErrorKind.protocol,
      );
    }
  }

  /// `POST /v1/accounts` — register an account on a hub that allows open
  /// signup (or admin-gated, in which case the bearer token must carry the
  /// `admin` scope). Returns the new account id + its issued bearer token,
  /// which the caller persists to build a per-hub [ConstellationClient].
  Future<HubAccount> createAccount({
    required String publicKey,
    required String displayName,
  }) async {
    final response = await _send(
      'POST',
      _v1('accounts'),
      headers: {'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(
        jsonEncode({'publicKey': publicKey, 'displayName': displayName}),
      ),
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Create account');
    }
    return HubAccount.fromJson(_decodeJson(response, 'Create account'));
  }

  /// `POST /v1/tokens` — mint a fine-grained scoped token: the "hand a
  /// member a contribute-to-mosaic-42-only token" capability. Capability
  /// attenuation — the hub validates subset-only delegation (this token must
  /// already permit every requested action on the requested resource) and
  /// returns the RAW narrowed token once, which the caller hands to the member.
  ///
  /// [role] is the base scope (`read`/`contribute`/`admin`); [actions] (wire
  /// names) narrows to an allow-list (null ⇒ all the role permits);
  /// [resourceType]/[resourceId] bind it to one collaborative artifact;
  /// [deviceId] binds it to one device; [lifetimeSeconds] expires it.
  Future<MintedToken> mintToken({
    required String role,
    Set<String>? actions,
    String? resourceType,
    String? resourceId,
    String? deviceId,
    int? lifetimeSeconds,
    String? accountId,
  }) async {
    final response = await _send(
      'POST',
      _v1('tokens'),
      headers: {'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(
        jsonEncode(<String, Object?>{
          'role': role,
          if (actions != null) 'actions': actions.toList(growable: false),
          if (resourceType != null) 'resourceType': resourceType,
          if (resourceId != null) 'resourceId': resourceId,
          if (deviceId != null) 'deviceId': deviceId,
          if (lifetimeSeconds != null) 'lifetimeSeconds': lifetimeSeconds,
          if (accountId != null) 'accountId': accountId,
        }),
      ),
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Mint token');
    }
    return MintedToken.fromJson(_decodeJson(response, 'Mint token'));
  }

  /// `POST /v1/targets` — create (or look up by name) a shared target so the
  /// swarm has a field to deepen. Idempotent on the hub side: an existing target
  /// with the same name/centre is returned rather than duplicated. The hub echoes
  /// the new target back in the client-facing browse shape (`targetId`/`raDeg`/…)
  /// under a `target` key, which decodes straight into a [SharedTarget].
  ///
  /// Requires the `contribute` scope (seeding a field is a contribution-class
  /// action on the hub).
  Future<SharedTarget> ensureTarget({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    double priority = 0.5,
  }) async {
    final response = await _send(
      'POST',
      _v1('targets'),
      headers: {'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(
        jsonEncode({
          'name': name,
          'centerRaDeg': centerRaDeg,
          'centerDecDeg': centerDecDeg,
          'radiusDeg': radiusDeg,
          'priority': priority,
        }),
      ),
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Create shared target');
    }
    final body = _decodeJson(response, 'Create shared target');
    final target = body['target'];
    if (target is! Map<String, dynamic>) {
      throw const ConstellationException(
        'Create shared target returned no target object',
        kind: ConstellationErrorKind.protocol,
      );
    }
    return SharedTarget.fromJson(target);
  }

  /// `POST /v1/tiles/{tileId}/contributions?order=…` — upload the additive
  /// `.skt` delta at [deltaPath]. Provenance hints (frame/integration deltas +
  /// instrument fingerprint, *not* PII) ride as headers per the contract.
  Future<ContributionReceipt> pushTile({
    required int tileId,
    required int order,
    required String deltaPath,
    required String license,
    int framesDelta = 0,
    double integrationSecondsDelta = 0,
    double? medianFwhm,
    String? solver,
    String? instrument,
    bool attributionConsent = true,
  }) async {
    final file = File(deltaPath);
    if (!file.existsSync()) {
      throw ConstellationException(
        'Contribution delta not found: $deltaPath',
        kind: ConstellationErrorKind.notFound,
      );
    }
    final bytes = await file.readAsBytes();
    final headers = <String, String>{
      'Content-Type': 'application/octet-stream',
      'framesDelta': '$framesDelta',
      'integrationSecondsDelta': '$integrationSecondsDelta',
      if (medianFwhm != null) 'medianFwhm': '$medianFwhm',
      if (solver != null && solver.isNotEmpty) 'solver': solver,
      if (instrument != null && instrument.isNotEmpty) 'instrument': instrument,
      // Consent: the hub requires a shareable license + records consent
      // before storing any bytes. The license rides as a header so the user's
      // license/credit choice travels with the contribution receipt.
      'license': license,
      'attributionConsent': '$attributionConsent',
    };
    final response = await _send(
      'POST',
      _v1('tiles/$tileId/contributions', {'order': '$order'}),
      headers: headers,
      bodyBytes: bytes,
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Push tile $tileId');
    }
    return ContributionReceipt.fromJson(
      _decodeJson(response, 'Push tile $tileId'),
    );
  }

  /// `GET /v1/tiles/{tileId}?order=…&finalized=…` — download the community
  /// co-add for [tileId] to [outPath]. [finalized] true pulls a rendered FITS;
  /// false pulls the merged `.skt` accumulator (still additive, so it can be
  /// merged locally). Returns [outPath] on success.
  Future<String> pullTile({
    required int tileId,
    required int order,
    required String outPath,
    bool finalized = true,
  }) async {
    final response = await _send(
      'GET',
      _v1('tiles/$tileId', {'order': '$order', 'finalized': '$finalized'}),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Pull tile $tileId');
    }
    final out = File(outPath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(response.bodyBytes, flush: true);
    return outPath;
  }

  /// `DELETE /v1/contributions/{id}` — retract a prior contribution. The hub
  /// subtracts it from the fused tile (exact when no clipping is configured).
  Future<RetractionReceipt> retract(String remoteContributionId) async {
    final response = await _send(
      'DELETE',
      _v1('contributions/$remoteContributionId'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Retract $remoteContributionId');
    }
    return RetractionReceipt.fromJson(
      _decodeJson(response, 'Retract $remoteContributionId'),
    );
  }

  /// `POST /v1/tiles/{tileId}/subframes?order=…` — upload one raw FITS subframe
  /// at [fitsPath], streamed straight from disk. Provenance (capturedImageId,
  /// instrument, exposure) rides as query params. The hub gates this on its
  /// `acceptsRawSubs` flag and returns 405 (→ [ConstellationErrorKind.conflict])
  /// when it does not accept raw subframes, which the service surfaces verbatim.
  Future<SubframeReceipt> pushSubframe({
    required int tileId,
    required int order,
    required String fitsPath,
    required String license,
    int? capturedImageId,
    double? exposureSeconds,
    String? instrument,
    bool attributionConsent = true,
  }) async {
    final file = File(fitsPath);
    if (!file.existsSync()) {
      throw ConstellationException(
        'Subframe not found: $fitsPath',
        kind: ConstellationErrorKind.notFound,
      );
    }
    final response = await _sendFile(
      'POST',
      _v1('tiles/$tileId/subframes', {
        'order': '$order',
        if (capturedImageId != null) 'capturedImageId': '$capturedImageId',
        if (exposureSeconds != null) 'exposureSeconds': '$exposureSeconds',
        if (instrument != null && instrument.isNotEmpty)
          'instrument': instrument,
        // The raw-subframe path is the most privacy-sensitive share, so it
        // too carries the shareable license + the explicit raw-subframe opt-in.
        'license': license,
        'shareRawSubframes': 'true',
        'attributionConsent': '$attributionConsent',
      }),
      file,
      headers: {'Content-Type': 'application/octet-stream'},
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Push subframe for tile $tileId');
    }
    return SubframeReceipt.fromJson(
      _decodeJson(response, 'Push subframe for tile $tileId'),
    );
  }

  /// `DELETE /v1/subframes/{contributionId}` — delete a stored raw subframe.
  /// A raw-sub deletion is a FILE-DELETE on the hub (the frame is removed), not
  /// a clean subtraction from a co-add.
  Future<void> deleteSubframe(String contributionId) async {
    final response = await _send('DELETE', _v1('subframes/$contributionId'));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Delete subframe $contributionId');
    }
  }

  // Follow-the-night handoff

  /// `GET /v1/handoff/{targetId}` — ask whether a shared target is dark and
  /// available for this user right now. Returns null when the hub has no
  /// handoff state for the target (HTTP 404 is treated as "no claim").
  Future<HandoffClaim?> queryHandoff(int targetId) async {
    final response = await _send('GET', _v1('handoff/$targetId'));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Handoff query $targetId');
    }
    return HandoffClaim.fromJson(
      _decodeJson(response, 'Handoff query $targetId'),
    );
  }

  /// `POST /v1/handoff/{targetId}/claim` — take the active-imager baton for a
  /// shared target so the swarm does not double-collect the same sky.
  Future<HandoffClaim?> claimHandoff(int targetId) async {
    final response = await _send('POST', _v1('handoff/$targetId/claim'));
    if (response.statusCode == 404) return null;
    // 409 here means another user holds the baton — surfaced as a conflict so
    // the caller can fall back to the next dark target.
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Handoff claim $targetId');
    }
    return HandoffClaim.fromJson(
      _decodeJson(response, 'Handoff claim $targetId'),
    );
  }

  /// `POST /v1/handoff/{targetId}/release` — hand the baton back when this
  /// user's window on the target closes (set below the horizon / dawn).
  Future<void> releaseHandoff(int targetId) async {
    final response = await _send('POST', _v1('handoff/$targetId/release'));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Handoff release $targetId');
    }
  }

  // Attribution

  /// `GET /v1/attribution?artifactType=&artifactRef=` — the authoritative,
  /// consent-aware contributor-credit list for one finished collaborative
  /// artifact. [artifactType] is `mosaic` | `coimaging` | `tile` | `subframe` |
  /// `calibration`; [artifactRef] is that artifact's id (mosaicId / sessionId /
  /// …). The hub resolves each credit's display name and renders a withheld
  /// contributor as `'Anonymous contributor'`, so the UI credits everyone from
  /// this source rather than reconstructing it from a browse payload. A hub with
  /// no attribution on record returns an empty list (200); a 404 (a hub that
  /// predates this route) is treated the same way.
  Future<ArtifactAttribution> fetchAttribution({
    required String artifactType,
    required String artifactRef,
    int limit = 200,
  }) async {
    final response = await _send(
      'GET',
      _v1('attribution', {
        'artifactType': artifactType,
        'artifactRef': artifactRef,
        'limit': '$limit',
      }),
    );
    if (response.statusCode == 404) {
      return ArtifactAttribution(
        artifactType: artifactType,
        artifactRef: artifactRef,
      );
    }
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Attribution for $artifactType $artifactRef');
    }
    return ArtifactAttribution.fromJson(
      _decodeJson(response, 'Attribution for $artifactType $artifactRef'),
    );
  }

  // Collaborative mosaics

  /// `POST /v1/mosaics` — publish a panel grid as claimable work items. Returns
  /// the created mosaic (with its panel states).
  Future<CollabMosaic> publishMosaic({
    required String name,
    required int rows,
    required int cols,
    required double centerRaDeg,
    required double centerDecDeg,
    required List<({int panelIndex, double centerRaDeg, double centerDecDeg})>
    panels,
    double overlapPct = 15.0,
    double positionAngleDeg = 0.0,
  }) async {
    final response = await _send(
      'POST',
      _v1('mosaics'),
      headers: {'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(
        jsonEncode(<String, Object?>{
          'name': name,
          'rows': rows,
          'cols': cols,
          'overlapPct': overlapPct,
          'positionAngleDeg': positionAngleDeg,
          'centerRaDeg': centerRaDeg,
          'centerDecDeg': centerDecDeg,
          'panels': [
            for (final p in panels)
              <String, Object?>{
                'panelIndex': p.panelIndex,
                'centerRaDeg': p.centerRaDeg,
                'centerDecDeg': p.centerDecDeg,
              },
          ],
        }),
      ),
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Publish mosaic');
    }
    return CollabMosaic.fromJson(_decodeJson(response, 'Publish mosaic'));
  }

  /// `GET /v1/mosaics` — list open/claimable collaborative mosaics.
  Future<List<CollabMosaic>> listMosaics() async {
    final response = await _send('GET', _v1('mosaics'));
    if (response.statusCode != 200) _throwForStatus(response, 'List mosaics');
    final body = _decodeJson(response, 'List mosaics');
    final list = body['mosaics'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(CollabMosaic.fromJson)
        .toList(growable: false);
  }

  /// `GET /v1/mosaics/{mosaicId}` — one mosaic + its per-panel state.
  Future<CollabMosaic> getMosaic(String mosaicId) async {
    final response = await _send('GET', _v1('mosaics/$mosaicId'));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Get mosaic $mosaicId');
    }
    return CollabMosaic.fromJson(_decodeJson(response, 'Get mosaic $mosaicId'));
  }

  /// `POST /v1/mosaics/{mosaicId}/panels/{panelIndex}/claim` — take the panel
  /// baton. A 409 means another rig holds it (surfaced as
  /// [ConstellationErrorKind.conflict], distinct from a tile geometry mismatch).
  Future<MosaicPanelClaim> claimPanel(
    String mosaicId,
    int panelIndex, {
    String? rigId,
  }) async {
    final response = await _send(
      'POST',
      _v1('mosaics/$mosaicId/panels/$panelIndex/claim', {
        if (rigId != null && rigId.isNotEmpty) 'rigId': rigId,
      }),
    );
    final status = response.statusCode;
    if (status == 409) {
      // Panel held by another rig (or already uploaded) — a hub-state conflict,
      // NOT a tile geometry mismatch. Map to conflict explicitly.
      final body = response.body.trim();
      throw ConstellationException(
        'Claim panel $panelIndex of mosaic $mosaicId failed: panel is held by '
        'another rig${body.isEmpty ? '' : ' — $body'}',
        kind: ConstellationErrorKind.conflict,
        statusCode: 409,
      );
    }
    if (status != 200) {
      _throwForStatus(response, 'Claim panel $panelIndex of mosaic $mosaicId');
    }
    return MosaicPanelClaim.fromJson(
      _decodeJson(response, 'Claim panel $panelIndex of mosaic $mosaicId'),
    );
  }

  /// `POST /v1/mosaics/{mosaicId}/panels/{panelIndex}/release` — give the baton
  /// back. Returns whether a held claim was released.
  Future<bool> releasePanel(String mosaicId, int panelIndex) async {
    final response = await _send(
      'POST',
      _v1('mosaics/$mosaicId/panels/$panelIndex/release'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(
        response,
        'Release panel $panelIndex of mosaic $mosaicId',
      );
    }
    final body = _decodeJson(response, 'Release panel $panelIndex');
    return _requireBool(body, 'released', 'Release panel $panelIndex');
  }

  /// `POST /v1/mosaics/{mosaicId}/panels/{panelIndex}/force-release` —
  /// owner/admin eviction of a squatting claim or a poisoned upload the
  /// per-account [releasePanel] cannot recover. Resets the panel to `pending`
  /// (clearing any uploaded master) so a fresh rig can take the slot. Returns
  /// whether a panel was evicted; 404 when there was nothing to free. The hub
  /// enforces that only the mosaic owner or an admin may call this.
  Future<bool> forceReleasePanel(String mosaicId, int panelIndex) async {
    final response = await _send(
      'POST',
      _v1('mosaics/$mosaicId/panels/$panelIndex/force-release'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(
        response,
        'Force-release panel $panelIndex of mosaic $mosaicId',
      );
    }
    final body = _decodeJson(response, 'Force-release panel $panelIndex');
    return _requireBool(body, 'released', 'Force-release panel $panelIndex');
  }

  /// `POST /v1/mosaics/{mosaicId}/panels/{panelIndex}/master` — stream the
  /// integrated panel master FITS at [fitsPath] up to the hub (streamed from
  /// disk like [pushSubframe]). The caller must currently hold the claim;
  /// [claimToken] rides as the `x-claim-token` header. Returns the panel state.
  Future<CollabMosaicPanel> pushPanelMaster(
    String mosaicId,
    int panelIndex,
    String fitsPath, {
    required String license,
    String? rigId,
    String? claimToken,
    bool attributionConsent = true,
  }) async {
    final file = File(fitsPath);
    if (!file.existsSync()) {
      throw ConstellationException(
        'Panel master not found: $fitsPath',
        kind: ConstellationErrorKind.notFound,
      );
    }
    final response = await _sendFile(
      'POST',
      _v1('mosaics/$mosaicId/panels/$panelIndex/master', {
        if (rigId != null && rigId.isNotEmpty) 'rigId': rigId,
      }),
      file,
      headers: {
        'Content-Type': 'application/octet-stream',
        if (claimToken != null && claimToken.isNotEmpty)
          'x-claim-token': claimToken,
        // Consent: a panel master is shared into a redistributable mosaic, so
        // it carries the chosen license + named-vs-anonymous choice. The hub
        // rejects a missing/unshareable license before storing any bytes.
        'license': license,
        'attributionConsent': '$attributionConsent',
      },
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Push panel master $panelIndex');
    }
    return CollabMosaicPanel.fromJson(
      _decodeJson(response, 'Push panel master $panelIndex'),
    );
  }

  /// `GET /v1/mosaics/{mosaicId}/panels/{panelIndex}/master` — download a panel
  /// master FITS to [outPath] (the assembler pulls every panel). Returns
  /// [outPath].
  Future<String> pullPanelMaster(
    String mosaicId,
    int panelIndex,
    String outPath,
  ) async {
    return _download(
      'GET',
      _v1('mosaics/$mosaicId/panels/$panelIndex/master'),
      outPath,
      'Pull panel master $panelIndex',
    );
  }

  /// `POST /v1/mosaics/{mosaicId}/output` — stream the finished stitched mosaic
  /// FITS up (owner-only). Returns the mosaic after it is marked complete.
  Future<CollabMosaic> pushMosaicOutput(
    String mosaicId,
    String fitsPath,
  ) async {
    final file = File(fitsPath);
    if (!file.existsSync()) {
      throw ConstellationException(
        'Mosaic output not found: $fitsPath',
        kind: ConstellationErrorKind.notFound,
      );
    }
    final response = await _sendFile(
      'POST',
      _v1('mosaics/$mosaicId/output'),
      file,
      headers: {'Content-Type': 'application/octet-stream'},
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Push mosaic output');
    }
    return CollabMosaic.fromJson(_decodeJson(response, 'Push mosaic output'));
  }

  /// `GET /v1/mosaics/{mosaicId}/output` — download the finished mosaic to
  /// [outPath]. 404 (→ [ConstellationErrorKind.notFound]) until complete.
  Future<String> pullMosaicOutput(String mosaicId, String outPath) async {
    return _download(
      'GET',
      _v1('mosaics/$mosaicId/output'),
      outPath,
      'Pull mosaic output',
    );
  }

  // Live co-imaging sessions

  /// `POST /v1/coimaging/sessions` — open a live co-imaging session on a target.
  /// The caller is the owner + anchor participant; the response carries the
  /// owner's membership token + assigned framing offset.
  Future<CoImagingSession> createCoImagingSession({
    required String targetName,
    required double centerRaDeg,
    required double centerDecDeg,
    double radiusDeg = 1.5,
    String? rigId,
  }) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions'),
      headers: {'Content-Type': 'application/json'},
      bodyBytes: utf8.encode(
        jsonEncode(<String, Object?>{
          'targetName': targetName,
          'centerRaDeg': centerRaDeg,
          'centerDecDeg': centerDecDeg,
          'radiusDeg': radiusDeg,
          if (rigId != null && rigId.isNotEmpty) 'rigId': rigId,
        }),
      ),
    );
    final status = response.statusCode;
    if (status != 200 && status != 201) {
      _throwForStatus(response, 'Create co-imaging session');
    }
    return CoImagingSession.fromJson(
      _decodeJson(response, 'Create co-imaging session'),
    );
  }

  /// `GET /v1/coimaging/sessions` — browse active co-imaging sessions.
  Future<List<CoImagingSession>> listCoImagingSessions() async {
    final response = await _send('GET', _v1('coimaging/sessions'));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'List co-imaging sessions');
    }
    final body = _decodeJson(response, 'List co-imaging sessions');
    final list = body['sessions'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(CoImagingSession.fromJson)
        .toList(growable: false);
  }

  /// `GET /v1/coimaging/sessions/{id}` — one session + participants + baton.
  Future<CoImagingSession> getCoImagingSession(String sessionId) async {
    final response = await _send('GET', _v1('coimaging/sessions/$sessionId'));
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Get co-imaging session $sessionId');
    }
    return CoImagingSession.fromJson(
      _decodeJson(response, 'Get co-imaging session $sessionId'),
    );
  }

  /// `POST /v1/coimaging/sessions/{id}/join` — JOIN as a rig. The hub assigns a
  /// unique framing offset + a membership token (carried on the returned
  /// participant). A 409 means the session is closed.
  Future<CoImagingParticipant> joinCoImagingSession(
    String sessionId, {
    String? rigId,
    String role = 'contribute',
  }) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions/$sessionId/join', {
        if (rigId != null && rigId.isNotEmpty) 'rigId': rigId,
        'role': role,
      }),
    );
    final status = response.statusCode;
    if (status == 409) {
      final body = response.body.trim();
      throw ConstellationException(
        'Join co-imaging session $sessionId failed: session is closed'
        '${body.isEmpty ? '' : ' — $body'}',
        kind: ConstellationErrorKind.conflict,
        statusCode: 409,
      );
    }
    if (status != 200) {
      _throwForStatus(response, 'Join co-imaging session $sessionId');
    }
    return CoImagingParticipant.fromJson(
      _decodeJson(response, 'Join co-imaging session $sessionId'),
    );
  }

  /// `POST /v1/coimaging/sessions/{id}/leave` — leave the session.
  Future<bool> leaveCoImagingSession(String sessionId, {String? rigId}) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions/$sessionId/leave', {
        if (rigId != null && rigId.isNotEmpty) 'rigId': rigId,
      }),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Leave co-imaging session $sessionId');
    }
    final body = _decodeJson(response, 'Leave co-imaging session');
    return _requireBool(body, 'left', 'Leave co-imaging session $sessionId');
  }

  /// `POST /v1/coimaging/sessions/{id}/close` — close the session (owner/admin
  /// only). Marks it `closed` on the hub and tears down its live preview
  /// subscribers; returns the closed session's state.
  Future<CoImagingSession> closeCoImagingSession(String sessionId) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions/$sessionId/close'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Close co-imaging session $sessionId');
    }
    return CoImagingSession.fromJson(
      _decodeJson(response, 'Close co-imaging session $sessionId'),
    );
  }

  /// `POST /v1/coimaging/sessions/{id}/contributions` — report a rig's frames /
  /// integration to the COMBINED accounting after folding its sub into the
  /// shared-target tile. [membershipToken] rides as `x-membership-token`. Returns
  /// the updated combined totals.
  Future<CoImagingAccounting> recordCoImagingContribution(
    String sessionId, {
    required int framesDelta,
    required double integrationSecondsDelta,
    required String license,
    String? rigId,
    String? membershipToken,
    bool attributionConsent = true,
  }) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions/$sessionId/contributions', {
        'framesDelta': '$framesDelta',
        'integrationSecondsDelta': '$integrationSecondsDelta',
        if (rigId != null && rigId.isNotEmpty) 'rigId': rigId,
      }),
      headers: {
        if (membershipToken != null && membershipToken.isNotEmpty)
          'x-membership-token': membershipToken,
        // Consent: a co-imaging contribution folds this rig's sub into the
        // shared co-add, so it carries the chosen license + named-vs-anonymous
        // choice. The hub records consent before the combined accounting lands.
        'license': license,
        'attributionConsent': '$attributionConsent',
      },
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Record co-imaging contribution');
    }
    return CoImagingAccounting.fromJson(
      _decodeJson(response, 'Record co-imaging contribution'),
    );
  }

  /// `GET /v1/coimaging/sessions/{id}/baton` — who holds the active-imager baton.
  Future<CoImagingBatonState> getCoImagingBaton(String sessionId) async {
    final response = await _send(
      'GET',
      _v1('coimaging/sessions/$sessionId/baton'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Get co-imaging baton $sessionId');
    }
    return CoImagingBatonState.fromJson(
      _decodeJson(response, 'Get co-imaging baton $sessionId'),
    );
  }

  /// `POST /v1/coimaging/sessions/{id}/baton/claim` — take the active-imager
  /// baton (the target is rising at this site). Returns null on a 409 (another
  /// site holds it) so the caller can keep pulling instead.
  Future<HandoffClaim?> claimCoImagingBaton(String sessionId) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions/$sessionId/baton/claim'),
    );
    if (response.statusCode == 409) return null;
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Claim co-imaging baton $sessionId');
    }
    return HandoffClaim.fromJson(
      _decodeJson(response, 'Claim co-imaging baton $sessionId'),
    );
  }

  /// `POST /v1/coimaging/sessions/{id}/baton/release` — hand the baton east as
  /// the target sets at this site.
  Future<bool> releaseCoImagingBaton(String sessionId) async {
    final response = await _send(
      'POST',
      _v1('coimaging/sessions/$sessionId/baton/release'),
    );
    if (response.statusCode != 200) {
      _throwForStatus(response, 'Release co-imaging baton $sessionId');
    }
    final body = _decodeJson(response, 'Release co-imaging baton');
    return _requireBool(
      body,
      'released',
      'Release co-imaging baton $sessionId',
    );
  }

  /// `GET /v1/coimaging/sessions/{id}/events` — subscribe to the live combined
  /// preview channel (Server-Sent Events). Yields one [CoImagingPreview] per SSE
  /// `data:` frame (an immediate snapshot, then one per contribution / join)
  /// until the returned subscription is cancelled. The hub delivers this as a
  /// long-lived `text/event-stream`, so callers MUST cancel the subscription to
  /// release the connection.
  Stream<CoImagingPreview> streamCoImagingEvents(String sessionId) async* {
    final request = http.Request(
      'GET',
      _v1('coimaging/sessions/$sessionId/events'),
    );
    request.headers.addAll(_authHeaders);
    final http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request);
    } on SocketException catch (e) {
      throw ConstellationException(
        'Cannot reach ${request.url.host}: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    } on http.ClientException catch (e) {
      throw ConstellationException(
        'Co-imaging event stream failed: ${e.message}',
        kind: ConstellationErrorKind.network,
      );
    }
    if (streamed.statusCode != 200) {
      _throwForStatus(
        await http.Response.fromStream(streamed),
        'Co-imaging events $sessionId',
      );
    }
    final lines = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final preview = parseSseDataLine(line);
      if (preview != null) yield preview;
    }
  }

  /// Decode one SSE line into a [CoImagingPreview], or null when the line is not
  /// a `data:` payload (an `event:`/blank framing line). Pure + static so the SSE
  /// parsing is unit-testable without a live socket.
  static CoImagingPreview? parseSseDataLine(String line) {
    if (!line.startsWith('data:')) return null;
    final payload = line.substring('data:'.length).trim();
    if (payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return CoImagingPreview.fromJson(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}
