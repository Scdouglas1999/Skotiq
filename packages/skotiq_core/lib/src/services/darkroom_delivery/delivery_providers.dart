/// Riverpod wiring for Darkroom delivery.
///
/// The services take their collaborators as constructor arguments so tests can
/// substitute a scripted transport, a fake keyring or a fixed clock. These
/// providers are the production assembly of the same pieces, and they are what
/// the dawn autopilot and the headless delivery endpoints read.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/delivery_journal_dao.dart';
import '../../database/daos/delivery_targets_dao.dart';
import '../../providers/notification_router_provider.dart'
    show secretsStoreProvider;
import '../logging_service.dart';
import 'delivery_retry_sweeper.dart';
import 'delivery_service.dart';
import 'delivery_transport_factory.dart';
import 'peer_manifest_service.dart';

/// Builds the transport for a destination row: filesystem for a watched
/// folder, OpenSSH for SFTP, and a journal publication for a peer.
final artifactTransportFactoryProvider = Provider<ArtifactTransportFactory>((
  ref,
) {
  final factory = DefaultArtifactTransportFactory(
    secrets: ref.watch(secretsStoreProvider),
    targets: ref.watch(deliveryTargetsDaoProvider),
  );
  return factory.call;
});

/// Delivers a finished dawn job's artifacts and runs the overnight retry
/// sweep.
final deliveryServiceProvider = Provider<DeliveryService>((ref) {
  return DeliveryService(
    targets: ref.watch(deliveryTargetsDaoProvider),
    journal: ref.watch(deliveryJournalDaoProvider),
    transportFactory: ref.watch(artifactTransportFactoryProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});

/// The overnight driver for the retry sweep.
///
/// A `Provider` rather than a bootstrap-local object so the GUI and the daemon
/// arm the same instance the rest of the graph would see. The timer is armed by
/// the one seam that runs in every mode owning this journal —
/// `resumeDarkroomWork` in the desktop bootstrap — and closed with the
/// container. Reading this provider alone starts nothing, because a sweeper
/// that armed itself on first read would arm from the settings page that merely
/// wanted to ask it for a single pass.
final deliveryRetrySweeperProvider = Provider<DeliveryRetrySweeper>((ref) {
  final sweeper = DeliveryRetrySweeper(
    delivery: ref.watch(deliveryServiceProvider),
    logger: ref.watch(loggingServiceProvider),
  );
  ref.onDispose(() => unawaited(sweeper.dispose()));
  return sweeper;
});

/// Serves the peer-pull surface: the manifest a paired desktop reads, the ids
/// it resolves, and the acknowledgement that closes a published row.
final peerManifestServiceProvider = Provider<PeerManifestService>((ref) {
  return PeerManifestService(
    targets: ref.watch(deliveryTargetsDaoProvider),
    journal: ref.watch(deliveryJournalDaoProvider),
  );
});
