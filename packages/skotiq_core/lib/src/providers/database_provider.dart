import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import '../database/database.dart' as db;
import '../models/equipment_profile.dart' as remote_profile;
import '../models/equipment_profile_remote_mapping.dart';
import '../database/daos/equipment_profiles_dao.dart';
import '../database/daos/targets_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/images_dao.dart';
import '../database/daos/sequences_dao.dart';
import '../database/daos/settings_dao.dart';
import '../database/daos/science_dao.dart';
import '../database/daos/guide_rms_history_dao.dart';
import '../database/daos/narrator_events_dao.dart';
import '../services/imaging_records_repository.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'host_settings/host_settings_providers.dart';

export 'project_tracking_provider.dart';

/// Global database instance provider
final databaseProvider = Provider<db.SkotiqDatabase>((ref) {
  final database = db.SkotiqDatabase();
  ref.onDispose(() => database.close());
  return database;
});

/// Equipment profiles DAO provider
final equipmentProfilesDaoProvider = Provider<EquipmentProfilesDao>((ref) {
  return EquipmentProfilesDao(ref.watch(databaseProvider));
});

/// Targets DAO provider
final targetsDaoProvider = Provider<TargetsDao>((ref) {
  return TargetsDao(ref.watch(databaseProvider));
});

/// Sessions DAO provider
final sessionsDaoProvider = Provider<SessionsDao>((ref) {
  return SessionsDao(ref.watch(databaseProvider));
});

/// Images DAO provider
final imagesDaoProvider = Provider<ImagesDao>((ref) {
  return ImagesDao(ref.watch(databaseProvider));
});

/// Sequences DAO provider
final sequencesDaoProvider = Provider<SequencesDao>((ref) {
  return SequencesDao(ref.watch(databaseProvider));
});

/// Settings DAO provider
///
/// On a linked client this reads and writes the imaging host's rows (see
/// [RemoteSettingsDao]); on the machine that owns the hardware it is this
/// computer's database. Rebuilt when [settingsStoreRevisionProvider] says the
/// rows changed underneath it, so providers that watch it re-read them.
final settingsDaoProvider = Provider<SettingsDao>((ref) {
  final database = ref.watch(databaseProvider);
  ref.watch(settingsStoreRevisionProvider);
  final store = ref.watch(hostSettingsStoreProvider);
  if (store == null) return SettingsDao(database);
  return buildRemoteSettingsDao(ref, store, database);
});

/// Science DAO provider
final scienceDaoProvider = Provider<ScienceDao>((ref) {
  return ScienceDao(ref.watch(databaseProvider));
});

/// Guide RMS history DAO provider.
final guideRmsHistoryDaoProvider = Provider<GuideRmsHistoryDao>((ref) {
  return GuideRmsHistoryDao(ref.watch(databaseProvider));
});

/// Night Narrator events DAO provider.
final narratorEventsDaoProvider = Provider<NarratorEventsDao>((ref) {
  return NarratorEventsDao(ref.watch(databaseProvider));
});

// Convenience providers for watching data
// Note: These use the database entity types (prefixed with db.)

/// Watch all equipment profiles
final allProfilesProvider = StreamProvider<List<db.EquipmentProfile>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteEquipmentProfiles(backend);
  }
  return ref.watch(equipmentProfilesDaoProvider).watchAllProfiles();
});

/// Watch the active equipment profile
final activeProfileProvider = StreamProvider<db.EquipmentProfile?>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteActiveProfile(backend);
  }
  return ref.watch(equipmentProfilesDaoProvider).watchActiveProfile();
});

/// Watch all targets (database entities)
final allDbTargetsProvider = StreamProvider<List<db.Target>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteTargets(backend);
  }
  return ref.watch(targetsDaoProvider).watchAllTargets();
});

/// Watch favorite targets (database entities)
final favoriteDbTargetsProvider = StreamProvider<List<db.Target>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteTargets(
      backend,
    ).map((targets) => targets.where((target) => target.isFavorite).toList());
  }
  return ref.watch(targetsDaoProvider).watchFavoriteTargets();
});

/// Watch all sequences (database entities)
final allDbSequencesProvider = StreamProvider<List<db.Sequence>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteSequenceRows(backend, templates: false);
  }
  return ref.watch(sequencesDaoProvider).watchAllSequences();
});

/// Watch all sequence templates (database entities)
final allDbTemplatesProvider = StreamProvider<List<db.Sequence>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteSequenceRows(backend, templates: true);
  }
  return ref.watch(sequencesDaoProvider).watchAllTemplates();
});

/// Watch all imaging sessions
final allSessionsProvider = StreamProvider<List<db.ImagingSession>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteSessions(backend);
  }
  return ref.watch(sessionsDaoProvider).watchAllSessions();
});

/// Watch all captured images (database entities)
final allDbImagesProvider = StreamProvider<List<db.CapturedImage>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteImages(backend);
  }
  return ref.watch(imagesDaoProvider).watchAllImages();
});

/// Load a captured image row by id.
final capturedImageByIdProvider = FutureProvider.family<db.CapturedImage?, int>(
  (ref, imageId) {
    final backend = ref.watch(backendProvider);
    if (backend is NetworkBackend) {
      return ref.watch(imagingRecordsRepositoryProvider).getImageById(imageId);
    }
    return ref.watch(imagesDaoProvider).getImageById(imageId);
  },
);

class CapturedImageWcsData {
  final int id;
  final bool isPlateSolved;
  final double? solvedRaHours;
  final double? solvedDecDegrees;
  final double? solvedRotationDegrees;
  final double? solvedPixelScaleArcsecPerPixel;

  const CapturedImageWcsData({
    required this.id,
    required this.isPlateSolved,
    required this.solvedRaHours,
    required this.solvedDecDegrees,
    required this.solvedRotationDegrees,
    required this.solvedPixelScaleArcsecPerPixel,
  });
}

final capturedImageWcsProvider =
    FutureProvider.family<CapturedImageWcsData?, int>((ref, imageId) async {
      final backend = ref.watch(backendProvider);
      db.CapturedImage? row;
      if (backend is NetworkBackend) {
        row = await ref.watch(capturedImageByIdProvider(imageId).future);
      } else {
        row = await ref.watch(imagesDaoProvider).getImageById(imageId);
      }
      if (row == null) {
        return null;
      }
      return CapturedImageWcsData(
        id: row.id,
        isPlateSolved: row.isPlateSolved,
        solvedRaHours: row.solvedRa,
        solvedDecDegrees: row.solvedDec,
        solvedRotationDegrees: row.solvedRotation,
        solvedPixelScaleArcsecPerPixel: row.solvedPixelScale,
      );
    });

/// Watch all settings as a map
final allSettingsProvider = StreamProvider<Map<String, String>>((ref) {
  return ref.watch(settingsDaoProvider).watchAllSettings();
});

Stream<List<db.EquipmentProfile>> _pollRemoteEquipmentProfiles(
  NetworkBackend backend,
) => _pollRemote(() => _fetchRemoteEquipmentProfiles(backend), listEquals);

Stream<db.EquipmentProfile?> _pollRemoteActiveProfile(NetworkBackend backend) =>
    _pollRemote(() => _fetchRemoteActiveProfile(backend), (a, b) => a == b);

Future<List<db.EquipmentProfile>> _fetchRemoteEquipmentProfiles(
  NetworkBackend backend,
) async {
  final profiles = await backend.getProfiles();
  return profiles.map(_equipmentProfileFromRemote).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
}

Future<db.EquipmentProfile?> _fetchRemoteActiveProfile(
  NetworkBackend backend,
) async {
  final active = await backend.getActiveProfile();
  if (active == null) {
    return null;
  }
  return _equipmentProfileFromRemote(active);
}

db.EquipmentProfile _equipmentProfileFromRemote(
  remote_profile.EquipmentProfile profile,
) {
  // Route through the single canonical converter so the slave's profile stream
  // stays lossless (carries safetyMonitorId/switchId/meridianFlipOverrides) and
  // never drifts from the host's `/api/profiles` mapping. No `existing` arg =>
  // the remote payload's own isDefault/isActive/sortOrder flags are carried
  // through, matching the host's row.
  return remoteProfileToDbRow(profile);
}

/// Polls [fetch] every [interval], emitting the first value and thereafter
/// ONLY when the value actually changes (per [unchanged]).
///
/// The remote list/profile providers below are backed by these polls, and the
/// planner's `tonightSuggestionsProvider` awaits those streams: an emission
/// that carries no change still reloads the whole suggestion pipeline and
/// blanks the Plan Tonight tab. The change-guard makes a quiet host emit
/// exactly once.
Stream<T> _pollRemote<T>(
  Future<T> Function() fetch,
  bool Function(T a, T b) unchanged, {
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: fetch,
  unchanged: unchanged,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote poll failed; retaining last value',
      name: 'DatabaseProvider',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);

Stream<List<db.Target>> _pollRemoteTargets(NetworkBackend backend) =>
    _pollRemote(() => _fetchRemoteTargets(backend), listEquals);

Stream<List<db.Sequence>> _pollRemoteSequenceRows(
  NetworkBackend backend, {
  required bool templates,
}) => _pollRemote(
  () => _fetchRemoteSequenceRows(backend, templates: templates),
  listEquals,
);

Stream<List<db.ImagingSession>> _pollRemoteSessions(NetworkBackend backend) =>
    _pollRemote(() => _fetchRemoteSessions(backend), listEquals);

Stream<List<db.CapturedImage>> _pollRemoteImages(NetworkBackend backend) =>
    _pollRemote(() => _fetchRemoteImages(backend), listEquals);

/// Polls the host's `/api/sequence-runs` and maps each [RemoteSequenceRun]
/// onto the local `SequenceRun` Drift row shape the run-history consumers read
/// (dashboard recap, cockpit Morning Report, sequencer History tab). The
/// slave's local `sequence_runs` table is never populated, so without this
/// poll those surfaces always render their empty state even after the master
/// imaged all night. [sequenceId] scopes the poll to a single sequence for the
/// family provider.
/// Public entry point used by `sequence_stats_provider.dart` so the
/// run-history providers can branch onto the remote transport without
/// re-implementing the poll/mapping (both file-private here).
Stream<List<db.SequenceRun>> pollRemoteSequenceRuns(
  NetworkBackend backend, {
  int? sequenceId,
}) => _pollRemoteRuns(backend, sequenceId: sequenceId);

/// Fetches the complete host run history, following the paginated API until
/// every row reported by the host has been received. Keeping this helper
/// shared prevents reports and live history surfaces from quietly diverging
/// once an installation has accumulated more than one response page.
Future<List<RemoteSequenceRun>> fetchAllRemoteSequenceRuns(
  NetworkBackend backend, {
  int? sequenceId,
}) async {
  const pageSize = 1000;
  final runs = <RemoteSequenceRun>[];
  var offset = 0;

  while (true) {
    final page = await backend.fetchSequenceRuns(
      sequenceId: sequenceId,
      limit: pageSize,
      offset: offset,
    );
    runs.addAll(page.items);
    offset += page.items.length;
    if (page.items.isEmpty || offset >= page.total) break;
  }

  return runs;
}

Stream<List<db.SequenceRun>> _pollRemoteRuns(
  NetworkBackend backend, {
  int? sequenceId,
}) => _pollRemote(
  () => _fetchRemoteRuns(backend, sequenceId: sequenceId),
  listEquals,
);

Future<List<db.SequenceRun>> _fetchRemoteRuns(
  NetworkBackend backend, {
  int? sequenceId,
}) async {
  final runs = await fetchAllRemoteSequenceRuns(
    backend,
    sequenceId: sequenceId,
  );
  final mapped = runs.map(_runRowFromRemote).toList();
  // Host endpoint already orders by startedAt desc; keep that invariant so the
  // ".first" the consumers read is the newest run.
  mapped.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return mapped;
}

db.SequenceRun _runRowFromRemote(RemoteSequenceRun run) {
  return db.SequenceRun(
    id: run.id,
    sequenceId: run.sequenceId,
    sequenceName: run.sequenceName ?? 'Sequence',
    startedAt: run.startedAt,
    endedAt: run.endedAt,
    status: run.status,
    statsJson: run.statsJson ?? '{}',
    // The wire row does not carry the executed-sequence snapshot (it is not
    // exposed by /api/sequence-runs); the run-history surfaces that consume
    // this stream do not read it, so leaving it null is lossless for them.
    sequenceSnapshotJson: null,
  );
}

Future<List<db.Target>> _fetchRemoteTargets(NetworkBackend backend) async {
  final targets = await backend.getAllTargets();
  return targets.map(_targetFromJson).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
}

Future<List<db.Sequence>> _fetchRemoteSequenceRows(
  NetworkBackend backend, {
  required bool templates,
}) async {
  final rows = templates
      ? await backend.getSequenceTemplates()
      : await backend.getSequenceList();
  final mapped = rows.map(_sequenceRowFromRemoteJson).toList();
  mapped.sort((a, b) => a.name.compareTo(b.name));
  return mapped;
}

db.Sequence _sequenceRowFromRemoteJson(Map<String, dynamic> json) {
  return db.Sequence(
    id: json['id'] as int,
    name: json['name'] as String? ?? 'Untitled sequence',
    description: json['description'] as String?,
    rootNodeId: json['rootNodeId'] as String?,
    estimatedDurationMins: json['estimatedDurationMins'] as int? ?? 0,
    createdAt: wireTimestamp(json['createdAt']),
    updatedAt: wireTimestamp(json['updatedAt']),
    isTemplate: json['isTemplate'] as bool? ?? false,
    tagsJson: json['tagsJson'] as String? ?? '[]',
    isFavorite: json['isFavorite'] as bool? ?? false,
  );
}

Future<List<db.ImagingSession>> _fetchRemoteSessions(
  NetworkBackend backend,
) async {
  final sessions = await backend.getAllSessions();
  final mapped = sessions.map(imagingSessionFromWireJson).toList();
  // Match SessionsDao.watchAllSessions: newest session first. Several
  // consumers intentionally use `.first` as the most recent session.
  mapped.sort((a, b) => b.startTime.compareTo(a.startTime));
  return mapped;
}

Future<List<db.CapturedImage>> _fetchRemoteImages(
  NetworkBackend backend,
) async {
  final images = await backend.getAllImageRows();
  final mapped = images.map(_imageFromJson).toList();
  // Match ImagesDao.watchAllImages: newest capture first.
  mapped.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  return mapped;
}

db.Target _targetFromJson(Map<String, dynamic> json) {
  return db.Target(
    id: json['id'] as int,
    name: json['name'] as String? ?? 'Untitled target',
    catalogId: json['catalogId'] as String?,
    objectType: json['objectType'] as String?,
    ra: (json['ra'] as num?)?.toDouble() ?? 0.0,
    dec: (json['dec'] as num?)?.toDouble() ?? 0.0,
    positionAngle: (json['positionAngle'] as num?)?.toDouble(),
    magnitude: (json['magnitude'] as num?)?.toDouble(),
    constellation: json['constellation'] as String?,
    sizeArcmin: (json['sizeArcmin'] as num?)?.toDouble(),
    minAltitude: (json['minAltitude'] as num?)?.toDouble() ?? 30.0,
    priority: json['priority'] as int? ?? 5,
    totalPlannedSubs: json['totalPlannedSubs'] as int? ?? 0,
    capturedSubs: json['capturedSubs'] as int? ?? 0,
    totalIntegrationSecs:
        (json['totalIntegrationSecs'] as num?)?.toDouble() ?? 0.0,
    goalIntegrationSecs:
        (json['goalIntegrationSecs'] as num?)?.toDouble() ?? 0.0,
    filterProgress: json['filterProgress'] as String?,
    notes: json['notes'] as String?,
    createdAt: wireTimestamp(json['createdAt']),
    updatedAt: wireTimestamp(json['updatedAt']),
    isFavorite: json['isFavorite'] as bool? ?? false,
  );
}

db.CapturedImage _imageFromJson(Map<String, dynamic> json) {
  return db.CapturedImage.fromJson(json);
}
