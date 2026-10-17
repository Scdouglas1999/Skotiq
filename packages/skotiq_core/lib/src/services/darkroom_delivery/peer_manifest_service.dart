/// Builds the manifest a paired desktop pulls, and resolves the opaque ids in
/// it back to files on the rig.
///
/// The publication is the set of `delivery_journal` rows a peer destination
/// holds for one job. Everything the desktop is allowed to fetch is in those
/// rows, so an id that resolves to nothing is a request for a file this job
/// never published — refused, rather than reached for on disk.
///
/// Sizes and checksums are read at manifest time rather than recalled from the
/// journal. The journal records a checksum only once a file has ARRIVED, and a
/// peer file has not arrived until the desktop pulls it; describing the bytes
/// as they are right now also means the manifest agrees with whatever the
/// download endpoint is about to serve. The cost is one pass over the
/// published files per manifest request, which is why a desktop asks for a
/// manifest once per job rather than polling it.
library;

import 'package:path/path.dart' as p;

import '../../database/daos/delivery_journal_dao.dart';
import '../../database/daos/delivery_targets_dao.dart';
import '../../models/darkroom/delivery.dart';
import 'delivery_artifact.dart';
import 'delivery_failure.dart';
import 'delivery_manifest.dart';
import 'delivery_naming.dart';
import 'peer_publication_transport.dart';

/// No enabled peer destination on this rig answers to the requested peer id.
class UnknownDeliveryPeerException implements Exception {
  /// The peer id the caller asked as.
  final String peerId;

  const UnknownDeliveryPeerException(this.peerId);

  @override
  String toString() =>
      'No enabled peer delivery destination is configured for "$peerId"';
}

/// One published file, resolved from a manifest id.
class PublishedArtifact {
  /// The `delivery_targets.id` that published it.
  final int targetId;

  /// The `darkroom_jobs.id` it belongs to.
  final int jobId;

  /// Absolute path on the rig.
  final String filePath;

  /// The name this destination publishes it under — the same namespaced name
  /// [DeliveryManifest] listed for it.
  ///
  /// Not the rig's own file name. Every other transport writes
  /// `<rigId>-<name>` precisely so two rigs sharing one folder do not collide,
  /// and a download that offered the bare name handed exactly that collision
  /// to any puller that saves what the header says — `curl -OJ`, a browser, a
  /// third-party script. Skotiq's own puller writes the manifest entry's
  /// name and was never affected, which is what let the two disagree unnoticed.
  final String fileName;

  const PublishedArtifact({
    required this.targetId,
    required this.jobId,
    required this.filePath,
    required this.fileName,
  });
}

/// Serves the peer-pull side of delivery.
class PeerManifestService {
  final DeliveryTargetsDao _targets;
  final DeliveryJournalDao _journal;
  final DateTime Function() _clock;

  PeerManifestService({
    required DeliveryTargetsDao targets,
    required DeliveryJournalDao journal,
    DateTime Function()? clock,
  }) : _targets = targets,
       _journal = journal,
       _clock = clock ?? DateTime.now;

  /// The manifest of everything [jobId] published for [peerId].
  ///
  /// Throws [UnknownDeliveryPeerException] when no enabled peer destination
  /// carries that peer id — a manifest served to an unrecognised caller would
  /// hand one desktop another desktop's night.
  ///
  /// A file a job published that is no longer on disk is not offered — it is
  /// listed as unavailable, whether this request is the first to notice it
  /// gone or the rig's own sweep already recorded it terminal. Both readings
  /// name the same file to the desktop, so a pull that ran before the sweep
  /// and one that ran after it report the same night.
  ///
  /// A file this desktop already ACKNOWLEDGED is not offered either. The
  /// manifest is the list of what is still owed, and every other transport
  /// stops at `delivered` too. It is not listed as unavailable, because
  /// nothing about it went wrong and the desktop is the machine that told the
  /// rig it landed. The download endpoint still serves it — [resolveArtifact]
  /// reads every row of the job — so a desktop holding the id from an earlier
  /// manifest can still fetch the bytes again and acknowledge them again.
  Future<DeliveryManifest> buildManifest({
    required int jobId,
    required String peerId,
  }) async {
    final namings = <int, DeliveryNaming>{
      for (final entry in (await _peerTargets(peerId)).entries)
        entry.key: DeliveryNaming.forDestination(entry.value),
    };
    final entries = <DeliveryManifestEntry>[];
    final unavailable = <UnavailableArtifact>[];
    for (final row in await _journal.listForJob(jobId)) {
      final naming = namings[row.targetId];
      if (naming == null) continue;
      if (row.state == DeliveryAttemptState.delivered) continue;
      if (row.state == DeliveryAttemptState.failed) {
        // Terminal on the rig: nothing here will offer it again, so it is not
        // an entry. It is still one of this job's published files, and the
        // desktop is the one machine that cannot see the rig's journal —
        // dropping the row outright is how a file the rig lost after
        // publishing it disappeared from both surfaces at once.
        unavailable.add(
          UnavailableArtifact(
            artifactId: artifactIdForPath(row.filePath),
            reason: _terminalReason(row),
          ),
        );
        continue;
      }
      final DeliveryFile file;
      try {
        file = await DeliveryFile.describe(row.filePath);
      } on DeliveryFailure catch (failure) {
        // The published file is gone or unreadable on the rig. Listing it
        // would promise the desktop a download that cannot be served, and
        // leaving it out silently would read as a job that produced less.
        unavailable.add(
          UnavailableArtifact(
            artifactId: artifactIdForPath(row.filePath),
            reason: failure.journalText,
          ),
        );
        continue;
      }
      entries.add(
        DeliveryManifestEntry(
          artifactId: artifactIdForPath(row.filePath),
          targetId: row.targetId,
          fileName: naming.nameFor(file.fileName),
          bytes: file.bytes,
          checksum: file.checksum,
        ),
      );
    }
    return DeliveryManifest(
      jobId: jobId,
      peerId: peerId,
      generatedAt: _clock().toUtc(),
      entries: entries,
      unavailable: unavailable,
    );
  }

  /// Why a terminal row cannot be served, in the words the journal recorded.
  ///
  /// [DeliveryJournalDao.markFailed] is the only writer of that state and it
  /// requires the text, so this reads the recorded reason. A row that reached
  /// the state without one is reported as exactly that rather than given a
  /// reason it does not have.
  static String _terminalReason(DeliveryJournalEntry row) {
    final recorded = row.lastError?.trim();
    if (recorded == null || recorded.isEmpty) {
      return 'This file is recorded as failed on the rig with no reason';
    }
    return recorded;
  }

  /// Resolve [artifactId] to the file it names, or null when this job
  /// published nothing under that id for this peer.
  Future<PublishedArtifact?> resolveArtifact({
    required int jobId,
    required String peerId,
    required String artifactId,
  }) async {
    final targets = await _peerTargets(peerId);
    for (final row in await _journal.listForJob(jobId)) {
      final destination = targets[row.targetId];
      if (destination == null) continue;
      if (artifactIdForPath(row.filePath) != artifactId) continue;
      // The same naming the manifest published this file under, read from the
      // same destination row, so the two cannot drift. A `rigId` this build
      // cannot read throws here exactly as it does in [buildManifest] — the
      // caller has already had that refusal, because the id it is asking with
      // came out of a manifest.
      final naming = DeliveryNaming.forDestination(destination);
      return PublishedArtifact(
        targetId: row.targetId,
        jobId: row.jobId,
        filePath: row.filePath,
        fileName: naming.nameFor(p.basename(row.filePath)),
      );
    }
    return null;
  }

  /// Record that a paired desktop pulled and verified one published file.
  ///
  /// This is what turns a peer row from published into delivered. The rig
  /// cannot observe the arrival itself — it served bytes, which is not the
  /// same as the bytes landing intact on the other machine — so the claim in
  /// the morning report comes from the puller.
  ///
  /// Throws [UnknownDeliveryPeerException] when the caller is not a configured
  /// peer, [DeliveryJournalMissingException] when this job published nothing
  /// under that id for that peer, and [DeliveryFailure] with
  /// [DeliveryFailureKind.checksumMismatch] when the acknowledged checksum is
  /// not the one the manifest published, so a desktop cannot mark a corrupt
  /// pull as delivered.
  Future<DeliveryJournalEntry> acknowledgePull({
    required int jobId,
    required String peerId,
    required String artifactId,
    required String checksum,
  }) async {
    final artifact = await resolveArtifact(
      jobId: jobId,
      peerId: peerId,
      artifactId: artifactId,
    );
    if (artifact == null) {
      throw DeliveryJournalMissingException(0, jobId, artifactId);
    }
    final onRig = await DeliveryFile.describe(artifact.filePath);
    if (onRig.checksum != checksum) {
      throw DeliveryFailure(
        DeliveryFailureKind.checksumMismatch,
        'The pull of ${onRig.fileName} reported $checksum but the rig\'s copy '
        'hashes to ${onRig.checksum}',
      );
    }
    return _journal.markDelivered(
      targetId: artifact.targetId,
      jobId: artifact.jobId,
      filePath: artifact.filePath,
      checksum: checksum,
      bytes: onRig.bytes,
      now: _clock(),
    );
  }

  /// The enabled peer destinations that answer to [peerId], by row id.
  ///
  /// The rows themselves rather than their ids, because the manifest names the
  /// file the desktop writes and that name carries each destination's own
  /// rig-identity component.
  Future<Map<int, ArtifactDestination>> _peerTargets(String peerId) async {
    final wanted = peerId.trim();
    if (wanted.isEmpty) throw UnknownDeliveryPeerException(peerId);
    final matched = <int, ArtifactDestination>{};
    // The undecodable rows are deliberately not consulted: a row this build
    // cannot read cannot be shown to answer to a peer id, and the delivery
    // pass has already named it as skipped.
    for (final destination in (await _targets.readEnabled()).destinations) {
      if (destination.kind != ArtifactDestinationKind.peer) continue;
      final id = destination.id;
      if (id == null) continue;
      final String configured;
      try {
        configured = PeerPublicationTransport.readPeerId(destination);
      } on DeliveryFailure {
        // A peer destination with no usable peerId answers to nobody. The
        // delivery service reports that configuration failure when it tries to
        // publish; here it simply matches no request, and one misconfigured
        // destination does not deny another peer its manifest.
        continue;
      }
      if (configured == wanted) matched[id] = destination;
    }
    if (matched.isEmpty) throw UnknownDeliveryPeerException(peerId);
    return matched;
  }
}
