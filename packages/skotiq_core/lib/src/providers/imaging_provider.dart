import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart' as db;
import '../models/imaging/imaging_models.dart';
import '../models/imaging/auto_stretch_settings.dart';
import '../models/backend/device_capabilities.dart';
import '../models/equipment/equipment_models.dart';
import 'backend_provider.dart';
import 'host_role.dart';
import 'capability_provider.dart' show cameraSensitivityProvider;
import 'equipment/camera_state_provider.dart';
import 'database_provider.dart';
import '../services/darkroom_build_service.dart' show observingNight;
import 'host_settings/host_settings_providers.dart'
    show settingsRowChangesProvider;
import 'profiles_provider.dart';
import '../models/equipment_profile_model.dart';
import 'session_provider.dart';
import 'settings_provider.dart';
import 'runtime_mirror/channels/session_frames_channel.dart'
    show hostSessionFrameIdsProvider;
import 'sequence/last_ended_run.dart' show lastEndedRunProvider;
import 'package:skotiq_astro/skotiq_astro.dart';
import '../database/daos/settings_dao.dart';
import '../settings/app_settings_state.g.dart';
import '../settings/capture_format.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';

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

/// The row holding [profile]'s manual capture settings.
Setting<String?> _exposureSettingsRow(EquipmentProfileModel profile) =>
    StoreSettings.captureSettings.row(_exposureProfileKey(profile));

/// The `app_settings` key holding [profile]'s manual capture settings.
String exposureSettingsKeyFor(EquipmentProfileModel profile) =>
    _exposureSettingsRow(profile).key;

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

/// The connected imaging camera's id, the gain it reports and its
/// sensitivity; the id is null while no camera is connected.
final _connectedCameraIsoProvider =
    Provider<(String?, int?, ExposureSensitivity)>((ref) {
      final (connected, deviceId, gain) = ref.watch(
        cameraStateProvider.select(
          (s) => (
            s.connectionState == DeviceConnectionState.connected,
            s.deviceId,
            s.gain,
          ),
        ),
      );
      if (!connected || deviceId == null || deviceId.isEmpty) {
        return (null, null, const GainSensitivity());
      }
      return (deviceId, gain, ref.watch(cameraSensitivityProvider));
    });

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

  // A DSLR or mirrorless body is set to an ISO of its own (its dial, its
  // menu, the last program that drove it). Once per connection, after the
  // profile's snapshot is loaded, the snapshot takes the ISO the body
  // reports, so the ISO picker shows what the body is at and the next frame
  // does not silently change it.
  String? adoptedFor;
  void adoptBodyIso() {
    if (disposed || loadedProfileKey == null) return;
    final (deviceId, reported, sensitivity) = ref.read(
      _connectedCameraIsoProvider,
    );
    if (deviceId == null) {
      adoptedFor = null;
      return;
    }
    if (adoptedFor == deviceId ||
        reported == null ||
        sensitivity is! IsoSensitivity ||
        !sensitivity.speeds.contains(reported)) {
      return;
    }
    adoptedFor = deviceId;
    final current = ref.read(exposureSettingsProvider);
    if (current.gain == reported) return;
    updateManualExposureSettings(ref, current.copyWith(gain: reported));
  }

  Future<void>.microtask(() {
    final profileKey = profile.id?.toString() ?? profile.name;
    if (disposed || loadInFlight || loadedProfileKey == profileKey) return;
    loadInFlight = true;

    final revisionAtStart = ref.read(_manualExposureRevisionProvider);
    () async {
      final dao = ref.read(settingsDaoProvider);
      ExposureSettings? saved;
      try {
        final value = await dao.read(_exposureSettingsRow(profile));
        if (value != null) {
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
      if (ref.read(_manualExposureRevisionProvider) == revisionAtStart &&
          !disposed) {
        ref.read(exposureSettingsProvider.notifier).state =
            saved ??
            ExposureSettings(
              exposureTime: 2,
              gain: profile.defaultGain ?? 100,
              offset: profile.defaultOffset ?? 50,
              binningX: profile.defaultBinX,
              binningY: profile.defaultBinY,
              frameType: FrameType.light,
            );
      }
      adoptBodyIso();
    }();
  });

  ref.listen<(String?, int?, ExposureSensitivity)>(
    _connectedCameraIsoProvider,
    (_, __) => adoptBodyIso(),
  );

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
      final value = await ref
          .read(settingsDaoProvider)
          .read(_exposureSettingsRow(profile));
      if (value != null) {
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
      final json = await _ref
          .read(settingsDaoProvider)
          .read(StoreSettings.autoStretch);
      if (json != null && revisionAtStart == _requestRevision && mounted) {
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
      await _ref
          .read(settingsDaoProvider)
          .write(StoreSettings.autoStretch, jsonEncode(settings.toJson()));
    } catch (e) {
      developer.log(
        'Failed to save auto-stretch settings: $e',
        name: 'AutoStretch',
        level: 1000,
      );
      rethrow;
    }
  }

  Future<void> reset() => update(AutoStretchSettings.defaults());
}

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

  final format = ImageFileFormatSettingsX.fromSettings(
    normalizeCaptureImageFormat(settings.format),
  );
  final baseDir = settings.outputPath.isEmpty ? '.' : settings.outputPath;

  return NamingPattern(
    pattern: settings.pattern,
    baseDir: baseDir,
    format: format,
  );
});

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
  if (ref.watch(isRemoteModeProvider)) return;
  final now = DateTime.now();
  final window = observingNightWindow(now);
  final rows = await ref
      .read(imagesDaoProvider)
      .getImagesCapturedBetween(window.start, window.end);
  ref.read(sessionImagesProvider.notifier).seedNight([
    for (final row in rows)
      if (row.isAccepted) capturedImageFromDbRow(row),
  ], now: now);
});

/// The session a linked client's host is recording into, for a client that
/// only watches: its own session state names a session only when it started
/// or recovered one itself. Null on the host, whose session state is the
/// whole answer, and when the host is idle.
///
/// The host's sessions arrive newest first, so the first active one is the
/// current one. A run that ended here closed its session on the host; its
/// frames stay tonight's until the next run starts.
final watchedHostSessionIdProvider = hostRoleProvider<int?>(
  here: (ref) => null,
  linked: (ref, host) {
    final sessions = ref.watch(allSessionsProvider).valueOrNull;
    if (sessions == null) return null;
    for (final session in sessions) {
      if (session.status == 'active') return session.id;
    }
    if (sessions.isNotEmpty && ref.watch(lastEndedRunProvider) != null) {
      return sessions.first.id;
    }
    return null;
  },
);

/// The frames of the session in progress, oldest first.
///
/// The host keeps them in memory as its capture loop takes them
/// ([sessionImagesProvider]). A linked client takes the list of frame ids its
/// host shares (`SessionFramesChannel`), so both count the same frames
/// whenever the client connected; for a host that shares none it shows the
/// rows of the session the host is recording into.
final recentSessionFramesProvider = hostRoleProvider<List<CapturedImage>>(
  here: (ref) => ref.watch(sessionImagesProvider),
  linked: (ref, host) {
    final hostIds = ref.watch(hostSessionFrameIdsProvider);
    if (hostIds != null) {
      if (hostIds.isEmpty) return const <CapturedImage>[];
      final rows = ref.watch(allDbImagesProvider).valueOrNull;
      if (rows == null) return const <CapturedImage>[];
      final byId = {for (final row in rows) row.id: row};
      return [
        for (final id in hostIds)
          if (byId[id] case final db.DbCapturedImage row)
            capturedImageFromDbRow(row),
      ];
    }

    final sessionId =
        ref.watch(sessionStateProvider.select((state) => state.dbSessionId)) ??
        ref.watch(watchedHostSessionIdProvider);
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
  },
);

/// Map a persisted `captured_images` row onto the in-memory [CapturedImage]
/// shape the cockpit/strip widgets render.
///
/// Package-public because the sequencer's frame-registration path needs the same
/// mapping to push freshly persisted sequence frames into
/// [sessionImagesProvider]; duplicating it there would let the two views of a
/// frame drift apart.
CapturedImage capturedImageFromDbRow(db.DbCapturedImage row) {
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

ImageFileFormat _imageFormatFromDbString(String str) =>
    ImageFileFormat.fromRecord(str) ?? ImageFileFormat.fits;

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
