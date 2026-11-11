import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import '../database/database.dart' as db;
import '../models/imaging/imaging_models.dart';
import '../models/imaging/auto_stretch_settings.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import '../services/darkroom_build_service.dart'
    show observingNight, observingNightWindow;
import 'host_settings/host_settings_providers.dart'
    show settingsRowChangesProvider;
import 'profiles_provider.dart';
import 'session_provider.dart';
import 'settings_provider.dart';
import 'runtime_mirror/channels/session_frames_channel.dart'
    show hostSessionFrameIdsProvider;
import 'sequence/last_ended_run.dart' show lastEndedRunProvider;

/// Current exposure settings
final exposureSettingsProvider = StateProvider<ExposureSettings>((ref) {
  return const ExposureSettings(
    // A snapshot is an operator probe, not a deep-sky integration. Keep the
    // cold-start value short enough that an accidental click cannot waste a
    // night; the user's last settings are restored per equipment profile.
    exposureTime: 2,
    gain: 100,
    offset: 50,
    binningX: 1,
    binningY: 1,
    frameType: FrameType.light,
  );
});

/// Compatibility flag used by the existing camera controls. The profile key and
/// revision providers below carry the information needed by persistence.
final exposureSettingsUserDirtyProvider = StateProvider<bool>((ref) => false);

final _manualExposureRevisionProvider = StateProvider<int>((ref) => 0);
final _exposureWriteTailProvider = StateProvider<Future<void>>(
  (ref) => Future<void>.value(),
);

String _exposureProfileKey(EquipmentProfileModel profile) =>
    profile.id?.toString() ?? profile.name;

/// Update a manual snapshot setting and persist it for the active equipment
/// profile. Hydration uses the provider state directly, so it cannot enqueue a
/// write or overwrite a newer manual edit.
void updateManualExposureSettings(Ref ref, ExposureSettings settings) {
  final profile = ref.read(activeEquipmentProfileProvider);
  final previous = ref.read(exposureSettingsProvider);
  ref.read(exposureSettingsUserDirtyProvider.notifier).state = true;
  ref.read(_manualExposureRevisionProvider.notifier).state++;
  ref.read(exposureSettingsProvider.notifier).state = settings;
  if (profile == null) return;

  final key = exposureSettingsKeyFor(profile);
  // Store only the fields this edit changed, laid over the row as it is now.
  // The host and every linked client edit the same row, so writing the whole
  // object from this screen's copy reverted whatever another screen had just
  // changed (gain set on one side, exposure on the other: one was lost).
  final full = _exposureSettingsToJson(settings);
  final before = _exposureSettingsToJson(previous);
  final changed = <String, Object?>{
    for (final entry in full.entries)
      if (before[entry.key] != entry.value) entry.key: entry.value,
  };
  if (changed.isEmpty) return;
  Future<void> save() async {
    try {
      await ref
          .read(settingsDaoProvider)
          .mergeJsonObjectSetting(key, changed, base: full);
    } catch (error, stack) {
      developer.log(
        'Failed to save manual capture settings: $error',
        name: 'ImagingSettings',
        level: 1000,
        error: error,
        stackTrace: stack,
      );
    }
  }

  final tail = ref.read(_exposureWriteTailProvider);
  final recovered = tail.then<void>((_) {}, onError: (_, __) {});
  final next = recovered.then<void>((_) => save());
  ref.read(_exposureWriteTailProvider.notifier).state = next;
  ref.read(_exposureWritesInFlightProvider.notifier).state++;
  unawaited(
    next.whenComplete(() {
      final int left;
      try {
        left = --ref.read(_exposureWritesInFlightProvider.notifier).state;
      } on StateError {
        // The container was disposed while the write ran; nothing to update.
        return;
      }
      // The stored row now holds this edit merged with any field another
      // screen changed meanwhile; a change announced while this write was in
      // flight was not applied, so take the row as stored.
      if (left == 0) {
        unawaited(_reloadExposureSettings(ref, profile, key, () => false));
      }
    }),
  );
}

/// Manual capture-settings writes not yet stored. While one is pending, a
/// changed row is not re-read: it could only bring back an older value.
final _exposureWritesInFlightProvider = StateProvider<int>((ref) => 0);

/// The `app_settings` key holding [profile]'s manual capture settings.
String exposureSettingsKeyFor(EquipmentProfileModel profile) =>
    'imaging_capture_settings_profile_${_exposureProfileKey(profile)}';

/// Façade for callers that own a provider container/ref.
final manualExposureSettingsUpdaterProvider =
    Provider<ManualExposureSettingsUpdater>((ref) {
      return ManualExposureSettingsUpdater(ref);
    });

class ManualExposureSettingsUpdater {
  final Ref _ref;

  const ManualExposureSettingsUpdater(this._ref);

  void update(ExposureSettings settings) =>
      updateManualExposureSettings(_ref, settings);
}

/// Call this provider from the imaging screen's initState/build to ensure
/// snapshot controls are initialized from the active equipment profile.
///
/// On first call (or when the active profile changes), this restores the
/// profile's last manual snapshot settings. New profiles receive camera
/// defaults for gain/offset/binning. Smart Night recommendations are applied by
/// sequencing, never by the manual imaging screen.
final syncExposureFromProfileProvider = Provider<void>((ref) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return;

  var disposed = false;
  String? loadedProfileKey;
  var loadInFlight = false;
  ref.onDispose(() => disposed = true);

  Future<void>.microtask(() {
    final profileKey = profile.id?.toString() ?? profile.name;
    if (disposed || loadInFlight || loadedProfileKey == profileKey) return;
    loadInFlight = true;

    final revisionAtStart = ref.read(_manualExposureRevisionProvider);
    () async {
      final dao = ref.read(settingsDaoProvider);
      final key = 'imaging_capture_settings_profile_$profileKey';
      ExposureSettings? saved;
      try {
        final value = await dao.getSetting(key);
        if (value != null && value.isNotEmpty) {
          saved = _exposureSettingsFromJson(jsonDecode(value));
        }
      } catch (_) {
        saved = null;
      }
      final currentProfile = ref.read(activeEquipmentProfileProvider);
      if (disposed ||
          currentProfile == null ||
          _exposureProfileKey(currentProfile) != profileKey) {
        return;
      }
      loadedProfileKey = profileKey;
      loadInFlight = false;
      // A manual edit completed while the DAO was reading. Its value is
      // newer than the stored snapshot and must win the race.
      if (ref.read(_manualExposureRevisionProvider) != revisionAtStart) {
        return;
      }
      if (disposed) return;
      if (saved != null) {
        ref.read(exposureSettingsProvider.notifier).state = saved;
        return;
      }

      ref.read(exposureSettingsProvider.notifier).state = ExposureSettings(
        exposureTime: 2,
        gain: profile.defaultGain ?? 100,
        offset: profile.defaultOffset ?? 50,
        binningX: profile.defaultBinX,
        binningY: profile.defaultBinY,
        frameType: FrameType.light,
      );
    }();
  });

  // Follow the row when it changes under this screen: on the host when a
  // linked client or a script writes it, on a client when the host's screen or
  // another client does. Without this each side showed its own values until
  // the profile changed, and the next edit wrote them back over the other's.
  final key = exposureSettingsKeyFor(profile);
  final changes = ref.read(settingsRowChangesProvider).stream.listen((keys) {
    if (!keys.contains(key)) return;
    unawaited(_reloadExposureSettings(ref, profile, key, () => disposed));
  });
  ref.onDispose(changes.cancel);
});

Future<void> _reloadExposureSettings(
  Ref ref,
  EquipmentProfileModel profile,
  String key,
  bool Function() disposed,
) async {
  try {
    if (ref.read(_exposureWritesInFlightProvider) > 0) return;
    final revisionAtStart = ref.read(_manualExposureRevisionProvider);
    ExposureSettings? stored;
    try {
      final value = await ref.read(settingsDaoProvider).getSetting(key);
      if (value != null && value.isNotEmpty) {
        stored = _exposureSettingsFromJson(jsonDecode(value));
      }
    } on Object catch (error) {
      developer.log(
        'Could not re-read the capture settings after a change: $error',
        name: 'ImagingSettings',
        level: 900,
      );
      return;
    }
    if (disposed() || stored == null) return;
    final current = ref.read(activeEquipmentProfileProvider);
    if (current == null ||
        _exposureProfileKey(current) != _exposureProfileKey(profile)) {
      return;
    }
    // An edit made on this screen while the row was being read is newer.
    if (ref.read(_manualExposureRevisionProvider) != revisionAtStart ||
        ref.read(_exposureWritesInFlightProvider) > 0) {
      return;
    }
    if (ref.read(exposureSettingsProvider) != stored) {
      ref.read(exposureSettingsProvider.notifier).state = stored;
    }
  } on StateError {
    // The container was disposed while the row was being read.
  }
}

Map<String, dynamic> _exposureSettingsToJson(ExposureSettings settings) => {
  'exposureTime': settings.exposureTime,
  'gain': settings.gain,
  'offset': settings.offset,
  'binningX': settings.binningX,
  'binningY': settings.binningY,
  'filter': settings.filter,
  'frameType': settings.frameType.name,
  'fastReadout': settings.fastReadout,
  'readoutModeIndex': settings.readoutModeIndex,
};

ExposureSettings? _exposureSettingsFromJson(dynamic value) {
  if (value is! Map) return null;
  final exposure = (value['exposureTime'] as num?)?.toDouble();
  final gain = (value['gain'] as num?)?.toInt();
  final offset = (value['offset'] as num?)?.toInt();
  if (exposure == null ||
      !exposure.isFinite ||
      exposure <= 0 ||
      gain == null ||
      offset == null) {
    return null;
  }
  final frameName = value['frameType'] as String?;
  final frameType = FrameType.values.firstWhere(
    (type) => type.name == frameName,
    orElse: () => FrameType.light,
  );
  return ExposureSettings(
    exposureTime: exposure,
    gain: gain,
    offset: offset,
    binningX: (value['binningX'] as num?)?.toInt() ?? 1,
    binningY: (value['binningY'] as num?)?.toInt() ?? 1,
    filter: value['filter'] as String?,
    frameType: frameType,
    fastReadout: value['fastReadout'] as bool? ?? false,
    readoutModeIndex: (value['readoutModeIndex'] as num?)?.toInt(),
  );
}

/// Last captured image stats
final lastImageStatsProvider = StateProvider<ImageStats?>((ref) => null);

/// Auto-stretch settings with method selection and advanced parameters.
///
/// Settings are persisted to the database and loaded on startup.
final autoStretchSettingsProvider =
    StateNotifierProvider<AutoStretchSettingsNotifier, AutoStretchSettings>(
      (ref) => AutoStretchSettingsNotifier(ref),
    );

/// StateNotifier for auto-stretch settings with database persistence.
class AutoStretchSettingsNotifier extends StateNotifier<AutoStretchSettings> {
  final Ref _ref;
  bool _isLoaded = false;
  AutoStretchSettings _confirmedSettings = AutoStretchSettings.defaults();
  AutoStretchSettings _requestedSettings = AutoStretchSettings.defaults();
  int _requestRevision = 0;
  Future<void> _writeTail = Future<void>.value();
  Future<void> _requestedWrite = Future<void>.value();

  AutoStretchSettingsNotifier(this._ref)
    : super(AutoStretchSettings.defaults()) {
    _loadSettings();
  }

  /// Load settings from database on startup.
  Future<void> _loadSettings() async {
    if (_isLoaded) return;
    _isLoaded = true;
    final revisionAtStart = _requestRevision;

    try {
      final dao = _ref.read(settingsDaoProvider);
      final json = await dao.getAutoStretchSettings();
      if (json != null &&
          json.isNotEmpty &&
          revisionAtStart == _requestRevision &&
          mounted) {
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final loaded = AutoStretchSettings.fromJson(decoded);
        _confirmedSettings = loaded;
        _requestedSettings = loaded;
        state = loaded;
      }
    } catch (e) {
      developer.log(
        'Failed to load auto-stretch settings: $e',
        name: 'AutoStretch',
        level: 1000,
      );
    }
  }

  /// Update settings and persist to database.
  ///
  /// Skips the state update (and downstream rebuild of stretched image
  /// providers) when the new settings are identical to the current ones.
  Future<void> update(AutoStretchSettings newSettings) {
    if (_requestedSettings == newSettings) return _requestedWrite;

    _requestedSettings = newSettings;
    final revision = ++_requestRevision;
    state = newSettings;
    final operation = _writeTail.then((_) async {
      try {
        await _persistSettings(newSettings);
        _confirmedSettings = newSettings;
      } catch (_) {
        if (revision == _requestRevision && mounted) {
          _requestedSettings = _confirmedSettings;
          state = _confirmedSettings;
        }
        rethrow;
      }
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    _requestedWrite = operation;
    return operation;
  }

  /// Persist a captured settings snapshot to the database.
  Future<void> _persistSettings(AutoStretchSettings settings) async {
    try {
      final dao = _ref.read(settingsDaoProvider);
      final json = jsonEncode(settings.toJson());
      await dao.setAutoStretchSettings(json);
    } catch (e) {
      developer.log(
        'Failed to save auto-stretch settings: $e',
        name: 'AutoStretch',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Reset to default settings.
  Future<void> reset() => update(AutoStretchSettings.defaults());
}

/// Cooling settings
final coolingSettingsProvider = StateProvider<CoolingSettings>((ref) {
  return const CoolingSettings();
});

/// Cooling status (read from camera)
final coolingStatusProvider = StateProvider<CoolingStatus>((ref) {
  return const CoolingStatus();
});

/// Focus/Autofocus panel settings.
///
/// The autofocus fields (step size, steps out, exposure, exposures per point,
/// method) are the persisted autofocus settings: an edit on the panel is saved
/// to them, and a change saved anywhere else (Settings, the host's screen, a
/// linked client) shows on the panel. The manual nudge step size is this
/// screen's own and is kept in memory.
final focusSettingsProvider =
    StateNotifierProvider<FocusSettingsNotifier, FocusSettings>((ref) {
      return FocusSettingsNotifier(ref);
    });

/// Holds the focus panel's values; see [focusSettingsProvider].
class FocusSettingsNotifier extends StateNotifier<FocusSettings> {
  final Ref _ref;

  /// Panel edits still being saved. While one is, the persisted values can
  /// only be older than the panel's, so they are not taken.
  int _pendingWrites = 0;

  /// Whether the manual step size has been seeded or edited. It starts from
  /// the autofocus step size once, then is this screen's own.
  bool _manualStepSet = false;

  FocusSettingsNotifier(this._ref) : super(const FocusSettings()) {
    _ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (_, next) {
      final settings = next.valueOrNull;
      if (settings != null) _adopt(settings);
    });
    _loadFromAppSettings();
  }

  Future<void> _loadFromAppSettings() async {
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (!mounted) return;
      _adopt(settings);
    } catch (e) {
      developer.log(
        'Failed to initialize focus settings from app settings: $e',
        name: 'FocusSettings',
        level: 1000,
      );
    }
  }

  /// Take the persisted autofocus values.
  void _adopt(AppSettingsState settings) {
    if (!mounted || _pendingWrites > 0) return;
    final seedStep = !_manualStepSet;
    _manualStepSet = true;
    final next = state.copyWith(
      stepSize: seedStep ? settings.afStepSize : null,
      method: settings.afMethod,
      afStepSize: settings.afStepSize,
      stepsOut: settings.afInitialOffsetSteps,
      exposuresPerPoint: settings.afExposuresPerPoint,
      exposureTime: settings.afExposureTime,
    );
    if (next != state) state = next;
  }

  /// Apply an edit from the panel and save the autofocus fields it changed.
  void update(FocusSettings newSettings) {
    final before = state;
    state = newSettings;
    if (newSettings.stepSize != before.stepSize) _manualStepSet = true;
    _pendingWrites++;
    unawaited(
      _persist(before, newSettings).whenComplete(() {
        _pendingWrites--;
        final settings = _ref.read(appSettingsProvider).valueOrNull;
        if (_pendingWrites == 0 && settings != null) _adopt(settings);
      }),
    );
  }

  Future<void> _persist(FocusSettings before, FocusSettings next) async {
    try {
      // Saving needs the loaded settings; an edit made before they arrive is
      // saved once they do.
      await _ref.read(appSettingsProvider.future);
      final notifier = _ref.read(appSettingsProvider.notifier);
      if (next.afStepSize != before.afStepSize) {
        await notifier.setAfStepSize(next.afStepSize);
      }
      if (next.stepsOut != before.stepsOut) {
        await notifier.setAfInitialOffsetSteps(next.stepsOut);
      }
      if (next.exposureTime != before.exposureTime) {
        await notifier.setAfExposureTime(next.exposureTime);
      }
      if (next.exposuresPerPoint != before.exposuresPerPoint) {
        await notifier.setAfExposuresPerPoint(next.exposuresPerPoint);
      }
      if (next.method != before.method) {
        await notifier.setAfMethod(next.method);
      }
    } catch (error) {
      developer.log(
        'Could not save the autofocus panel setting: $error',
        name: 'FocusSettings',
        level: 1000,
      );
    }
  }
}

/// Dither settings for guiding (persists across navigation)
final ditherSettingsProvider = StateProvider<DitherSettings>((ref) {
  return const DitherSettings();
});

/// Slew coordinates for mount tab (persists across navigation)
final slewCoordinatesProvider = StateProvider<SlewCoordinates>((ref) {
  return const SlewCoordinates();
});

/// Selected imaging panel index (persists across navigation)
/// 0 = Capture, 1 = Focus, 2 = Mount, 3 = Guider
final selectedImagingPanelProvider = StateProvider<int>((ref) => 0);

/// File naming pattern derived from persisted settings
final namingPatternProvider = Provider<NamingPattern>((ref) {
  final settings = ref.watch(
    appSettingsProvider.select(
      (settingsAsync) => settingsAsync.valueOrNull == null
          ? null
          : (
              pattern: settingsAsync.valueOrNull!.fileNamingPattern,
              outputPath: settingsAsync.valueOrNull!.imageOutputPath,
              format: settingsAsync.valueOrNull!.imageFormat,
            ),
    ),
  );

  if (settings == null) {
    return const NamingPattern();
  }

  // Captures are currently persisted through the native FITS writer. This
  // defensive coercion also protects callers while a legacy/remote settings
  // snapshot is being migrated by appSettingsProvider.
  const format = ImageFileFormat.fits;
  final baseDir = settings.outputPath.isEmpty ? '.' : settings.outputPath;

  return NamingPattern(
    pattern: settings.pattern,
    baseDir: baseDir,
    format: format,
  );
});

/// Session captured images
final sessionImagesProvider =
    StateNotifierProvider<SessionImagesNotifier, List<CapturedImage>>((ref) {
      return SessionImagesNotifier();
    });

/// The session frames list: every kept frame of the observing night (local
/// noon to noon, the night Darkroom groups by), oldest first.
///
/// It lived only in memory, so a crash, an update or a restart mid-night
/// emptied it, and the restored run's frames started a new list: the host and
/// every linked client then showed a night that began at the restart.
/// [seedNight] rebuilds it from the database at startup; a frame already in
/// the list is never added twice, and the first frame of the next night
/// starts a new list.
class SessionImagesNotifier extends StateNotifier<List<CapturedImage>> {
  SessionImagesNotifier() : super([]);

  void addImage(CapturedImage image) {
    if (state.any((existing) => existing.id == image.id)) return;
    final night = observingNight(image.capturedAt);
    if (state.isNotEmpty && observingNight(state.last.capturedAt) != night) {
      state = [image];
      return;
    }
    state = [...state, image];
  }

  /// Merge the night's frames read from the database into the list.
  ///
  /// [frames] are the kept frames of the night containing [now]; anything in
  /// the list from another night is dropped.
  void seedNight(List<CapturedImage> frames, {required DateTime now}) {
    final night = observingNight(now);
    final byId = <String, CapturedImage>{
      for (final image in frames)
        if (observingNight(image.capturedAt) == night) image.id: image,
      for (final image in state)
        if (observingNight(image.capturedAt) == night) image.id: image,
    };
    state = byId.values.toList()
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }

  void removeImage(String id) {
    state = state.where((img) => img.id != id).toList();
  }

  void clearSession() {
    state = [];
  }

  int get count => state.length;

  Duration get totalExposureTime {
    return state.fold(
      Duration.zero,
      (total, img) =>
          total + Duration(seconds: img.settings.exposureTime.round()),
    );
  }
}

/// Seeds [sessionImagesProvider] with the observing night's kept frames from
/// the database, on the process that owns it. Watch it for the whole app.
///
/// "Kept" is what the run's frame recorder and the capture pipeline add to
/// the list as frames land: rows still accepted (a grader's reject or a
/// frame-watch exclusion clears `is_accepted`).
final sessionNightSeedProvider = FutureProvider<void>((ref) async {
  if (ref.watch(backendProvider) is NetworkBackend) return;
  final now = DateTime.now();
  final window = observingNightWindow(now);
  final rows = await ref
      .read(imagesDaoProvider)
      .getImagesCapturedBetween(window.start, window.end);
  ref
      .read(sessionImagesProvider.notifier)
      .seedNight(
        [
          for (final row in rows)
            if (row.isAccepted) capturedImageFromDbRow(row),
        ],
        now: now,
      );
});

/// Recent frames for the active session, remote-aware.
///
/// On the host this is exactly the in-memory [sessionImagesProvider] list (the
/// local capture loop populates it). On a slave (NetworkBackend) the master is
/// the node actually imaging, so those frames never reach the local in-memory
/// list — instead this branches onto the already remote-aware
/// [allDbImagesProvider] (which polls the host's `/api/images`), filters to the
/// active session's `dbSessionId`, and maps each Drift row back onto the
/// in-memory [CapturedImage] shape the cockpit/strip widgets render. Ordering
/// matches [sessionImagesProvider]: oldest-first (capture order), so the
/// consumers' "take the tail, reverse to newest-first" logic is unchanged.
///
/// The session id itself is also remote-aware. `dbSessionId` is only ever set
/// locally by [SessionStateNotifier.startSession] / `recoverSession`, so a
/// phone or tablet that merely *watches* a host-started run never has one. When
/// the local id is absent this falls back to the host's own active session,
/// using the same `status == 'active'` invariant
/// `SessionsDao.getActiveSessions` relies on.
///
/// A host that shares its own list (see `SessionFramesChannel`) settles all
/// of that: the client shows the host's frames, in the host's order, so the
/// two count the same frames whenever the client connected.
final recentSessionFramesProvider = Provider<List<CapturedImage>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! NetworkBackend) {
    return ref.watch(sessionImagesProvider);
  }

  final hostIds = ref.watch(hostSessionFrameIdsProvider);
  if (hostIds != null) {
    if (hostIds.isEmpty) return const <CapturedImage>[];
    final rows = ref.watch(allDbImagesProvider).valueOrNull;
    if (rows == null) return const <CapturedImage>[];
    final byId = {for (final row in rows) row.id: row};
    return [
      for (final id in hostIds)
        if (byId[id] case final db.CapturedImage row)
          capturedImageFromDbRow(row),
    ];
  }

  var sessionId = ref.watch(
    sessionStateProvider.select((state) => state.dbSessionId),
  );
  if (sessionId == null) {
    // `allSessionsProvider` is already sorted newest-first on both the local
    // and the remote path, so the first active row is the current session. A
    // genuinely idle host yields null and the strip stays empty — which is then
    // the truth, not a false negative.
    final sessions = ref.watch(allSessionsProvider).valueOrNull;
    if (sessions != null) {
      for (final session in sessions) {
        if (session.status == 'active') {
          sessionId = session.id;
          break;
        }
      }
      // A run that ended this session closed its session on the host; its
      // frames are still tonight's until the next run starts.
      if (sessionId == null &&
          sessions.isNotEmpty &&
          ref.watch(lastEndedRunProvider) != null) {
        sessionId = sessions.first.id;
      }
    }
  }
  if (sessionId == null) {
    return const <CapturedImage>[];
  }

  final rows = ref.watch(allDbImagesProvider).valueOrNull;
  if (rows == null) {
    return const <CapturedImage>[];
  }

  final sessionRows =
      rows.where((row) => row.sessionId == sessionId).toList(growable: false)
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  return sessionRows.map(capturedImageFromDbRow).toList(growable: false);
});

/// Map a persisted `captured_images` row onto the in-memory [CapturedImage]
/// shape the cockpit/strip widgets render.
///
/// Package-public because the sequencer's frame-registration path needs the same
/// mapping to push freshly persisted sequence frames into
/// [sessionImagesProvider]; duplicating it there would let the two views of a
/// frame drift apart.
CapturedImage capturedImageFromDbRow(db.CapturedImage row) {
  return CapturedImage(
    id: row.id.toString(),
    filePath: row.filePath,
    capturedAt: row.capturedAt,
    settings: ExposureSettings(
      exposureTime: row.exposureDuration,
      gain: row.gain ?? 0,
      offset: row.offset ?? 0,
      binningX: row.binX,
      binningY: row.binY,
      filter: row.filter,
      frameType: _frameTypeFromDbString(row.frameType),
    ),
    stats: row.hfr != null || row.starCount != null
        ? ImageStats(
            hfr: row.hfr,
            starCount: row.starCount,
            background: row.background,
            noise: row.noise,
          )
        : null,
    format: _imageFormatFromDbString(row.fileFormat),
  );
}

FrameType _frameTypeFromDbString(String str) {
  switch (str.toLowerCase()) {
    case 'dark':
      return FrameType.dark;
    case 'flat':
      return FrameType.flat;
    case 'bias':
      return FrameType.bias;
    case 'darkflat':
      return FrameType.darkFlat;
    case 'snapshot':
      return FrameType.snapshot;
    default:
      return FrameType.light;
  }
}

ImageFileFormat _imageFormatFromDbString(String str) {
  switch (str.toLowerCase()) {
    case 'xisf':
      return ImageFileFormat.xisf;
    case 'tiff':
      return ImageFileFormat.tiff;
    case 'png':
      return ImageFileFormat.png;
    case 'jpeg':
    case 'jpg':
      return ImageFileFormat.jpeg;
    default:
      return ImageFileFormat.fits;
  }
}

// Temperature history tracking

/// A point in the temperature history
class TemperaturePoint {
  final double temperature;
  final double? targetTemp;
  final double? coolerPower;
  final DateTime time;

  TemperaturePoint({
    required this.temperature,
    this.targetTemp,
    this.coolerPower,
    required this.time,
  });
}

/// Provider for temperature history (last N points)
final temperatureHistoryProvider =
    StateNotifierProvider<TemperatureHistoryNotifier, List<TemperaturePoint>>((
      ref,
    ) {
      return TemperatureHistoryNotifier();
    });

class TemperatureHistoryNotifier extends StateNotifier<List<TemperaturePoint>> {
  static const int maxPoints = 120; // 10 minutes at 5-second intervals

  /// One reading per minute in [longHistory]: twelve hours in 720 points.
  static const Duration longBucket = Duration(minutes: 1);
  static const int maxLongPoints = 720;

  TemperatureHistoryNotifier() : super([]);

  final List<TemperaturePoint> _long = <TemperaturePoint>[];

  /// The night's cooler history, downsampled to the last reading of each
  /// minute and capped at twelve hours, so a chart can say "since 19:20"
  /// where [state] only covers the last ten minutes. Every point is a real
  /// reading; nothing is averaged or filled in.
  List<TemperaturePoint> get longHistory =>
      List<TemperaturePoint>.unmodifiable(_long);

  /// [at] defaults to now; tests pass it to build hours of history.
  void addPoint(
    double temperature, {
    double? targetTemp,
    double? coolerPower,
    DateTime? at,
  }) {
    final point = TemperaturePoint(
      temperature: temperature,
      targetTemp: targetTemp,
      coolerPower: coolerPower,
      time: at ?? DateTime.now(),
    );

    _addLong(point);
    if (state.length >= maxPoints) {
      state = [...state.sublist(1), point];
    } else {
      state = [...state, point];
    }
  }

  void _addLong(TemperaturePoint point) {
    if (_long.isNotEmpty &&
        _bucketOf(_long.last.time) == _bucketOf(point.time)) {
      _long[_long.length - 1] = point;
    } else {
      _long.add(point);
    }
    final cutoff = point.time.subtract(longBucket * maxLongPoints);
    _long.removeWhere((p) => p.time.isBefore(cutoff));
    if (_long.length > maxLongPoints) {
      _long.removeRange(0, _long.length - maxLongPoints);
    }
  }

  static int _bucketOf(DateTime time) =>
      time.millisecondsSinceEpoch ~/ longBucket.inMilliseconds;

  /// Put [earlier] (oldest first) in front of the twelve-hour history: the
  /// imaging host's readings from before a linked client connected. Readings
  /// at or after this history's first are already here.
  void addEarlier(List<TemperaturePoint> earlier) {
    final first = _long.isEmpty ? null : _long.first.time;
    final older = [
      for (final point in earlier)
        if (first == null || _bucketOf(point.time) < _bucketOf(first)) point,
    ];
    if (older.isEmpty) return;
    _long.insertAll(0, older);
    final cutoff = _long.last.time.subtract(longBucket * maxLongPoints);
    _long.removeWhere((p) => p.time.isBefore(cutoff));
    if (_long.length > maxLongPoints) {
      _long.removeRange(0, _long.length - maxLongPoints);
    }
    // The long history is read through this list's change signal.
    state = [...state];
  }

  void clear() {
    _long.clear();
    state = [];
  }

  /// Get the minimum and maximum temperature in the history
  (double, double) get tempRange {
    if (state.isEmpty) return (-30.0, 30.0);

    double minTemp = state.first.temperature;
    double maxTemp = state.first.temperature;

    for (final point in state) {
      if (point.temperature < minTemp) minTemp = point.temperature;
      if (point.temperature > maxTemp) maxTemp = point.temperature;
      if (point.targetTemp != null) {
        if (point.targetTemp! < minTemp) minTemp = point.targetTemp!;
        if (point.targetTemp! > maxTemp) maxTemp = point.targetTemp!;
      }
    }

    // Add some padding
    return (minTemp - 5, maxTemp + 5);
  }
}

/// The cooler history of the last twelve hours, one reading per minute. See
/// [TemperatureHistoryNotifier.longHistory].
final temperatureLongHistoryProvider = Provider<List<TemperaturePoint>>((ref) {
  // Every reading replaces the short list, so watching it is the change
  // signal for the long one as well.
  ref.watch(temperatureHistoryProvider);
  return ref.read(temperatureHistoryProvider.notifier).longHistory;
});
