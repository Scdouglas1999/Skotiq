part of '../quick_start_service.dart';

Future<CheckpointInfo?> _safeCheckpointInfo(SkotiqBackend backend) async {
  try {
    return await backend.getCheckpointInfo();
  } catch (error, stackTrace) {
    developer.log(
      'QuickStartService: checkpoint availability check failed: $error',
      name: 'QuickStartService',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

bool _isRecentCompletedSession(db.ImagingSession session, DateTime now) {
  final age = now.difference(session.startTime);
  final hasProgress =
      session.successfulExposures > 0 || session.totalIntegrationSecs > 0;
  return session.status == 'completed' && age.inDays <= 7 && hasProgress;
}

/// Builds Quick Start contexts from the same host-aware streams used by the
/// Analytics and library screens. Remote controllers must not consult their
/// empty local session/target/sequence tables.
Future<List<QuickStartContext>> _remoteQuickStartContexts(
  Ref ref,
  NetworkBackend backend, {
  required int limit,
}) async {
  final sessionsFuture = ref.watch(allSessionsProvider.future);
  final targetsFuture = ref.watch(allDbTargetsProvider.future);
  final sequencesFuture = ref.watch(allDbSequencesProvider.future);
  final profilesFuture = ref.watch(allProfilesProvider.future);
  final checkpointFuture = _safeCheckpointInfo(backend);

  final sessions = List<db.ImagingSession>.from(await sessionsFuture)
    ..sort((a, b) => b.startTime.compareTo(a.startTime));
  final targets = await targetsFuture;
  final sequences = await sequencesFuture;
  final profiles = await profilesFuture;
  final checkpoint = await checkpointFuture;

  final candidates = <db.ImagingSession>[];
  candidates.addAll(sessions.where((session) => session.status == 'active'));
  final now = DateTime.now();
  for (final session in sessions) {
    if (candidates.length >= limit) break;
    if (_isRecentCompletedSession(session, now)) {
      candidates.add(session);
    }
  }

  final targetById = {for (final target in targets) target.id: target};
  final sequenceById = {
    for (final sequence in sequences) sequence.id: sequence,
  };
  final profileById = {for (final profile in profiles) profile.id: profile};

  final contexts = <QuickStartContext>[];
  for (final session in candidates.take(limit)) {
    final target = session.targetId == null
        ? null
        : targetById[session.targetId!];
    final sequence = session.sequenceId == null
        ? null
        : sequenceById[session.sequenceId!];
    final profile = session.profileId == null
        ? null
        : profileById[session.profileId!];

    EquipmentSnapshot? snapshot;
    final snapshotJson = session.equipmentSnapshot;
    if (snapshotJson != null && snapshotJson.isNotEmpty) {
      try {
        snapshot = EquipmentSnapshot.fromJsonString(snapshotJson);
      } catch (error, stackTrace) {
        developer.log(
          'QuickStartService: failed to parse host equipment snapshot: $error',
          name: 'QuickStartService',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    final context = QuickStartContext(
      sessionId: session.id,
      sessionName: session.name,
      profileId: session.profileId,
      profileName: profile?.name,
      targetId: session.targetId,
      targetName: target?.name,
      targetRa: target?.ra,
      targetDec: target?.dec,
      sequenceId: session.sequenceId,
      sequenceName: sequence?.name,
      completedFrames: session.successfulExposures,
      totalFrames: session.totalExposures,
      lastSessionDate: session.endTime ?? session.startTime,
      equipmentSnapshot: snapshot,
      totalIntegrationHours: session.totalIntegrationSecs / 3600.0,
    );
    contexts.add(context.withCheckpointInfo(checkpoint));
  }
  return contexts;
}

/// Provider for the QuickStartService
final quickStartServiceProvider = Provider<QuickStartService>((ref) {
  return QuickStartService(
    sessionsDao: ref.watch(sessionsDaoProvider),
    profilesDao: ref.watch(equipmentProfilesDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
    sequencesDao: ref.watch(sequencesDaoProvider),
    checkpointsDao: ref.watch(sequenceCheckpointsDaoProvider),
    resolveProfileName: (profileId) async {
      final backend = ref.read(backendProvider);
      if (backend is NetworkBackend) {
        final profiles = await backend.getProfiles();
        for (final profile in profiles) {
          if (int.tryParse(profile.id) == profileId) {
            return profile.name;
          }
        }
        return null;
      }

      final state = ref.read(equipmentProfilesProvider).valueOrNull;
      if (state != null) {
        for (final profile in state.profiles) {
          if (profile.id == profileId) {
            return profile.name;
          }
        }
      }

      final profile = await ref
          .read(equipmentProfilesDaoProvider)
          .getProfileById(profileId);
      return profile?.name;
    },
  );
});

/// Provider for the quick start context (most recent session)
final quickStartContextProvider = FutureProvider<QuickStartContext?>((
  ref,
) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final contexts = await _remoteQuickStartContexts(ref, backend, limit: 1);
    return contexts.isEmpty ? null : contexts.first;
  }
  final service = ref.watch(quickStartServiceProvider);
  final context = await service.getQuickStartContext();
  if (context == null) return null;
  final checkpoint = await _safeCheckpointInfo(backend);
  return context.withCheckpointInfo(checkpoint);
});

/// Provider for checking if quick start is available
final quickStartAvailableProvider = FutureProvider<bool>((ref) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return (await _remoteQuickStartContexts(ref, backend, limit: 1)).isNotEmpty;
  }
  final service = ref.watch(quickStartServiceProvider);
  return service.isQuickStartAvailable();
});

/// Provider for multiple quick start contexts (for session list display)
final quickStartContextsProvider =
    FutureProvider.family<List<QuickStartContext>, int>((ref, limit) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteQuickStartContexts(ref, backend, limit: limit);
      }
      final service = ref.watch(quickStartServiceProvider);
      final contexts = await service.getQuickStartContexts(limit: limit);
      final checkpoint = await _safeCheckpointInfo(backend);
      return contexts
          .map((context) => context.withCheckpointInfo(checkpoint))
          .toList(growable: false);
    });
