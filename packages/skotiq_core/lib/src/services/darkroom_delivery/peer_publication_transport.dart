/// Delivery to another Skotiq install — by publication, not by push.
///
/// The remote protocol serves artifacts by authenticated GET only: there is no
/// peer write scope, no inbound artifact receiver, and no resumable upload.
/// So the rig does not send anything to a peer. It publishes a per-job
/// manifest — the file list with sizes and checksums — and the paired desktop
/// pulls it on schedule or on wake through the existing Range/ETag download
/// surface.
///
/// Publishing is exactly one act: the `delivery_journal` row. That row is the
/// manifest's only source, so a manifest served after a restart lists the same
/// files the process that died had published, and the morning report reads one
/// journal for all three transports.
///
/// Config (`delivery_targets.config_json`):
///
/// ```json
/// {"peerId": "office-pc"}
/// ```
///
/// `peerId` is what the paired desktop identifies itself as when it asks for a
/// manifest. It is required: without it a rig with two peer destinations
/// cannot tell which desktop pulled what, and both would be reported as
/// delivered when one machine collected everything.
library;

import '../../models/darkroom/delivery.dart';
import 'artifact_transport.dart';
import 'delivery_artifact.dart';
import 'delivery_failure.dart';

/// Publishes a job's artifacts for a paired desktop to pull.
class PeerPublicationTransport implements ArtifactTransport {
  /// The destination row this transport serves.
  final ArtifactDestination destination;

  /// The job whose artifacts are published.
  final int jobId;

  String? _peerId;

  PeerPublicationTransport({required this.destination, required this.jobId});

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.peer;

  /// The peer identity this destination publishes for, once [open] has read
  /// it. Null before that.
  String? get peerId => _peerId;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {
    _peerId = readPeerId(destination);
  }

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    final peer = _peerId;
    if (peer == null) {
      throw const DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This peer destination was asked to publish before it was opened',
      );
    }
    // The file was sized and hashed moments ago by the caller; publishing adds
    // no bytes and moves nothing. The journal row the service writes around
    // this call is the publication.
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.awaitingPull,
      checksum: artifact.checksum,
      destinationDescription: 'published for $peer to pull',
    );
  }

  @override
  Future<void> close() async {
    _peerId = null;
  }

  /// The `peerId` on a peer destination's config.
  ///
  /// Throws [DeliveryFailure] with [DeliveryFailureKind.configurationInvalid]
  /// when the config is not an object or names no peer — a manifest served to
  /// an unnamed peer would be served to every peer.
  static String readPeerId(ArtifactDestination destination) {
    final config = decodeDeliveryConfig(destination, what: 'peer destination');
    final peerId = config['peerId'];
    if (peerId is! String || peerId.trim().isEmpty) {
      throw const DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This peer destination names no peerId, so no desktop can ask for its '
        'manifest',
      );
    }
    return peerId.trim();
  }
}
