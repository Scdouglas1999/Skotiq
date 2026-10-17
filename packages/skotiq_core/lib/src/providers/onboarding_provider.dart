import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hardware_presets/hardware_preset_models.dart';
import '../models/onboarding/onboarding_state.dart';
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/hardware_presets_provider.dart';
import '../providers/profiles_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tutorial_provider.dart';
import '../services/hardware_presets/hardware_presets_service.dart';

/// Bootstrap gate read by the `EquipmentOnboardingLauncher` widget on app
/// launch. Resolves true only when there are zero equipment profiles AND the
/// `equipmentOnboarding` row is absent or unfinished.
final shouldRunEquipmentOnboardingProvider = FutureProvider<bool>((ref) async {
  // Don't nag returning users — any existing profile means they already
  // got past onboarding (either through this wizard or the original
  // equipment screen). The wizard is reachable from settings for those
  // users.
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final remoteProfiles = await backend.getProfiles();
    if (remoteProfiles.isNotEmpty) return false;
  } else {
    final profilesDao = ref.read(equipmentProfilesDaoProvider);
    final profiles = await profilesDao.getAllProfiles();
    if (profiles.isNotEmpty) return false;
  }

  final tutorialDao = ref.read(tutorialProgressDaoProvider);
  final progress = await tutorialDao.getProgress(
    OnboardingDraft.persistenceCategory,
  );
  if (progress != null && (progress.completed || progress.dismissed)) {
    // The user explicitly finished or skipped the wizard; trust that
    // even though they have no profile yet.
    return false;
  }
  return true;
});

/// State notifier owning the live draft + persistence.
final onboardingDraftProvider =
    StateNotifierProvider<OnboardingNotifier, OnboardingDraft>((ref) {
      final notifier = OnboardingNotifier(ref);
      // Kick off the async hydrate immediately — the UI shows a small
      // spinner until `isLoaded` flips true via [OnboardingNotifier.isLoaded].
      notifier._loadDraft();
      return notifier;
    });

/// Set of drivers available on the current platform. ASCOM is Windows-only;
/// the other backends work everywhere. Exposed as a provider so widget
/// tests can override the platform check.
final availableOnboardingDriversProvider = Provider<Set<DriverType>>((ref) {
  final drivers = <DriverType>{
    DriverType.native,
    DriverType.alpaca,
    DriverType.indi,
    DriverType.simulator,
  };
  if (Platform.isWindows) {
    drivers.add(DriverType.ascom);
  }
  return drivers;
});

class OnboardingNotifier extends StateNotifier<OnboardingDraft> {
  OnboardingNotifier(this._ref) : super(const OnboardingDraft());

  final Ref _ref;
  bool _isLoaded = false;
  Completer<void>? _loadCompleter;

  /// True once the persisted draft (if any) has been read into [state].
  /// The wizard widget waits for this before rendering its first frame so
  /// the user doesn't see a flash of step 0 before being restored to
  /// (say) the optical train step.
  bool get isLoaded => _isLoaded;

  /// Future that resolves when the initial draft load is done. Awaited by
  /// tests that need to be certain of the hydrated state before pumping
  /// the widget tree.
  Future<void> get loaded {
    if (_isLoaded) return Future.value();
    _loadCompleter ??= Completer<void>();
    return _loadCompleter!.future;
  }

  Future<void> _loadDraft() async {
    try {
      final settingsDao = _ref.read(settingsDaoProvider);
      final raw = await settingsDao.getSetting(
        OnboardingDraft.draftSettingsKey,
      );
      final draft = OnboardingDraft.fromJsonStringOrEmpty(raw);
      // If the user has not selected any drivers yet (truly fresh start),
      // seed sensible defaults so the discovery step doesn't show an
      // empty multi-select.
      if (draft.selectedDrivers.isEmpty) {
        final available = _ref.read(availableOnboardingDriversProvider);
        // Default to everything except the simulator — the simulator is
        // useful for development but new users want real devices.
        final defaults = available
            .where((d) => d != DriverType.simulator)
            .toSet();
        // Same `mounted` guard as the other branch: the hydrate is in flight
        // across an await, and writing state after disposal throws.
        if (mounted) state = draft.copyWith(selectedDrivers: defaults);
      } else if (mounted) {
        state = draft;
      }
    } finally {
      _isLoaded = true;
      _loadCompleter?.complete();
      _loadCompleter = null;
    }
  }

  Future<void> _persistDraft() async {
    final settingsDao = _ref.read(settingsDaoProvider);
    await settingsDao.setSetting(
      OnboardingDraft.draftSettingsKey,
      state.toJsonString(),
    );
  }

  /// Move to a specific step. Used by the side-bar "jump to step" affordance.
  Future<void> goToStep(OnboardingStep step) async {
    if (!mounted) return;
    state = state.copyWith(currentStep: step);
    await _persistDraft();
  }

  /// Advance to the next non-skipped step. Honors the user's optional-step
  /// choices: if the user did not select a focuser at the focuser step,
  /// the next-step call from the focuser step still proceeds — it's the
  /// caller's job to decide whether to skip; this method just moves
  /// forward by one in OnboardingStep.values order.
  Future<void> next() async {
    final idx = state.currentStep.order;
    if (idx >= OnboardingStep.values.length - 1) return;
    final nextStep = OnboardingStep.values[idx + 1];
    state = state.copyWith(currentStep: nextStep);
    await _persistDraft();
  }

  /// Step backward. No-op on the welcome step.
  Future<void> back() async {
    final idx = state.currentStep.order;
    if (idx == 0) return;
    final prevStep = OnboardingStep.values[idx - 1];
    state = state.copyWith(currentStep: prevStep);
    await _persistDraft();
  }

  /// Toggle a driver on/off. Discovery is keyed off this set.
  Future<void> toggleDriver(DriverType driver) async {
    final next = Set<DriverType>.from(state.selectedDrivers);
    if (next.contains(driver)) {
      next.remove(driver);
    } else {
      next.add(driver);
    }
    state = state.copyWith(selectedDrivers: next);
    await _persistDraft();
  }

  Future<void> setCamera({
    String? id,
    String? name,
    double? pixelSizeMicrons,
  }) async {
    if (id == null || id.isEmpty) {
      state = state.copyWith(clearCamera: true);
    } else {
      state = state.copyWith(
        cameraId: id,
        cameraName: name,
        pixelSizeMicrons: pixelSizeMicrons ?? state.pixelSizeMicrons,
      );
    }
    await _persistDraft();
  }

  Future<void> setMount({String? id, String? name}) async {
    if (id == null || id.isEmpty) {
      state = state.copyWith(clearMount: true);
    } else {
      state = state.copyWith(mountId: id, mountName: name);
    }
    await _persistDraft();
  }

  Future<void> setFocuser({String? id, String? name}) async {
    if (id == null || id.isEmpty) {
      state = state.copyWith(clearFocuser: true);
    } else {
      state = state.copyWith(focuserId: id, focuserName: name);
    }
    await _persistDraft();
  }

  Future<void> setFilterWheel({
    String? id,
    String? name,
    List<String>? filterNames,
  }) async {
    if (id == null || id.isEmpty) {
      state = state.copyWith(clearFilterWheel: true, filterNames: const []);
    } else {
      state = state.copyWith(
        filterWheelId: id,
        filterWheelName: name,
        filterNames: filterNames ?? state.filterNames,
      );
    }
    await _persistDraft();
  }

  Future<void> setFilterNames(List<String> names) async {
    state = state.copyWith(filterNames: names);
    await _persistDraft();
  }

  Future<void> setGuider({String? id, String? name}) async {
    if (id == null || id.isEmpty) {
      state = state.copyWith(clearGuider: true);
    } else {
      state = state.copyWith(guiderId: id, guiderName: name);
    }
    await _persistDraft();
  }

  Future<void> setOpticalTrain({
    double? pixelSizeMicrons,
    double? focalLengthMm,
    double? apertureMm,
    double? reducerFactor,
  }) async {
    state = state.copyWith(
      pixelSizeMicrons: pixelSizeMicrons,
      focalLengthMm: focalLengthMm,
      apertureMm: apertureMm,
      reducerFactor: reducerFactor ?? state.reducerFactor,
      clearPixelSize: pixelSizeMicrons == null,
      clearFocalLength: focalLengthMm == null,
      clearAperture: apertureMm == null,
    );
    await _persistDraft();
  }

  /// Read-only access to the merged hardware-presets service (built-ins +
  /// user overrides) so the optical-train and camera-defaults steps can render
  /// the preset pickers without reaching through to the provider themselves.
  HardwarePresetsService get hardwarePresets =>
      _ref.read(hardwarePresetsServiceProvider);

  /// Apply a telescope preset picked at the optical-train step. Pins the
  /// preset id + display name and prefills the optics (focal length, aperture)
  /// from the catalog so the image-scale readout updates immediately. The
  /// reducer factor is intentionally left untouched — a reducer is a separate
  /// physical accessory the user may add on top of any OTA.
  Future<void> applyTelescopePreset(TelescopePreset preset) async {
    state = state.copyWith(
      telescopePresetId: preset.id,
      telescopeName: preset.displayName,
      focalLengthMm: preset.focalLengthMm,
      apertureMm: preset.apertureMm,
    );
    await _persistDraft();
  }

  /// Apply a camera-defaults preset picked at the camera-defaults step. Pins
  /// the preset id, prefills the pixel size (feeding the image-scale math) and
  /// the acquisition defaults (gain/offset/binning/cooling). A preset with no
  /// regulated cooling (e.g. a DSLR) clears the cooling set-point rather than
  /// collapsing it to 0 °C.
  Future<void> applyCameraPreset(CameraDefaultsPreset preset) async {
    state = state.copyWith(
      cameraPresetId: preset.id,
      pixelSizeMicrons: preset.pixelSizeMicrons,
      defaultGain: preset.recommendedGain,
      defaultOffset: preset.recommendedOffset,
      defaultBinX: preset.recommendedBinX,
      defaultBinY: preset.recommendedBinY,
      defaultCoolingTempC: preset.recommendedCoolingTempC,
      clearCoolingTempC: preset.recommendedCoolingTempC == null,
    );
    await _persistDraft();
  }

  /// Set (or override) the camera acquisition defaults captured at the
  /// camera-defaults step. Any argument left null preserves the existing draft
  /// value; pass the matching `clear*` flag to null a set-point out explicitly
  /// (the user emptied the field, or toggled regulated cooling off), since a
  /// plain null cannot distinguish "leave unchanged" from "clear".
  Future<void> setCameraDefaults({
    int? gain,
    int? offset,
    int? binX,
    int? binY,
    double? coolingTempC,
    bool? coolOnConnect,
    bool clearCoolingTempC = false,
    bool clearGain = false,
    bool clearOffset = false,
    bool clearBinX = false,
    bool clearBinY = false,
  }) async {
    state = state.copyWith(
      defaultGain: gain ?? state.defaultGain,
      defaultOffset: offset ?? state.defaultOffset,
      defaultBinX: binX ?? state.defaultBinX,
      defaultBinY: binY ?? state.defaultBinY,
      defaultCoolingTempC: coolingTempC ?? state.defaultCoolingTempC,
      coolOnConnect: coolOnConnect,
      clearCoolingTempC: clearCoolingTempC,
      clearGain: clearGain,
      clearOffset: clearOffset,
      clearBinX: clearBinX,
      clearBinY: clearBinY,
    );
    await _persistDraft();
  }

  Future<void> setCaptureDirectory(String path) async {
    state = state.copyWith(captureDirectory: path);
    await _persistDraft();
  }

  Future<void> setProfileName(String name) async {
    state = state.copyWith(profileName: name);
    await _persistDraft();
  }

  /// Create the equipment profile from the current draft and persist the
  /// capture directory. Returns the created profile id so the launcher can
  /// immediately activate it.
  ///
  /// This is invoked at the summary step. It deliberately does NOT mark the
  /// tutorial complete, wipe the draft, or flip the bootstrap gate — that
  /// happens in [finishNextSteps] once the user leaves the terminal
  /// `nextSteps` step. Splitting the two lets the wizard create the profile,
  /// then show the "what's next" guidance while the rig is already live, and
  /// only retire onboarding when the user actually finishes.
  Future<int> complete() async {
    final draft = state;
    final backendOwner = _ref.read(backendProvider.notifier);
    final backend = backendOwner.currentBackend;
    void requireAuthority(String action) {
      if (!mounted || !backendOwner.isCurrentBackend(backend)) {
        throw StateError(
          'The imaging host changed while $action. The onboarding result was '
          'not applied to the replacement host.',
        );
      }
    }

    // Persist the new equipment profile. The DAO marks the first profile
    // as default+active on insert so the user lands on the dashboard
    // already pointed at their new rig.
    final dao = backend is NetworkBackend
        ? null
        : _ref.read(equipmentProfilesDaoProvider);
    final localProfiles = backend is NetworkBackend
        ? null
        : _ref.read(equipmentProfilesProvider.notifier);
    final focalRatio =
        (draft.focalLengthMm != null &&
            draft.apertureMm != null &&
            draft.apertureMm! > 0)
        ? (draft.focalLengthMm! * draft.reducerFactor) / draft.apertureMm!
        : null;

    final profile = EquipmentProfileModel(
      name: (draft.profileName ?? '').trim().isNotEmpty
          ? draft.profileName!.trim()
          : 'My First Rig',
      description: 'Created by the first-run setup wizard',
      cameraId: draft.cameraId,
      cameraName: draft.cameraName,
      mountId: draft.mountId,
      mountName: draft.mountName,
      focuserId: draft.focuserId,
      focuserName: draft.focuserName,
      filterWheelId: draft.filterWheelId,
      filterWheelName: draft.filterWheelName,
      guiderId: draft.guiderId,
      guiderName: draft.guiderName,
      telescopeName: draft.telescopeName,
      focalLength: draft.focalLengthMm != null
          ? draft.focalLengthMm! * draft.reducerFactor
          : 0.0,
      aperture: draft.apertureMm ?? 0.0,
      focalRatio: focalRatio,
      telescopeFocalLength: draft.focalLengthMm,
      telescopeAperture: draft.apertureMm,
      // Camera acquisition defaults captured at the camera-defaults step.
      // defaultBinX/Y are non-nullable on the model (default 1), so fall back
      // to 1 when the draft never set them.
      defaultGain: draft.defaultGain,
      defaultOffset: draft.defaultOffset,
      defaultBinX: draft.defaultBinX ?? 1,
      defaultBinY: draft.defaultBinY ?? 1,
      defaultCoolingTemp: draft.defaultCoolingTempC,
      // Cool-on-connect stays OPT-IN — a set-point alone never arms the TEC,
      // because a setup done in the middle of a summer day must not pin the
      // cooler at full power for hours. The wizard asks ("Start cooling when
      // the camera connects", off by default) and its answer is carried here,
      // so an operator who ticked it does not have to find the same checkbox
      // again in Equipment > Edit Profile > Camera Defaults.
      coolOnConnect: draft.coolOnConnect,
      filterNames: draft.filterNames,
    );

    final int id;
    if (backend is NetworkBackend) {
      await backend.saveProfile(profile.toRemoteProfile());
      requireAuthority('creating the equipment profile');
      _ref.invalidate(equipmentProfilesProvider);
      final createdId = backend.lastSavedProfileId;
      if (createdId == null || createdId.isEmpty) {
        throw StateError(
          'Host saved onboarding profile "${profile.name}" but did not '
          'return its created id',
        );
      }
      final parsedId = int.tryParse(createdId);
      if (parsedId == null) {
        throw StateError(
          'Host saved onboarding profile "${profile.name}" with non-numeric id',
        );
      }
      await backend.loadProfile(createdId);
      requireAuthority('activating the equipment profile');
      _ref.invalidate(equipmentProfilesProvider);
      id = parsedId;
    } else {
      id = await dao!.createProfile(profile.toCompanion());
      requireAuthority('creating the equipment profile');
      // dao.createProfile only auto-activates the FIRST profile; when older
      // profiles already exist the new row is inserted inactive. Re-running
      // onboarding must still leave the user pointed at the rig they just
      // built, so route activation through the remote-aware notifier — that
      // flips SQLite AND write-throughs the active row to the native executor
      // store, making the terminal "active & ready" screen truthful. Idempotent
      // for the first-profile case (already active), and it performs the native
      // write-through a bare DAO insert skips. Local-only: this is the
      // non-NetworkBackend branch, so [setActiveProfile] never hits the host.
      await localProfiles!.setActiveProfile(id);
      requireAuthority('activating the equipment profile');
    }

    await _persistAppSettings(draft, backend, requireAuthority);

    // Note: marking the tutorial complete, wiping the draft blob, and flipping
    // the bootstrap gate are deferred to [finishNextSteps] — the profile now
    // exists, but onboarding is not "done" until the user leaves the terminal
    // next-steps screen.
    return id;
  }

  /// Push the app-level answers the wizard collected into app settings.
  ///
  /// Two of them:
  ///   * the capture directory, so the imaging service writes frames where the
  ///     user said from day one;
  ///   * the discovery backends ticked at the driver step. These are the same
  ///     question Settings → Equipment → Connection asks as "Query INDI/Alpaca
  ///     on startup", and the wizard is where the user actually answered, so
  ///     its answer is the stored one — otherwise a camera found over INDI
  ///     during onboarding is never looked for again at launch.
  ///
  /// Both flags are written, not just the true ones: unticking INDI in the
  /// wizard has to be able to turn an inherited `true` back off, or "the wizard
  /// drives these toggles" would only be half true.
  ///
  /// One read-modify-write for the remote host: a second round trip could race
  /// the first and lose whichever field it did not carry.
  Future<void> _persistAppSettings(
    OnboardingDraft draft,
    SkotiqBackend backend,
    void Function(String action) requireAuthority,
  ) async {
    final captureDir = draft.captureDirectory?.trim();
    final hasCaptureDir = captureDir != null && captureDir.isNotEmpty;
    // An empty driver set means the step never resolved (a draft restored from
    // before it existed); silently disabling both backends would be an answer
    // the user never gave.
    final hasDrivers = draft.selectedDrivers.isNotEmpty;
    if (!hasCaptureDir && !hasDrivers) return;

    final indi = draft.selectedDrivers.contains(DriverType.indi);
    final alpaca = draft.selectedDrivers.contains(DriverType.alpaca);

    if (backend is NetworkBackend) {
      final settings = await backend.getSettings();
      requireAuthority('loading the app settings');
      await backend.updateSettings(
        settings.copyWith(
          imageOutputPath: hasCaptureDir
              ? captureDir
              : settings.imageOutputPath,
          indiAutoConnect: hasDrivers ? indi : settings.indiAutoConnect,
          alpacaAutoDiscover: hasDrivers ? alpaca : settings.alpacaAutoDiscover,
        ),
      );
    } else {
      final dao = _ref.read(settingsDaoProvider);
      if (hasCaptureDir) {
        await dao.setImageOutputDirectory(captureDir);
      }
      if (hasDrivers) {
        await dao.setSettings({
          'indi_auto_connect': indi.toString(),
          'alpaca_auto_discover': alpaca.toString(),
        });
      }
    }
    requireAuthority('saving the onboarding settings');
    _ref.invalidate(appSettingsProvider);
  }

  /// Retire the wizard once the user leaves the terminal `nextSteps` step.
  /// Marks `tutorial_progress` completed, wipes the draft blob, and flips the
  /// bootstrap gate so the wizard does not auto-launch again. Idempotent —
  /// safe to call more than once (the DAO upserts and deleteSetting is a no-op
  /// on a missing row).
  Future<void> finishNextSteps() async {
    final tutorialDao = _ref.read(tutorialProgressDaoProvider);
    await tutorialDao.markCompleted(OnboardingDraft.persistenceCategory);
    final settingsDao = _ref.read(settingsDaoProvider);
    await settingsDao.deleteSetting(OnboardingDraft.draftSettingsKey);

    // Invalidate the bootstrap gate so the next launch reads `false`.
    _ref.invalidate(shouldRunEquipmentOnboardingProvider);
  }

  /// User pressed "Skip onboarding". We mark the wizard dismissed in
  /// tutorial_progress so it stops auto-launching, but we keep the draft
  /// around in case the user reopens the wizard later from Settings.
  Future<void> skip() async {
    final tutorialDao = _ref.read(tutorialProgressDaoProvider);
    await tutorialDao.markDismissed(OnboardingDraft.persistenceCategory);
    _ref.invalidate(shouldRunEquipmentOnboardingProvider);
  }

  /// Reset the wizard to a pristine state. Used by the "Start over" button
  /// on the welcome step (and by tests).
  Future<void> reset() async {
    final available = _ref.read(availableOnboardingDriversProvider);
    final defaults = available.where((d) => d != DriverType.simulator).toSet();
    final resetDraft = OnboardingDraft(selectedDrivers: defaults);
    final settingsDao = _ref.read(settingsDaoProvider);
    await settingsDao.setSetting(
      OnboardingDraft.draftSettingsKey,
      resetDraft.toJsonString(),
    );
    if (mounted) state = resetDraft;
  }
}
