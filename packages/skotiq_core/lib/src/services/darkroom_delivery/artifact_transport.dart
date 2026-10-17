/// The contract every delivery transport implements.
///
/// One transport instance serves one destination for one job. The
/// [DeliveryService] opens it, hands it the artifacts that destination has
/// selected one at a time, and closes it — so a transport that holds a
/// connection opens it once per destination rather than once per file.
///
/// Failure is a [DeliveryFailure], never a bare exception and never a
/// degraded success: a transport that cannot verify what it wrote reports the
/// verification failure instead of reporting the write.
library;

import '../../models/darkroom/delivery.dart';
import 'delivery_artifact.dart';

/// What a transport did with one artifact.
enum DeliveryDisposition {
  /// The bytes are at their final name on the destination and their checksum
  /// was verified there.
  delivered,

  /// The artifact is published for the paired desktop to pull and has not
  /// moved yet. The rig cannot claim arrival on a pull transport until the
  /// puller acknowledges it.
  awaitingPull,
}

/// One artifact's transport-level outcome.
class TransportDeliveryOutcome {
  /// What happened to the file.
  final DeliveryDisposition disposition;

  /// The checksum that was verified at the destination, or — for
  /// [DeliveryDisposition.awaitingPull] — the checksum published for the
  /// puller to verify against.
  final String checksum;

  /// Where the file is, in the words the morning report prints.
  final String destinationDescription;

  const TransportDeliveryOutcome({
    required this.disposition,
    required this.checksum,
    required this.destinationDescription,
  });
}

/// A place artifacts are delivered to.
abstract class ArtifactTransport {
  /// The destination kind this transport serves.
  ArtifactDestinationKind get kind;

  /// Resolve configuration and credentials, prove the destination is
  /// reachable, and check it has room for [artifacts].
  ///
  /// Every failure that is knowable before the first byte moves belongs here,
  /// so a whole destination fails once instead of once per file.
  Future<void> open(List<DeliveryFile> artifacts);

  /// Copy one artifact to the destination and verify it arrived intact.
  ///
  /// The source is never modified and never removed — Skotiq copies, it
  /// does not move.
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact);

  /// Release whatever [open] acquired. Called even when a delivery failed.
  Future<void> close();
}
