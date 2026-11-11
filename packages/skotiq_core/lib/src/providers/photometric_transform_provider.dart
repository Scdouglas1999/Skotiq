import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' show PhotometricTransformRow;
import '../utils/resilient_poll_stream.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// Watches transforms relevant to the current equipment profile.
final activeProfileTransformsProvider =
    StreamProvider<List<PhotometricTransformRow>>((ref) {
      final backend = ref.watch(backendProvider);
      final remote = backend.remoteHost?.history;
      final profileId = ref.watch(activeEquipmentProfileIdProvider);
      if (remote != null) {
        return _pollRemoteTransforms(
          remote,
          profileId: profileId,
          interval: ref.watch(remotePhotometricTransformPollIntervalProvider),
        );
      }
      return ref.watch(scienceDaoProvider).watchTransformsForProfile(profileId);
    });

final activeEquipmentProfileIdProvider = Provider<int?>((ref) {
  final profile = ref.watch(activeProfileProvider).valueOrNull;
  return profile?.id;
});

/// Host transform catalogs are low-churn. Exposed for deterministic poll
/// recovery tests without waiting for the production interval.
final remotePhotometricTransformPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 10),
);

Stream<List<PhotometricTransformRow>> _pollRemoteTransforms(
  HostHistory remote, {
  int? profileId,
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: () => remote.getPhotometricTransforms(profileId: profileId),
  unchanged: listEquals,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote photometric-transform poll failed; retaining last value',
      name: 'PhotometricTransformProvider',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);
