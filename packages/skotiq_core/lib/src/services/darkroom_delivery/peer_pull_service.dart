/// The paired desktop's side of peer delivery: fetch the rig's manifest, pull
/// what it lists, verify it, and tell the rig what landed.
///
/// This runs on the DESKTOP, on schedule or on wake. It is the whole reason
/// peer delivery is a pull: the remote protocol serves artifacts by
/// authenticated GET with Range and ETag, and has no inbound receiver, no peer
/// write scope, and no resumable upload for the rig to push with.
///
/// Three refusals are deliberate:
///
/// * A manifest that does not verify against this desktop's own token is
///   refused whole. The signature is what binds the checksums to the rig.
/// * A file already on disk under its final name with the manifest's checksum
///   is acknowledged, not re-downloaded.
/// * A download whose bytes do not hash to the manifest's checksum is
///   discarded, never renamed into place, and never acknowledged.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show computeServerFingerprint;
import 'package:path/path.dart' as p;

import '../../models/backend/remote_api_compatibility.dart';
import 'delivery_artifact.dart';
import 'delivery_failure.dart';
import 'delivery_manifest.dart';
import 'resumable_artifact_downloader.dart';

/// What happened to one manifest entry on one pull.
enum PeerPullOutcome {
  /// The bytes were downloaded, verified, renamed into place and acknowledged.
  pulled,

  /// The file was already on disk with the manifest's checksum; it was
  /// acknowledged rather than fetched again.
  alreadyPresent,

  /// The pull failed; [PeerPullFileReport.problem] says how.
  failed,
}

/// One file's result.
class PeerPullFileReport {
  /// The manifest entry this is about.
  final DeliveryManifestEntry entry;

  /// What happened.
  final PeerPullOutcome outcome;

  /// Bytes transferred on this pass. Zero for a file that was already there.
  final int transferredBytes;

  /// The failure, when [outcome] is [PeerPullOutcome.failed].
  final String? problem;

  const PeerPullFileReport({
    required this.entry,
    required this.outcome,
    required this.transferredBytes,
    this.problem,
  });
}

/// What happened on one pull of one job.
class PeerPullReport {
  /// The job that was pulled.
  final int jobId;

  /// Per-file results, in manifest order.
  final List<PeerPullFileReport> files;

  /// A problem that stopped the pull before any file was fetched — an
  /// unreachable rig, a manifest that did not verify. Null when the manifest
  /// was read.
  final String? manifestProblem;

  /// Files the rig published but could not serve, as it reported them.
  final List<UnavailableArtifact> unavailable;

  const PeerPullReport({
    required this.jobId,
    required this.files,
    this.manifestProblem,
    this.unavailable = const [],
  });

  /// Files that arrived on this pass.
  int get pulled =>
      files.where((f) => f.outcome == PeerPullOutcome.pulled).length;

  /// Files that were already present.
  int get alreadyPresent =>
      files.where((f) => f.outcome == PeerPullOutcome.alreadyPresent).length;

  /// Files that did not arrive.
  int get failed =>
      files.where((f) => f.outcome == PeerPullOutcome.failed).length;

  /// True when the manifest was read and every file it listed is on disk.
  bool get complete =>
      manifestProblem == null && failed == 0 && unavailable.isEmpty;

  /// The line the desktop's status surface prints.
  String get summary {
    final problem = manifestProblem;
    if (problem != null) return 'Job $jobId: $problem';
    final parts = <String>[
      if (pulled > 0) '$pulled pulled',
      if (alreadyPresent > 0) '$alreadyPresent already here',
      if (failed > 0) '$failed failed',
      if (unavailable.isNotEmpty) '${unavailable.length} not served by the rig',
    ];
    // "Nothing to pull", not "nothing published": the manifest lists what this
    // machine is still owed, and a job whose files this desktop has already
    // pulled and acknowledged is off that list. Claiming the rig published
    // nothing would be a statement about the night that the manifest, by
    // design, no longer carries the evidence for.
    return parts.isEmpty
        ? 'Job $jobId: the rig is offering this machine nothing to pull'
        : 'Job $jobId: ${parts.join(', ')}';
  }
}

/// Pulls a rig's published artifacts onto this machine.
class PeerPullService {
  /// Base URL of the rig's headless API, e.g. `http://rig.local:8080`.
  final Uri baseUrl;

  /// The bearer token this desktop pairs with. Also the material the manifest
  /// signature is verified against.
  final String token;

  /// The peer id this desktop is configured as on the rig's destination row.
  final String peerId;

  /// Directory the artifacts land in.
  final Directory destinationDirectory;

  final ArtifactHttpClient _http;
  final ResumableArtifactDownloader _downloader;

  factory PeerPullService({
    required Uri baseUrl,
    required String token,
    required String peerId,
    required Directory destinationDirectory,
    ArtifactHttpClient? http,
  }) {
    // One client, used by both the manifest calls and the downloader: two
    // would open two connection pools to the same rig and only one of them
    // would ever be closed.
    final client = http ?? IoArtifactHttpClient();
    return PeerPullService._(
      baseUrl: baseUrl,
      token: token,
      peerId: peerId,
      destinationDirectory: destinationDirectory,
      client: client,
    );
  }

  PeerPullService._({
    required this.baseUrl,
    required this.token,
    required this.peerId,
    required this.destinationDirectory,
    required ArtifactHttpClient client,
  }) : _http = client,
       _downloader = ResumableArtifactDownloader(client);

  /// Pull everything the rig published for this desktop on [jobId].
  ///
  /// Never throws: a rig that is asleep at 06:00 is a line in the report, not
  /// an error that kills the desktop's scheduled task.
  Future<PeerPullReport> pullJob(int jobId) async {
    final SignedDeliveryManifest signed;
    try {
      signed = await fetchManifest(jobId);
    } on DeliveryFailure catch (failure) {
      return PeerPullReport(
        jobId: jobId,
        files: const [],
        manifestProblem: failure.journalText,
      );
    } on DeliveryManifestFormatException catch (error) {
      return PeerPullReport(
        jobId: jobId,
        files: const [],
        manifestProblem: 'the manifest did not parse: ${error.message}',
      );
    } on SocketException catch (error) {
      return PeerPullReport(
        jobId: jobId,
        files: const [],
        manifestProblem: 'the rig at $baseUrl did not answer: ${error.message}',
      );
    }

    if (!signed.verify(computeServerFingerprint(token))) {
      final reason =
          signed.signatureAbsentReason ??
          'its signature is not the one this pairing produces';
      return PeerPullReport(
        jobId: jobId,
        files: const [],
        manifestProblem: 'the manifest was refused because $reason',
        unavailable: signed.manifest.unavailable,
      );
    }

    await destinationDirectory.create(recursive: true);
    final files = <PeerPullFileReport>[];
    for (final entry in signed.manifest.entries) {
      files.add(await _pullOne(jobId: jobId, entry: entry));
    }
    return PeerPullReport(
      jobId: jobId,
      files: files,
      unavailable: signed.manifest.unavailable,
    );
  }

  /// Fetch and parse the signed manifest for [jobId].
  Future<SignedDeliveryManifest> fetchManifest(int jobId) async {
    final url = _resolve('api/darkroom/delivery/manifest/$jobId', {
      'peer': peerId,
    });
    final response = await _http.get(url, _headers());
    final body = await _collect(response);
    if (response.statusCode != HttpStatus.ok) {
      throw DeliveryFailure(
        _kindForStatus(response.statusCode),
        'the rig answered ${response.statusCode} to the manifest request: '
        '${body.isEmpty ? 'no body' : body}',
      );
    }
    return SignedDeliveryManifest.fromJson(jsonDecode(body));
  }

  /// Release the HTTP connections this service holds.
  void close() => _http.close();

  Future<PeerPullFileReport> _pullOne({
    required int jobId,
    required DeliveryManifestEntry entry,
  }) async {
    final destinationPath = p.join(destinationDirectory.path, entry.fileName);
    try {
      final existing = File(destinationPath);
      if (await existing.exists()) {
        final onDisk = await sha256OfFile(existing);
        if (onDisk == entry.checksum) {
          await acknowledge(jobId: jobId, entry: entry);
          return PeerPullFileReport(
            entry: entry,
            outcome: PeerPullOutcome.alreadyPresent,
            transferredBytes: 0,
          );
        }
        throw DeliveryFailure(
          DeliveryFailureKind.destinationConflict,
          '$destinationPath already exists with different content (here: '
          '$onDisk, on the rig: ${entry.checksum}); the pull copies and never '
          'overwrites',
        );
      }

      final transferred = await _downloader.download(
        url: _resolve(
          'api/darkroom/delivery/artifact/$jobId/${entry.artifactId}',
          {'peer': peerId},
        ),
        headers: _headers(),
        artifactId: entry.artifactId,
        destinationPath: destinationPath,
        expectedChecksum: entry.checksum,
      );
      await acknowledge(jobId: jobId, entry: entry);
      return PeerPullFileReport(
        entry: entry,
        outcome: PeerPullOutcome.pulled,
        transferredBytes: transferred,
      );
    } on DeliveryFailure catch (failure) {
      return PeerPullFileReport(
        entry: entry,
        outcome: PeerPullOutcome.failed,
        transferredBytes: 0,
        problem: failure.journalText,
      );
    } on SocketException catch (error) {
      return PeerPullFileReport(
        entry: entry,
        outcome: PeerPullOutcome.failed,
        transferredBytes: 0,
        problem: 'the rig stopped answering: ${error.message}',
      );
    }
  }

  /// Tell the rig one file arrived and verified, so its journal can say
  /// delivered instead of awaiting pull.
  Future<void> acknowledge({
    required int jobId,
    required DeliveryManifestEntry entry,
  }) async {
    final response = await _http.postJson(
      _resolve('api/darkroom/delivery/ack/$jobId', const {}),
      _headers(),
      <String, Object?>{
        'peerId': peerId,
        'artifactId': entry.artifactId,
        'checksum': entry.checksum,
      },
    );
    final body = await _collect(response);
    if (response.statusCode != HttpStatus.ok) {
      throw DeliveryFailure(
        _kindForStatus(response.statusCode),
        'the rig answered ${response.statusCode} to the delivery '
        'acknowledgement: ${body.isEmpty ? 'no body' : body}',
      );
    }
  }

  Uri _resolve(String path, Map<String, String> query) {
    final base = baseUrl.path.endsWith('/') ? baseUrl.path : '${baseUrl.path}/';
    return baseUrl.replace(
      path: '$base$path',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Map<String, String> _headers() => <String, String>{
    HttpHeaders.authorizationHeader: 'Bearer $token',
    RemoteApiCompatibility.apiVersionHeader: RemoteApiCompatibility
        .clientApiVersion
        .format(),
  };

  static DeliveryFailureKind _kindForStatus(int status) {
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      return DeliveryFailureKind.credentialMissing;
    }
    if (status == HttpStatus.notFound) return DeliveryFailureKind.sourceMissing;
    return DeliveryFailureKind.transportFailure;
  }

  static Future<String> _collect(ArtifactHttpResponse response) async {
    final buffer = <int>[];
    await for (final chunk in response.body) {
      buffer.addAll(chunk);
    }
    return utf8.decode(buffer, allowMalformed: true);
  }
}
