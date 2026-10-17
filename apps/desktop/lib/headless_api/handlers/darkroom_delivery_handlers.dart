import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../request_context.dart';
import '../response_helpers.dart';
import '../validation.dart';

/// The rig side of **peer delivery** — the surface a paired desktop pulls the
/// night's artifacts through.
///
/// Peer delivery is a pull, not a push. The remote protocol serves artifacts
/// by authenticated GET with RFC 7233 Range/If-Range/ETag and has no inbound
/// receiver, no peer write scope and no resumable upload, so the rig publishes
/// and the desktop collects. These three endpoints are that publication:
///
///   * `GET  /api/darkroom/delivery/manifest/<jobId>?peer=<peerId>` — the
///     signed list of what this job published for that peer, with sizes and
///     SHA-256s.
///   * `GET  /api/darkroom/delivery/artifact/<jobId>/<artifactId>?peer=<peerId>`
///     — the bytes, served exactly like `/api/images/<id>/download` so the
///     desktop's resumable downloader can resume a 4 GB master over a flaky
///     link.
///   * `POST /api/darkroom/delivery/ack/<jobId>` — the desktop stating that a
///     file arrived and verified, which is what lets the morning report say
///     "delivered to office-pc" instead of "awaiting pull". The rig served
///     bytes; only the puller knows they landed intact.
///
/// **Nothing here takes a path from the caller.** An artifact is addressed by
/// an opaque id that the manifest issued and that resolves back through the
/// `delivery_journal` rows this job published for this peer. A request for a
/// file the job never published resolves to nothing and is refused, so no
/// crafted id can walk the rig's filesystem.
///
/// **The peer id is required and is checked against the destination rows** —
/// an id no enabled peer destination carries is refused. That is a check on the
/// id, not on the caller: nothing here proves the caller IS the peer it names,
/// because no peer↔credential association exists to check against. A
/// destination row carries `{"peerId": ...}` and nothing else identifying
/// (`config_json` may hold no key material by design), and a
/// [HeadlessAuthGrant] carries only resource levels — no pairing identity. So
/// on a rig with two peer destinations, a caller already holding a delivery
/// credential can name either peer and collect that peer's night, or
/// acknowledge on its behalf.
///
/// What bounds that today is the scope, not the id: the whole
/// `/api/darkroom/delivery/` prefix is `darkroom:control` (see
/// `route_metadata/path_classification.dart`), so a read-only credential
/// cannot reach any of it and only a credential already trusted to run the rig
/// can. Binding a peer to the credential that pairs as it needs a recorded
/// association on the destination row and a pairing flow that sets it; until
/// that exists this surface separates peers by NAME, not by AUTHORITY, and the
/// journal's "delivered to &lt;peer&gt;" is only as strong as that.
class DarkroomDeliveryHandlers {
  final ProviderContainer container;

  DarkroomDeliveryHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  PeerManifestService get _peers => container.read(peerManifestServiceProvider);

  /// GET /api/darkroom/delivery/manifest/&lt;jobId&gt;?peer=&lt;peerId&gt;
  ///
  /// The signature covers the manifest's canonical bytes under a key derived
  /// from the calling token's digest, which the desktop can re-derive from the
  /// token it paired with. A server running with no token configured has no
  /// principal to derive a key from; it answers with a manifest that says so
  /// rather than one that pretends to be signed.
  Future<Response> handleGetDeliveryManifest(
    Request request,
    String jobId,
  ) async {
    final id = _parseJobId(jobId);
    final peerId = _requirePeerId(request);
    _logger.info(
      '[API] GET /api/darkroom/delivery/manifest/$id peer=$peerId',
      source: 'DarkroomDeliveryHandlers',
    );

    final DeliveryManifest manifest;
    try {
      manifest = await _peers.buildManifest(jobId: id, peerId: peerId);
    } on UnknownDeliveryPeerException catch (error) {
      return jsonNotFound({
        'error': 'unknown_delivery_peer',
        'message': error.toString(),
      });
    }

    final identity = authIdentityFrom(request);
    final signed = identity == null
        ? SignedDeliveryManifest.unsigned(
            manifest: manifest,
            reason:
                'this server authenticated no principal for the request, so '
                'there is no pairing secret to sign with',
          )
        : SignedDeliveryManifest.sign(
            manifest: manifest,
            authIdentity: identity,
          );
    return jsonOk(signed.toJson());
  }

  /// GET /api/darkroom/delivery/artifact/&lt;jobId&gt;/&lt;artifactId&gt;?peer=&lt;peerId&gt;
  ///
  /// Range handling mirrors `/api/images/<imageId>/download` exactly: 200 with
  /// `accept-ranges` when no Range is sent, 206 with `content-range` for a
  /// satisfiable single range, 416 for anything malformed or multi-range, and
  /// a strong `etag` of `"<artifact>-<mtime-ms>"` so `If-Range` can decide
  /// whether a resume is still valid.
  Future<Response> handleDownloadDeliveryArtifact(
    Request request,
    String jobId,
    String artifactId,
  ) async {
    final id = _parseJobId(jobId);
    final peerId = _requirePeerId(request);
    _logger.info(
      '[API] GET /api/darkroom/delivery/artifact/$id/$artifactId peer=$peerId',
      source: 'DarkroomDeliveryHandlers',
    );

    final PublishedArtifact? published;
    try {
      published = await _peers.resolveArtifact(
        jobId: id,
        peerId: peerId,
        artifactId: artifactId,
      );
    } on UnknownDeliveryPeerException catch (error) {
      return jsonNotFound({
        'error': 'unknown_delivery_peer',
        'message': error.toString(),
      });
    }
    if (published == null) {
      return jsonNotFound({
        'error': 'artifact_not_published',
        'message':
            'Job $id published nothing under that id for $peerId. Ask for the '
            'manifest again — its ids are what this endpoint resolves.',
      });
    }

    final file = File(published.filePath);
    if (!await file.exists()) {
      return jsonNotFound({
        'error': 'artifact_missing',
        'message':
            'The published file is no longer on this machine. The manifest '
            'lists it under "unavailable" once it is gone.',
      });
    }

    final int fileLength;
    final DateTime mtime;
    try {
      fileLength = await file.length();
      mtime = await file.lastModified();
    } on PathAccessException {
      _logger.warning(
        'Reading published artifact $artifactId is not permitted',
        source: 'DarkroomDeliveryHandlers',
      );
      return jsonForbidden({
        'error': 'artifact_unreadable',
        'message': 'This server may not read the published file.',
      });
    } on FileSystemException catch (error) {
      _logger.error(
        'Stat of published artifact $artifactId failed: $error',
        source: 'DarkroomDeliveryHandlers',
      );
      return jsonInternalServerError(const {
        'error': 'artifact_unreadable',
        'detail': 'See server logs for diagnostics.',
      });
    }

    // The name the manifest promised for this artifact — `<rigId>-<name>` —
    // not the rig's own file name. A puller that saves what
    // `Content-Disposition` says now writes the same file the manifest listed,
    // which is the whole point of the namespacing: two rigs pulling into one
    // folder do not land on each other's names.
    final fileName = published.fileName;
    final etag = '"$artifactId-${mtime.millisecondsSinceEpoch}"';
    final rangeHeader = request.headers['range'];
    final ifRange = request.headers['if-range'];
    // RFC 7233 3.2: an If-Range that does not match the current validator
    // means the Range is ignored and the whole body is sent.
    final honourRange =
        rangeHeader != null && (ifRange == null || ifRange == etag);

    if (!honourRange) {
      return attachmentResponse(
        file.openRead(),
        fileName: fileName,
        contentType: _contentTypeFor(fileName),
        contentLength: fileLength,
        headers: {'accept-ranges': 'bytes', 'etag': etag},
      );
    }

    final int start;
    final int end;
    try {
      final parsed = parseRangeHeader(rangeHeader, fileLength);
      start = parsed.start;
      end = parsed.end;
    } on FormatException catch (error) {
      return rangeNotSatisfiableResponse(fileLength, reason: error.message);
    }

    // `openRead`'s end is exclusive; the Range bounds are inclusive.
    return partialContentResponse(
      file.openRead(start, end + 1),
      start: start,
      end: end,
      totalLength: fileLength,
      contentType: _contentTypeFor(fileName),
      fileName: fileName,
      headers: {'etag': etag},
    );
  }

  /// POST /api/darkroom/delivery/ack/&lt;jobId&gt;
  ///
  /// Body: `{"peerId": "office-pc", "artifactId": "...", "checksum": "..."}`.
  ///
  /// The acknowledged checksum is compared against the rig's own copy before
  /// the journal records an arrival: a desktop that pulled corrupt bytes
  /// cannot talk the morning report into saying they landed.
  Future<Response> handleAcknowledgeDelivery(
    Request request,
    String jobId,
  ) async {
    final id = _parseJobId(jobId);
    final body = await readJsonObject(request);
    final peerId = requireString(body, 'peerId');
    final artifactId = requireString(body, 'artifactId');
    final checksum = requireString(body, 'checksum');
    _logger.info(
      '[API] POST /api/darkroom/delivery/ack/$id peer=$peerId',
      source: 'DarkroomDeliveryHandlers',
    );

    try {
      final entry = await _peers.acknowledgePull(
        jobId: id,
        peerId: peerId,
        artifactId: artifactId,
        checksum: checksum,
      );
      return jsonOk({
        'jobId': entry.jobId,
        'targetId': entry.targetId,
        'state': entry.state.wire,
        'attempts': entry.attempts,
        'deliveredAt': entry.deliveredAt?.toIso8601String(),
      });
    } on UnknownDeliveryPeerException catch (error) {
      return jsonNotFound({
        'error': 'unknown_delivery_peer',
        'message': error.toString(),
      });
    } on DeliveryJournalMissingException {
      return jsonNotFound({
        'error': 'artifact_not_published',
        'message':
            'Job $id published nothing under that id for $peerId, so there is '
            'no delivery to acknowledge.',
      });
    } on DeliveryFailure catch (failure) {
      if (failure.kind == DeliveryFailureKind.checksumMismatch) {
        return jsonConflict({
          'error': 'checksum_mismatch',
          'message': failure.message,
        });
      }
      return jsonNotFound({
        'error': 'artifact_missing',
        'message': failure.message,
      });
    }
  }

  /// Parse the job id out of the path, so a malformed segment is the caller's
  /// 400 rather than an opaque 500 from the middleware.
  int _parseJobId(String value) {
    final id = int.tryParse(value);
    if (id == null || id <= 0) {
      throw BadRequestError(
        field: 'jobId',
        expected: 'positive integer',
        message: 'Path segment is not a valid job id',
      );
    }
    return id;
  }

  /// Read the required `peer` query parameter.
  String _requirePeerId(Request request) {
    final peerId = request.url.queryParameters['peer']?.trim();
    if (peerId == null || peerId.isEmpty) {
      throw BadRequestError(
        field: 'peer',
        expected: 'the peer id this destination is configured with',
        message:
            'A delivery manifest is published per peer, so the caller must say '
            'which peer it is',
      );
    }
    return peerId;
  }

  static String _contentTypeFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.fits') || lower.endsWith('.fit')) {
      return 'application/fits';
    }
    if (lower.endsWith('.xisf')) return 'application/x-xisf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return 'image/tiff';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.txt') || lower.endsWith('.log')) return 'text/plain';
    return 'application/octet-stream';
  }
}
