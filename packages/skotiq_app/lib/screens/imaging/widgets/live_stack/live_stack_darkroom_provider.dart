import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../../darkroom/edit/darkroom_image_library.dart';

/// Non-destructive Darkroom processing parameters applied in real time over an
/// active live stack filter via the native Rust Darkroom recipe engine.
@immutable
class LiveDarkroomRecipeSettings {
  final bool backgroundExtractEnabled;
  final int bgModelOrder;
  final double bgSampleSpacing;
  final double bgExclusionPercentile;

  final bool denoiseEnabled;
  final double denoiseStrength;
  final double denoiseThresholdSigma;
  final double denoiseChromaStrength;

  final bool colorBalanceEnabled;
  final double colorRedScale;
  final double colorGreenScale;
  final double colorBlueScale;

  /// Whether custom Generalised Hyperbolic Stretch parameters are active.
  /// When false (and no post-stretch op requires an explicit stretch), the
  /// Darkroom engine applies its own auto screen transfer for viewing.
  final bool stretchEnabled;
  final double stretchBlackPoint;
  final double stretchWhitePoint;
  final double stretchD;
  final double stretchB;
  final double stretchSymmetryPoint;

  /// True once `stretchBlackPoint` / `stretchWhitePoint` were measured from
  /// the live stack (or explicitly edited by the operator).
  final bool stretchMeasured;

  /// When true, re-measures stretch anchors automatically as new frames stack
  /// so faint signal reveals itself progressively. Automatically disabled if
  /// the operator manually tunes the GHS stretch sliders.
  final bool autoAdaptStretch;

  final bool saturationEnabled;
  final double saturationAmount;
  final double saturationProtection;

  final bool starReduceEnabled;
  final double starReduceAmount;
  final double starReduceThresholdSigma;

  const LiveDarkroomRecipeSettings({
    this.backgroundExtractEnabled = false,
    this.bgModelOrder = 2,
    this.bgSampleSpacing = 64.0,
    this.bgExclusionPercentile = 0.75,
    this.denoiseEnabled = false,
    this.denoiseStrength = 0.45,
    this.denoiseThresholdSigma = 2.5,
    this.denoiseChromaStrength = 0.5,
    this.colorBalanceEnabled = false,
    this.colorRedScale = 1.0,
    this.colorGreenScale = 1.0,
    this.colorBlueScale = 1.0,
    this.stretchEnabled = false,
    this.stretchBlackPoint = 0.0,
    this.stretchWhitePoint = 65535.0,
    this.stretchD = 3.0,
    this.stretchB = 2.0,
    this.stretchSymmetryPoint = 0.05,
    this.stretchMeasured = false,
    this.autoAdaptStretch = true,
    this.saturationEnabled = false,
    this.saturationAmount = 0.25,
    this.saturationProtection = 0.5,
    this.starReduceEnabled = false,
    this.starReduceAmount = 0.35,
    this.starReduceThresholdSigma = 5.0,
  });

  bool get hasAnyActiveStep =>
      backgroundExtractEnabled ||
      denoiseEnabled ||
      colorBalanceEnabled ||
      stretchEnabled ||
      saturationEnabled ||
      starReduceEnabled;

  LiveDarkroomRecipeSettings copyWith({
    bool? backgroundExtractEnabled,
    int? bgModelOrder,
    double? bgSampleSpacing,
    double? bgExclusionPercentile,
    bool? denoiseEnabled,
    double? denoiseStrength,
    double? denoiseThresholdSigma,
    double? denoiseChromaStrength,
    bool? colorBalanceEnabled,
    double? colorRedScale,
    double? colorGreenScale,
    double? colorBlueScale,
    bool? stretchEnabled,
    double? stretchBlackPoint,
    double? stretchWhitePoint,
    double? stretchD,
    double? stretchB,
    double? stretchSymmetryPoint,
    bool? stretchMeasured,
    bool? autoAdaptStretch,
    bool? saturationEnabled,
    double? saturationAmount,
    double? saturationProtection,
    bool? starReduceEnabled,
    double? starReduceAmount,
    double? starReduceThresholdSigma,
  }) {
    return LiveDarkroomRecipeSettings(
      backgroundExtractEnabled:
          backgroundExtractEnabled ?? this.backgroundExtractEnabled,
      bgModelOrder: bgModelOrder ?? this.bgModelOrder,
      bgSampleSpacing: bgSampleSpacing ?? this.bgSampleSpacing,
      bgExclusionPercentile:
          bgExclusionPercentile ?? this.bgExclusionPercentile,
      denoiseEnabled: denoiseEnabled ?? this.denoiseEnabled,
      denoiseStrength: denoiseStrength ?? this.denoiseStrength,
      denoiseThresholdSigma:
          denoiseThresholdSigma ?? this.denoiseThresholdSigma,
      denoiseChromaStrength:
          denoiseChromaStrength ?? this.denoiseChromaStrength,
      colorBalanceEnabled: colorBalanceEnabled ?? this.colorBalanceEnabled,
      colorRedScale: colorRedScale ?? this.colorRedScale,
      colorGreenScale: colorGreenScale ?? this.colorGreenScale,
      colorBlueScale: colorBlueScale ?? this.colorBlueScale,
      stretchEnabled: stretchEnabled ?? this.stretchEnabled,
      stretchBlackPoint: stretchBlackPoint ?? this.stretchBlackPoint,
      stretchWhitePoint: stretchWhitePoint ?? this.stretchWhitePoint,
      stretchD: stretchD ?? this.stretchD,
      stretchB: stretchB ?? this.stretchB,
      stretchSymmetryPoint: stretchSymmetryPoint ?? this.stretchSymmetryPoint,
      stretchMeasured: stretchMeasured ?? this.stretchMeasured,
      autoAdaptStretch: autoAdaptStretch ?? this.autoAdaptStretch,
      saturationEnabled: saturationEnabled ?? this.saturationEnabled,
      saturationAmount: saturationAmount ?? this.saturationAmount,
      saturationProtection: saturationProtection ?? this.saturationProtection,
      starReduceEnabled: starReduceEnabled ?? this.starReduceEnabled,
      starReduceAmount: starReduceAmount ?? this.starReduceAmount,
      starReduceThresholdSigma:
          starReduceThresholdSigma ?? this.starReduceThresholdSigma,
    );
  }

  /// Compile into valid Darkroom wire recipe steps (`linear` stage ops before
  /// `stretched` stage ops).
  List<Map<String, dynamic>> toRecipeSteps({required bool isColor}) {
    final steps = <Map<String, dynamic>>[];

    if (backgroundExtractEnabled) {
      steps.add(<String, dynamic>{
        'opId': 'background_extract',
        'opVersion': 1,
        'enabled': true,
        'params': <String, dynamic>{
          'modelOrder': bgModelOrder.clamp(0, 6),
          'sampleSpacing': bgSampleSpacing.clamp(8.0, 1024.0),
          'exclusionPercentile': bgExclusionPercentile.clamp(0.05, 1.0),
        },
      });
    }

    if (denoiseEnabled) {
      steps.add(<String, dynamic>{
        'opId': 'denoise',
        'opVersion': 1,
        'enabled': true,
        'params': <String, dynamic>{
          'scaleCount': 4,
          'thresholdSigma': denoiseThresholdSigma.clamp(0.0, 10.0),
          'strength': denoiseStrength.clamp(0.0, 1.0),
          'chromaStrength':
              isColor ? denoiseChromaStrength.clamp(0.0, 1.0) : 0.0,
        },
      });
    }

    if (isColor && colorBalanceEnabled) {
      steps.add(<String, dynamic>{
        'opId': 'color_calibrate',
        'opVersion': 1,
        'enabled': true,
        'params': <String, dynamic>{
          'channelScale': <double>[
            colorRedScale.clamp(1e-6, 1e6),
            colorGreenScale.clamp(1e-6, 1e6),
            colorBlueScale.clamp(1e-6, 1e6),
          ],
        },
      });
    }

    // Any post-stretch operation requires the image to have entered the
    // stretched domain first.
    final needsStretch =
        stretchEnabled || (isColor && saturationEnabled) || starReduceEnabled;
    if (needsStretch) {
      final bp = stretchBlackPoint;
      final wp =
          stretchWhitePoint > bp + 1e-3 ? stretchWhitePoint : bp + 1000.0;
      steps.add(<String, dynamic>{
        'opId': 'stretch',
        'opVersion': 1,
        'enabled': true,
        'params': <String, dynamic>{
          'blackPoint': bp,
          'whitePoint': wp,
          'd': stretchD.clamp(0.0, 10000.0),
          'b': stretchB.clamp(-5.0, 15.0),
          'symmetryPoint': stretchSymmetryPoint.clamp(0.0, 1.0),
        },
      });
    }

    if (isColor && saturationEnabled) {
      steps.add(<String, dynamic>{
        'opId': 'saturation',
        'opVersion': 1,
        'enabled': true,
        'params': <String, dynamic>{
          'amount': saturationAmount.clamp(-1.0, 3.0),
          'protection': saturationProtection.clamp(0.0, 1.0),
        },
      });
    }

    if (starReduceEnabled) {
      steps.add(<String, dynamic>{
        'opId': 'star_reduce',
        'opVersion': 1,
        'enabled': true,
        'params': <String, dynamic>{
          'amount': starReduceAmount.clamp(0.0, 1.0),
          'maskThresholdSigma': starReduceThresholdSigma.clamp(1.0, 20.0),
          'maskDilatePx': 2.0,
        },
      });
    }

    return steps;
  }

  /// Build the canonical Darkroom recipe JSON payload for rendering.
  String toRecipeJson({
    required String filterKey,
    required bool isColor,
  }) {
    final payload = <String, dynamic>{
      'id': 'live-$filterKey',
      'schemaVersion': recipeSchemaVersion,
      'baseMasterRef': 'livestack:$filterKey',
      'createdBy': 'user',
      'steps': toRecipeSteps(isColor: isColor),
    };
    return jsonEncode(payload);
  }
}

/// Summary of one Darkroom step outcome from the most recent live render.
@immutable
class LiveDarkroomStepOutcome {
  final String opId;
  final String outcome;
  final String? reason;

  const LiveDarkroomStepOutcome({
    required this.opId,
    required this.outcome,
    this.reason,
  });
}

/// Cached RGBA8 output from the Darkroom recipe engine for one filter stack.
@immutable
class LiveDarkroomRenderResult {
  final String filterKey;
  final int stackRevision;
  final int width;
  final int height;
  final bool isColor;
  final Uint8List rgba;
  final List<LiveDarkroomStepOutcome> stepOutcomes;

  const LiveDarkroomRenderResult({
    required this.filterKey,
    required this.stackRevision,
    required this.width,
    required this.height,
    required this.isColor,
    required this.rgba,
    this.stepOutcomes = const [],
  });
}

@immutable
class LiveStackDarkroomState {
  final bool enabled;

  /// When true, temporarily displays the raw auto-stretched stack for A/B
  /// comparison while keeping live Darkroom enabled.
  final bool compareBeforeAfter;

  final Map<String, LiveDarkroomRecipeSettings> settingsByFilter;

  /// Latest rendered RGBA frames keyed by filter key.
  final Map<String, LiveDarkroomRenderResult> renderedByFilter;

  final bool isRendering;
  final bool isAutoDeveloping;
  final String? error;

  const LiveStackDarkroomState({
    this.enabled = false,
    this.compareBeforeAfter = false,
    this.settingsByFilter = const {},
    this.renderedByFilter = const {},
    this.isRendering = false,
    this.isAutoDeveloping = false,
    this.error,
  });

  LiveDarkroomRecipeSettings settingsFor(String filterKey) =>
      settingsByFilter[filterKey] ?? const LiveDarkroomRecipeSettings();

  LiveDarkroomRenderResult? renderFor(String filterKey) =>
      renderedByFilter[filterKey];

  LiveStackDarkroomState copyWith({
    bool? enabled,
    bool? compareBeforeAfter,
    Map<String, LiveDarkroomRecipeSettings>? settingsByFilter,
    Map<String, LiveDarkroomRenderResult>? renderedByFilter,
    bool? isRendering,
    bool? isAutoDeveloping,
    String? error,
    bool clearError = false,
  }) {
    return LiveStackDarkroomState(
      enabled: enabled ?? this.enabled,
      compareBeforeAfter: compareBeforeAfter ?? this.compareBeforeAfter,
      settingsByFilter: settingsByFilter ?? this.settingsByFilter,
      renderedByFilter: renderedByFilter ?? this.renderedByFilter,
      isRendering: isRendering ?? this.isRendering,
      isAutoDeveloping: isAutoDeveloping ?? this.isAutoDeveloping,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives real-time non-destructive Darkroom rendering over active live stacks.
class LiveStackDarkroomNotifier extends StateNotifier<LiveStackDarkroomState> {
  LiveStackDarkroomNotifier(this._ref) : super(const LiveStackDarkroomState()) {
    _ref.listen<LiveStackingState>(liveStackingProvider, (previous, next) {
      if (next.status != LiveStackingStatus.running) {
        _renderDebounce?.cancel();
        _measuredRevisionByFilter.clear();
        final clearedSettings = state.settingsByFilter.isEmpty
            ? state.settingsByFilter
            : Map<String, LiveDarkroomRecipeSettings>.unmodifiable({
                for (final entry in state.settingsByFilter.entries)
                  entry.key: entry.value.copyWith(stretchMeasured: false),
              });
        if (state.renderedByFilter.isNotEmpty ||
            state.error != null ||
            state.settingsByFilter.values.any((s) => s.stretchMeasured)) {
          state = state.copyWith(
            settingsByFilter: clearedSettings,
            renderedByFilter: const {},
            isRendering: false,
            clearError: true,
          );
        }
        return;
      }
      if (!state.enabled) return;
      final active = next.activeFilterStack;
      if (active == null || !active.hasPixels) return;
      final prevActive = previous?.filterStacks[active.filterKey];
      final filterChanged =
          previous?.selectedFilterKey != next.selectedFilterKey;
      final revisionChanged = prevActive?.revision != active.revision;
      if (filterChanged || revisionChanged) {
        _scheduleRender(active.filterKey, immediate: filterChanged);
      }
    });
  }

  final Ref _ref;
  Timer? _renderDebounce;
  int _renderGeneration = 0;
  bool _renderInFlight = false;
  String? _inFlightRenderId;
  String? _queuedFilterKey;
  final Map<String, int> _measuredRevisionByFilter = <String, int>{};

  DarkroomSeam get _darkroom => _ref.read(darkroomSeamProvider);

  void _cancelInFlightRender() {
    final renderId = _inFlightRenderId;
    if (renderId == null) return;
    _inFlightRenderId = null;
    if (_ref.read(isRemoteClientProvider)) return;
    unawaited(
      _darkroom.cancel(<String, dynamic>{
        'op': 'cancel',
        'renderId': renderId
      }).catchError((Object _) => const <String, dynamic>{}),
    );
  }

  Future<void> setEnabled(bool enabled) async {
    if (state.enabled == enabled) return;
    state = state.copyWith(
      enabled: enabled,
      compareBeforeAfter: false,
      clearError: true,
    );
    if (!enabled) {
      _renderDebounce?.cancel();
      return;
    }
    final active = _ref.read(liveStackingProvider).activeFilterStack;
    if (active == null || !active.hasPixels) return;
    final current = state.settingsFor(active.filterKey);
    if (!current.stretchMeasured) {
      await _measureStretchDefaults(active.filterKey);
      if (!mounted || !state.enabled) return;
    }
    _scheduleRender(active.filterKey, immediate: true);
  }

  void toggleCompareBeforeAfter() {
    if (!state.enabled) return;
    state = state.copyWith(compareBeforeAfter: !state.compareBeforeAfter);
  }

  /// Measure auto-stretch parameters from the live stack in Rust and apply a
  /// clean one-click EAA Darkroom recipe (background extraction + GHS stretch +
  /// gentle denoise).
  Future<void> autoDevelop(String filterKey) async {
    if (_ref.read(isRemoteClientProvider)) return;
    state = state.copyWith(
      enabled: true,
      compareBeforeAfter: false,
      isAutoDeveloping: true,
      clearError: true,
    );
    try {
      final measured = await _measureStretchDefaults(filterKey);
      if (!mounted) return;
      final nextSettings = measured.copyWith(
        backgroundExtractEnabled: true,
        stretchEnabled: true,
        autoAdaptStretch: true,
        denoiseEnabled: true,
        denoiseStrength: 0.35,
      );
      final map = Map<String, LiveDarkroomRecipeSettings>.of(
        state.settingsByFilter,
      )..[filterKey] = nextSettings;
      state = state.copyWith(
        settingsByFilter: Map.unmodifiable(map),
        isAutoDeveloping: false,
      );
      if (state.enabled) {
        _scheduleRender(filterKey, immediate: true);
      }
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isAutoDeveloping: false,
        error: 'Auto-develop failed: ${userFacingError(error)}',
      );
    }
  }

  /// Re-measure black/white/GHS stretch anchors from the current live stack
  /// without altering other enabled steps.
  Future<LiveDarkroomRecipeSettings> _measureStretchDefaults(
    String filterKey,
  ) async {
    final existing = state.settingsFor(filterKey);
    if (_ref.read(isRemoteClientProvider)) return existing;
    try {
      final reply = await _darkroom.registry(<String, dynamic>{
        'liveStackKey': filterKey,
        'recipeId': 'live-$filterKey',
      });
      if (!mounted) return existing;
      final measuredRev =
          _ref.read(liveStackingProvider).filterStacks[filterKey]?.revision;
      if (measuredRev != null) {
        _measuredRevisionByFilter[filterKey] = measuredRev;
      }
      final params = DarkroomRegistryDraft.of(reply)?.paramsOf('stretch');
      if (params != null) {
        final bp = (params['blackPoint'] as num?)?.toDouble();
        final wp = (params['whitePoint'] as num?)?.toDouble();
        final d = (params['d'] as num?)?.toDouble();
        final b = (params['b'] as num?)?.toDouble();
        final sp = (params['symmetryPoint'] as num?)?.toDouble();
        if (bp != null && wp != null && wp > bp) {
          // Re-read the latest filter settings after the await so any
          // concurrent slider adjustments are preserved.
          final latest = state.settingsFor(filterKey);
          final updated = latest.copyWith(
            stretchBlackPoint: bp,
            stretchWhitePoint: wp,
            stretchD: d ?? latest.stretchD,
            stretchB: b ?? latest.stretchB,
            stretchSymmetryPoint: sp ?? latest.stretchSymmetryPoint,
            stretchMeasured: true,
          );
          final map = Map<String, LiveDarkroomRecipeSettings>.of(
            state.settingsByFilter,
          )..[filterKey] = updated;
          state = state.copyWith(settingsByFilter: Map.unmodifiable(map));
          return updated;
        }
      }
    } catch (error) {
      developer.log(
        '[LiveStackDarkroom] Could not measure stretch defaults: $error',
        name: 'LiveStackDarkroom',
      );
    }
    return mounted ? state.settingsFor(filterKey) : existing;
  }

  /// Update one filter's Darkroom controls and schedule a debounced live render.
  Future<void> updateSettings(
    String filterKey,
    LiveDarkroomRecipeSettings next,
  ) async {
    final map = Map<String, LiveDarkroomRecipeSettings>.of(
      state.settingsByFilter,
    )..[filterKey] = next;
    state = state.copyWith(
      enabled: true,
      compareBeforeAfter: false,
      settingsByFilter: Map.unmodifiable(map),
      clearError: true,
    );
    if (!next.stretchMeasured &&
        (next.stretchEnabled ||
            next.saturationEnabled ||
            next.starReduceEnabled)) {
      await _measureStretchDefaults(filterKey);
      if (!mounted || !state.enabled) return;
    }
    _scheduleRender(filterKey, immediate: false);
  }

  void resetFilterSettings(String filterKey) {
    final map = Map<String, LiveDarkroomRecipeSettings>.of(
      state.settingsByFilter,
    )..remove(filterKey);
    final rendered = Map<String, LiveDarkroomRenderResult>.of(
      state.renderedByFilter,
    )..remove(filterKey);
    state = state.copyWith(
      settingsByFilter: Map.unmodifiable(map),
      renderedByFilter: Map.unmodifiable(rendered),
      clearError: true,
    );
    if (state.enabled) {
      _scheduleRender(filterKey, immediate: true);
    }
  }

  void _scheduleRender(String filterKey, {required bool immediate}) {
    _renderGeneration++;
    _renderDebounce?.cancel();
    _cancelInFlightRender();
    if (immediate) {
      unawaited(_runRender(filterKey));
    } else {
      _renderDebounce = Timer(
        const Duration(milliseconds: 120),
        () => unawaited(_runRender(filterKey)),
      );
    }
  }

  Future<void> _runRender(String filterKey) async {
    if (!mounted || !state.enabled) return;
    if (_ref.read(isRemoteClientProvider)) return;

    final stackState = _ref.read(liveStackingProvider);
    final snap = stackState.filterStacks[filterKey];
    if (snap == null || !snap.hasPixels) return;

    if (_renderInFlight) {
      _queuedFilterKey = filterKey;
      _cancelInFlightRender();
      return;
    }

    _renderInFlight = true;
    final gen = _renderGeneration;
    final renderId = 'livestack-$filterKey-$gen';
    _inFlightRenderId = renderId;
    var settings = state.settingsFor(filterKey);
    final isColor = snap.channels >= 3;
    state = state.copyWith(isRendering: true, clearError: true);

    try {
      // If auto-adapt is active and a newer stack revision arrived, re-measure
      // stretch anchors from the deeper F32 integration before rendering so
      // faint structure continues to emerge automatically.
      final needsExplicitStretch = settings.stretchEnabled ||
          (isColor && settings.saturationEnabled) ||
          settings.starReduceEnabled;
      if (needsExplicitStretch &&
          settings.autoAdaptStretch &&
          _measuredRevisionByFilter[filterKey] != snap.revision) {
        settings = await _measureStretchDefaults(filterKey);
        if (!mounted || gen != _renderGeneration) return;
        _measuredRevisionByFilter[filterKey] = snap.revision;
      }

      final recipeJson = settings.toRecipeJson(
        filterKey: filterKey,
        isColor: isColor,
      );
      final preview = await _darkroom.renderPreview(
        recipeJson: recipeJson,
        context: <String, dynamic>{
          'liveStackKey': filterKey,
          'maxDimension': 1600,
          'encoding': 'auto',
          'renderId': renderId,
        },
      );
      if (!mounted) return;
      if (gen != _renderGeneration) return;

      final outcomes = <LiveDarkroomStepOutcome>[];
      final report = preview.report['report'];
      if (report is Map && report['steps'] is List) {
        for (final entry in report['steps'] as List) {
          if (entry
              case {
                'opId': final String opId,
                'outcome': final String outcome,
              } when opId.isNotEmpty && outcome.isNotEmpty) {
            final reason = entry['reason'];
            outcomes.add(
              LiveDarkroomStepOutcome(
                opId: opId,
                outcome: outcome,
                reason: reason is String ? reason : null,
              ),
            );
          }
        }
      }

      final rendered = Map<String, LiveDarkroomRenderResult>.of(
        state.renderedByFilter,
      )..[filterKey] = LiveDarkroomRenderResult(
          filterKey: filterKey,
          stackRevision: snap.revision,
          width: preview.width,
          height: preview.height,
          isColor: preview.isColor,
          rgba: preview.rgba,
          stepOutcomes: List.unmodifiable(outcomes),
        );
      state = state.copyWith(
        renderedByFilter: Map.unmodifiable(rendered),
        isRendering: false,
      );
    } on DarkroomCancelledOutcome {
      // Superseded render — quiet.
    } catch (error) {
      if (!mounted || gen != _renderGeneration) return;
      state = state.copyWith(
        isRendering: false,
        error: 'Live Darkroom render failed: ${userFacingError(error)}',
      );
    } finally {
      if (_inFlightRenderId == renderId) {
        _inFlightRenderId = null;
      }
      _renderInFlight = false;
      final queued = _queuedFilterKey;
      _queuedFilterKey = null;
      if (queued != null && mounted && state.enabled) {
        unawaited(_runRender(queued));
      } else if (mounted && state.isRendering) {
        state = state.copyWith(isRendering: false);
      }
    }
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    _cancelInFlightRender();
    super.dispose();
  }
}

final liveStackDarkroomProvider =
    StateNotifierProvider<LiveStackDarkroomNotifier, LiveStackDarkroomState>(
  (ref) => LiveStackDarkroomNotifier(ref),
);

/// Open in Darkroom: persist the active live stack for [filterKey] as a
/// Darkroom master, keeping the operator's live Darkroom edit as a recipe, and
/// return the IDs needed to navigate straight to `/darkroom`.
Future<LiveStackDarkroomPromotion> promoteLiveStackToDarkroom({
  required WidgetRef ref,
  required String filterKey,
}) async {
  final darkroomState = ref.read(liveStackDarkroomProvider);
  final settings = darkroomState.settingsFor(filterKey);
  final sessionState = ref.read(sessionStateProvider);
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final promoted = await ref.read(liveStackDarkroomPromoterProvider).promote(
        stack: ref.read(liveStackingProvider),
        filterKey: filterKey,
        targetName: sessionState.targetName,
        sessionId: sessionState.dbSessionId,
        recipeSteps: darkroomState.enabled && settings.hasAnyActiveStep
            ? settings.toRecipeSteps
            : null,
      );
  container.invalidate(darkroomImageLibraryProvider);
  return promoted;
}
