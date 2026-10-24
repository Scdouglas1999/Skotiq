import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/smart_night_plan_launcher.dart';
import '../../../utils/authority_bound_dialog.dart';
import '../../../widgets/camera_sensor_specs_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../equipment/dialogs/profile_editor_dialog.dart';

part 'smart_night_dialog/inline_widgets.dart';
part 'smart_night_dialog/safety_watchdogs.dart';
part 'smart_night_dialog/step_views.dart';

part 'smart_night_dialog/plan_helpers.dart';

/// One-click "Plan tonight" wizard.
///
/// Reachable from the sequencer Builder tab toolbar. Walks the user
/// through six steps:
///
/// 1. Confirm tonight's window (sunset → sunrise of user's location;
///    user can narrow).
/// 2. Confirm equipment profile + camera + filter wheel.
/// 3. Choose targets — hand-pick from the saved/scored list OR let
///    the auto-builder pick the top-N by score.
/// 4. Choose strategy — auto LRGB / narrowband HOO / SHO / OSC /
///    mono LRGB.
/// 5. Preview the generated sequence (timeline + per-target / per-
///    filter breakdown). User can tweak counts before accepting.
/// 6. Accept → the new sequence is loaded into the editor and the
///    dialog closes.
class SmartNightDialog extends ConsumerStatefulWidget {
  const SmartNightDialog({
    super.key,
    this.seedTargetIds,
    this.seedSourceLabel,
  });

  /// Optional set of target ids to pre-select on the Targets step — the Smart
  /// Night handoff from an active project. When non-empty the wizard opens in
  /// hand-pick mode with exactly these targets selected.
  ///
  /// An id only takes effect if it survives tonight's altitude/score cut-offs:
  /// the suggestion ranking is the source of truth for whether a target is
  /// imageable tonight. Ids that do not appear in the ranking are surfaced on
  /// the Targets step rather than silently dropped.
  final List<int>? seedTargetIds;

  /// Human-readable description of where [seedTargetIds] came from (e.g. the
  /// project name), shown as a banner on the Targets step. Null when the wizard
  /// was opened without a seed.
  final String? seedSourceLabel;

  @override
  ConsumerState<SmartNightDialog> createState() => _SmartNightDialogState();
}

/// Canonical entry point for the Smart Night "Plan Tonight" wizard.
///
/// Every "Plan Tonight" affordance across the app (dashboard, sequencer
/// toolbar, planner Projects tab, cockpit standby) funnels through this single
/// launcher so the flow, dialog, and behaviour can never drift between
/// entrances. Optional [seedTargetIds] / [seedSourceLabel] feed a campaign's
/// targets into the wizard (used by the Projects tab handoff); omit them for
/// the generic "best of tonight" plan.
Future<void> showSmartNightDialog(
  BuildContext context, {
  List<int>? seedTargetIds,
  String? seedSourceLabel,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SmartNightDialog(
      seedTargetIds: seedTargetIds,
      seedSourceLabel: seedSourceLabel,
    ),
  );
}

class _SmartNightDialogState extends ConsumerState<SmartNightDialog> {
  int _step = 0;

  // Step 1: window
  DateTime? _windowStart;
  DateTime? _windowEnd;
  bool _windowInitialised = false;
  String? _windowError;

  /// The computed astronomical-twilight (dark) window, cached on
  /// initialisation so [_validateWindow] can warn when the user narrows their
  /// imaging window wholly outside the dark hours (e.g. into daylight).
  DateTime? _twilightStart;
  DateTime? _twilightEnd;

  // Step 3: targets
  /// User-selected target IDs. Empty → auto-pick top N by score.
  final Set<int> _selectedTargetIds = <int>{};
  bool _autoSelect = true;
  int _autoSelectCount = 2;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _authorityGeneration = 0;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _authorityGeneration++;
        _countDraftDebounce?.cancel();
        closeAuthorityBoundDialog(context);
      },
    );
    // C11 handoff: when the dialog is opened seeded from an active project,
    // start in hand-pick mode with the project's incomplete targets selected.
    final seed = widget.seedTargetIds;
    if (seed != null && seed.isNotEmpty) {
      _autoSelect = false;
      _selectedTargetIds.addAll(seed);
    }
  }

  void _update(VoidCallback callback) => setState(callback);

  @override
  void dispose() {
    _backendSubscription?.close();
    _countDraftDebounce?.cancel();
    super.dispose();
  }

  bool _isCurrentAuthority(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _authorityGeneration &&
      identical(ref.read(backendProvider), backend);

  // Step 4: strategy
  SmartNightStrategy _strategy = SmartNightStrategy.autoLrgb;

  // Step 5: preview
  SmartNightPlan? _preview;
  String? _previewError;
  String? _previewDraftId;

  /// True while the (heavy) plan builder is running. Drives the primary
  /// button's busy/disabled state and guards [_onPrimaryPressed] against
  /// re-entry.
  bool _isBuildingPreview = false;

  /// True while the final plan is being launched (or saved as a template).
  /// Guards the terminal Start Sequence / Save-as-template actions against a
  /// double-tap re-entering the launcher before the dialog closes.
  bool _isStarting = false;

  /// Debounce timer for persisting count-tweak drafts. Each +/- tap patches
  /// the plan locally and immediately; the DB draft write is coalesced so a
  /// rapid burst of taps only persists the final count.
  Timer? _countDraftDebounce;

  // Settings (defaults; wizard can override)
  /// Local working copy of the wizard's [SmartNightSettings]. Seeded from
  /// the persisted defaults in [AppSettingsState] on first build; user
  /// changes are written back to settings so the next session pre-fills
  /// with the user's preferences.
  SmartNightSettings _settings = const SmartNightSettings();
  bool _settingsSeededFromAppSettings = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final appSettingsAsync = ref.watch(appSettingsProvider);
    if (appSettingsAsync.hasError) {
      return _buildSettingsGate(
        colors: colors,
        error: appSettingsAsync.error,
      );
    }
    final appSettings = appSettingsAsync.valueOrNull;
    if (appSettings == null) {
      return _buildSettingsGate(colors: colors);
    }
    _ensureSettingsSeeded(appSettings);
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 880,
      designHeight: 720,
    );
    return Dialog(
      backgroundColor: colors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: SkotiqTokens.borderRadiusMd,
        side: BorderSide(color: colors.border),
      ),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(colors),
              const SizedBox(height: 12),
              _buildStepIndicator(colors),
              const SizedBox(height: 16),
              Expanded(child: _buildStepBody(colors)),
              const SizedBox(height: 12),
              _buildFooter(colors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsGate({
    required SkotiqColors colors,
    Object? error,
  }) {
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 560,
      designHeight: 300,
    );
    return Dialog(
      backgroundColor: colors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: SkotiqTokens.borderRadiusMd,
        side: BorderSide(color: colors.border),
      ),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.sparkles, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Smart Night — Plan Tonight',
                      style: SkotiqTypography.h4
                          .copyWith(color: colors.textPrimary),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const Spacer(),
              if (error == null) ...[
                const Center(
                    child:
                        SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
                const SizedBox(height: 14),
                Text(
                  'Loading Smart Night settings…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textSecondary),
                ),
              ] else ...[
                Icon(
                  LucideIcons.alertTriangle,
                  size: 30,
                  color: colors.error,
                ),
                const SizedBox(height: 10),
                Text(
                  'Cannot load Smart Night settings',
                  textAlign: TextAlign.center,
                  style:
                      SkotiqTypography.h5.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary),
                ),
                const SizedBox(height: 12),
                Center(
                  child: SkotiqButton(
                    label: 'Retry',
                    icon: LucideIcons.refreshCw,
                    variant: ButtonVariant.outline,
                    size: ButtonSize.small,
                    onPressed: () => ref.invalidate(appSettingsProvider),
                  ),
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  // Header / stepper / footer

  void _ensureWindowInitialised() {
    if (_windowInitialised) return;
    final location = ref.read(appObserverLocationProvider);
    if (location == null) {
      _windowInitialised = true;
      return;
    }
    try {
      final window = _buildService().calculateWindow(
        latitudeDeg: location.latitude,
        longitudeDeg: location.longitude,
      );
      _windowStart = window.start;
      _windowEnd = window.end;
      _twilightStart = window.start;
      _twilightEnd = window.end;
    } on SmartNightBuildException catch (error) {
      _windowError = error.message;
    }
    _windowInitialised = true;
  }

  /// Pull persisted wizard defaults from [AppSettingsState] and apply them
  /// to [_settings] on first build. The wizard mutates [_settings] in
  /// place as the user changes controls; persistent writes are pushed
  /// back through [_persistSettings] so the next launch pre-fills with
  /// the user's last choices.
  ///
  /// We also pre-select the persisted default strategy so step 4 lands
  /// on whatever the user picked last time.
  void _ensureSettingsSeeded(AppSettingsState app) {
    if (_settingsSeededFromAppSettings) return;
    _settingsSeededFromAppSettings = true;

    // Translate the persisted minutes/hours into the wizard's native
    // units. `null` => use SmartNightSettings constructor default
    // (12h cap for max session, infinite per-target budget capped by
    // window in practice).
    final maxHours = app.smartNightMaxSessionHours;
    final defaultIntegrationHours =
        app.smartNightDefaultIntegrationBudgetMinsPerTarget / 60.0;
    _settings = _settings.copyWith(
      maxSessionHours: maxHours ?? _settings.maxSessionHours,
      afEveryFrames: app.smartNightDefaultAfCadenceFrames,
      defaultIntegrationBudgetHours: defaultIntegrationHours,
      includeFlatsAtEnd: app.smartNightIncludeFlatsAtEnd,
      useSchedulerForMultiTarget: app.smartNightUseSchedulerForMultiTarget,
      schedulerTargetThreshold: app.smartNightSchedulerTargetThreshold,
      polarAlignmentStaleAfterDays: app.smartNightPolarAlignmentStaleAfterDays,
      subExposureFloorSecs: app.smartNightSubExposureFloorSecs,
      subExposureCeilingSecs: app.smartNightSubExposureCeilingSecs,
      targetSnr: app.smartNightTargetSnr,
    );
    _strategy = _strategyFromPersistedName(app.smartNightDefaultStrategy);
    final seed = widget.seedTargetIds;
    if (seed == null || seed.isEmpty) {
      _autoSelect = app.smartNightAutoSelect;
      _autoSelectCount = app.smartNightAutoSelectCount.clamp(1, 10);
    }
  }

  /// Returns false only when the dialog's rig authority was invalidated.
  /// Ordinary build failures return true after populating [_previewError] so
  /// the Preview step can show its actionable error and Back affordance.
  Future<bool> _buildPreview() async {
    final backend = ref.read(backendProvider);
    final generation = _authorityGeneration;
    setState(() {
      _preview = null;
      _previewError = null;
      _previewDraftId = null;
    });

    try {
      var profile = ref.read(activeEquipmentProfileProvider);
      if (profile == null) {
        final profilesState = await ref.read(equipmentProfilesProvider.future);
        profile = profilesState.activeProfile;
      }
      if (profile == null) {
        setState(() => _previewError =
            'No active equipment profile — pick one on Equipment first.');
        return true;
      }
      final activeProfile = profile;
      final location = ref.read(appObserverLocationProvider);
      if (location == null ||
          (location.latitude == 0.0 && location.longitude == 0.0)) {
        setState(() => _previewError =
            'No observer location set — configure latitude / longitude in '
                'Settings first.');
        return true;
      }

      // Resolve the ranked candidate set; the service does NOT re-rank
      // when given a hand-picked list.
      final ranked = await ref.read(tonightSuggestionsProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return false;
      List<TargetSuggestion> selected;
      if (_autoSelect) {
        selected = ranked.take(_autoSelectCount).toList();
      } else {
        selected = ranked
            .where((s) => _selectedTargetIds.contains(s.targetId))
            .toList();
        if (selected.isEmpty) {
          setState(() => _previewError =
              'No selected targets matched tonight\'s rankings. They may '
                  'be below the altitude / score cut-offs.');
          return true;
        }
      }
      if (selected.isEmpty) {
        setState(() => _previewError =
            'No targets to plan with — saved targets list is empty or '
                'everything is below the altitude cut-off tonight.');
        return true;
      }

      // Build the cross-system context. Weather forecast probability
      // and dark library coverage come from existing providers — we
      // resolve them best-effort and fall back to null when not
      // available.
      final settings = await ref.read(appSettingsProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return false;
      final bortle = settings.bortleClass;
      final cloudCover = ref.read(cloudCoverPercentageProvider).valueOrNull;
      final cloudProb = cloudCover == null ? null : cloudCover / 100.0;

      // Polar alignment freshness.
      final lastPolarAlign =
          ref.read(lastPolarAlignmentProvider(activeProfile.id)).valueOrNull;
      int? daysSinceLastPolar;
      if (lastPolarAlign != null) {
        daysSinceLastPolar =
            DateTime.now().difference(lastPolarAlign.completedAt).inDays;
      }

      final effectiveSettings = _settings.copyWith(
        hasCoverCalibrator: _settings.hasCoverCalibrator ||
            activeProfile.coverCalibratorId != null,
      );
      var exposureContext =
          await ref.read(smartNightExposureContextProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return false;
      final sensorSpecs = await ref.read(
        activeCameraSensorSpecsProvider.future,
      );
      if (!_isCurrentAuthority(backend, generation)) return false;
      if (_shouldPromptForCameraSpecs(sensorSpecs)) {
        if (!mounted || !_isCurrentAuthority(backend, generation)) return false;
        final saved = await CameraSensorSpecsDialog.show(
          this.context,
          sensorSpecs,
        );
        if (!_isCurrentAuthority(backend, generation)) return false;
        if (saved) {
          ref.invalidate(smartNightExposureContextProvider);
          exposureContext =
              await ref.read(smartNightExposureContextProvider.future);
          if (!_isCurrentAuthority(backend, generation)) return false;
        }
      }

      // On a remote client the local dark library is the tablet's — empty —
      // not the rig's. Evaluating coverage against it would falsely report
      // every dark as missing and, with auto-schedule enabled, waste rig time
      // re-capturing darks the appliance already has. The rig owns its
      // calibration library, so skip the meaningless local computation here
      // (the plan's exposures/timing/targets come from synced settings +
      // profile and are unaffected). Browse the rig's darks via the
      // Calibration Library screen instead.
      final isRemoteBackend = ref.read(backendProvider) is NetworkBackend;
      final SmartNightDarkLibraryMissing darkLibraryMissing;
      if (exposureContext == null || isRemoteBackend) {
        darkLibraryMissing = const SmartNightDarkLibraryMissing.empty();
      } else {
        darkLibraryMissing = await SmartNightDarkLibraryCoverage(
          darkLibraryService: ref.read(darkLibraryServiceProvider),
        ).missing(
          profile: activeProfile,
          strategy: _strategy,
          settings: effectiveSettings,
          exposureContext: exposureContext,
          minCoverage: settings.darkLibraryMinCoverage,
        );
        if (!_isCurrentAuthority(backend, generation)) return false;
      }

      // The site's horizon with the obstructions runs have learned there, so
      // the plan's scheduler keeps targets clear of them.
      await ref.read(frameWatchSettingsProvider.future);
      if (!_isCurrentAuthority(backend, generation)) return false;
      final siteHorizon = ref.read(horizonProfileProvider);

      final context = SmartNightContext(
        windowStart: _windowStart!,
        windowEnd: _windowEnd!,
        rainOrCloudProbability: cloudProb,
        bortleClass: bortle,
        daysSinceLastPolarAlignment: daysSinceLastPolar,
        missingDarkLibraryNotes: darkLibraryMissing.notes,
        missingDarkRequirements: darkLibraryMissing.requirements,
        horizonProfile:
            siteHorizon.isFlat ? null : siteHorizon.toSchedulerProfile(),
      );

      await ref.read(hardwarePresetsServiceProvider.notifier).loaded;
      if (!mounted) return false;
      final plan = _buildService().build(
        profile: activeProfile,
        latitudeDeg: location.latitude,
        longitudeDeg: location.longitude,
        context: context,
        selectedSuggestions: selected,
        strategy: _strategy,
        settings: effectiveSettings,
        exposureContext: exposureContext,
      );
      final draft = await SmartNightDraftService(
        settingsDao: ref.read(settingsDaoProvider),
      ).savePending(
        profileId: activeProfile.id.toString(),
        astronomicalDay: context.windowStart,
        plan: plan,
      );
      if (!_isCurrentAuthority(backend, generation)) return false;
      setState(() {
        _preview = plan;
        _previewDraftId = draft.id;
      });
      return true;
    } on SmartNightBuildException catch (e) {
      if (!_isCurrentAuthority(backend, generation)) return false;
      setState(() => _previewError = e.message);
      return true;
    } catch (e) {
      if (!_isCurrentAuthority(backend, generation)) return false;
      setState(() => _previewError = 'Unexpected error: $e');
      return true;
    }
  }
}
