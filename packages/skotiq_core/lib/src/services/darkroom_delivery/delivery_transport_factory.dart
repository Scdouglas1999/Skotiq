/// Builds the transport one destination row delivers over.
///
/// The [DeliveryService] takes this as a function so a test can hand it a
/// fault-injected transport without a filesystem, an SSH server, or a paired
/// desktop. [DefaultArtifactTransportFactory] is what production passes.
library;

import 'dart:convert';

import '../../database/daos/delivery_targets_dao.dart';
import '../../models/darkroom/delivery.dart';
import '../notification/secrets_store.dart';
import 'artifact_transport.dart';
import 'peer_publication_transport.dart';
import 'sftp_command_runner.dart';
import 'sftp_transport.dart';
import 'watched_folder_transport.dart';

/// Builds the transport for one destination and one job.
typedef ArtifactTransportFactory =
    ArtifactTransport Function(ArtifactDestination destination, int jobId);

/// The production factory: a watched folder writes with the filesystem, SFTP
/// drives OpenSSH, and a peer is published for the paired desktop to pull.
class DefaultArtifactTransportFactory {
  final SecretsStore _secrets;
  final DeliveryTargetsDao _targets;
  final SftpCommandRunner _runner;
  final FreeSpaceProbe _freeSpace;

  DefaultArtifactTransportFactory({
    required SecretsStore secrets,
    required DeliveryTargetsDao targets,
    SftpCommandRunner runner = const ProcessSftpCommandRunner(),
    FreeSpaceProbe? freeSpace,
  }) : _secrets = secrets,
       _targets = targets,
       _runner = runner,
       _freeSpace = freeSpace ?? SystemFreeSpaceProbe();

  /// Build the transport for [destination].
  ArtifactTransport call(ArtifactDestination destination, int jobId) {
    switch (destination.kind) {
      case ArtifactDestinationKind.watchedFolder:
        return WatchedFolderTransport(
          destination: destination,
          jobId: jobId,
          freeSpace: _freeSpace,
        );
      case ArtifactDestinationKind.sftp:
        return SftpTransport(
          destination: destination,
          jobId: jobId,
          secrets: _secrets,
          runner: _runner,
          pinHostKey: (key) => _pinHostKey(destination, key),
        );
      case ArtifactDestinationKind.peer:
        return PeerPublicationTransport(destination: destination, jobId: jobId);
    }
  }

  /// Persist a newly learned SSH host key onto the destination row.
  ///
  /// The pin has to be durable before the first byte moves: a key held only in
  /// memory would be re-learned — and so re-trusted — on the next attempt,
  /// which is trust on EVERY use rather than trust on first use.
  ///
  /// Both halves are written. The fingerprint is what the operator reads and
  /// compares; the key itself is what the next delivery hands to OpenSSH so it
  /// can enforce the pin without scanning the server again.
  Future<void> _pinHostKey(
    ArtifactDestination destination,
    HostKeyScanEntry key,
  ) async {
    final id = destination.id;
    if (id == null) return;
    final decoded = jsonDecode(destination.configJson);
    final config = decoded is Map
        ? decoded.cast<String, Object?>()
        : <String, Object?>{};
    config['hostKeyFingerprint'] = key.fingerprint;
    config['hostKey'] = key.knownHostsKey;
    await _targets.update(id, configJson: jsonEncode(config));
  }
}
