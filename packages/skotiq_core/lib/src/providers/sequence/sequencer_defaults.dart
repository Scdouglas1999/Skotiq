import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart'
    show
        BinningMode,
        LiveStackingMethod,
        LiveStackingThumbnailSize,
        SequenceOverheadConfig;
import '../../settings/setting.dart';
import '../../settings/store_settings.dart';
import '../database_provider.dart';

/// Sentinel used by [SequencerDefaults.copyWith] to distinguish "leave
/// unchanged" from "explicitly clear to null" for nullable String? fields.
const Object _sentinel = Object();

/// Provider for sequencer default settings (persisted via settings DAO)
final sequencerDefaultsProvider =
    StateNotifierProvider<SequencerDefaultsNotifier, SequencerDefaults>((ref) {
      // Reload when the settings rows change underneath, e.g. on the host.
      ref.watch(settingsDaoProvider);
      return SequencerDefaultsNotifier(ref);
    });

/// Single [SequenceOverheadConfig] derived from the user's
/// [SequencerDefaults] so the time estimator, the tree-row rollup and the
/// pre-flight simulation all share ONE overhead model instead of divergent
/// sets of literals.
///
/// Only the fields the user actually configures in Sequencer Settings (dither
/// settle time, per-frame download overhead) are mapped from defaults; the
/// remaining fields keep the [SequenceOverheadConfig] field defaults.
final sequencerOverheadConfigProvider = Provider<SequenceOverheadConfig>((ref) {
  final defaults = ref.watch(sequencerDefaultsProvider);
  return SequenceOverheadConfig(
    // User-configured dither settle time drives the dither/settle cycle cost.
    ditherSecs: defaults.ditherSettleTime,
    // Shared per-frame download overhead (also fed into the ETA smoother).
    downloadOverheadPerExposureSecs: defaults.frameDownloadOverheadSecs,
  );
});

class SequencerDefaults {
  final int autofocusStepSize;
  final int autofocusStepsOut;
  final double autofocusExposureDuration;

  /// Cadence (frames between autofocus runs) for the
  /// standard `AutofocusInterval` trigger seeded into every executor. The
  /// Rust default in `skotiq_sequencer::default_autofocus_interval_frames()`
  /// is 25, which is wildly wrong for both very-short (5 s) and very-long
  /// (5 min) subs. Exposed in Sequencer Settings so the user can match the
  /// cadence to their actual sub-exposure length.
  final int autofocusIntervalFrames;

  final double ditherPixels;
  final double ditherSettleTime;
  final double ditherSettlePixels;
  final double ditherSettleTimeout;
  final bool ditherRaOnly;

  final double exposureDuration;
  final bool isExposureDurationConfigured;
  final int exposureCount;
  final String? exposureFilter;
  final int? exposureGain;
  final int? exposureOffset;
  final BinningMode exposureBinning;
  final int exposureDitherEvery;

  /// Fixed per-frame download + save overhead (seconds) folded into the
  /// ETA per-frame sample alongside the real exposure duration. Not user-
  /// editable today (no Settings surface persists it), but exposed as a
  /// field so the ETA smoother and the overhead estimator share one
  /// constant instead of two divergent literals.
  final double frameDownloadOverheadSecs;

  // LiveStacking defaults (palette + properties editor)
  /// Default TCP port the broadcast endpoints bind to. 8081 keeps clear
  /// of the headless API server's default (8080) and the dashboard.
  final int livestackingDefaultPort;

  /// Whether new LiveStacking nodes default to a public-access (no
  /// auth token) broadcast. Off by default — public outreach must be
  /// an explicit choice, not the accidental default.
  final bool livestackingPublicByDefault;

  /// Default stack-combine method used by newly-created nodes.
  final LiveStackingMethod livestackingDefaultStackMethod;

  /// Default watermark template (variable interpolation applied at
  /// render time). `null` = no watermark.
  final String? livestackingDefaultWatermark;

  /// Default broadcast thumbnail size preset used when the user drops
  /// a new LiveStackingNode. The properties editor exposes width / height
  /// directly; this default maps to a friendlier "small / medium / large"
  /// chooser in Settings.
  final LiveStackingThumbnailSize livestackingDefaultThumbnailSize;

  /// Master kill switch. When true, every LiveStackingNode
  /// at runtime has `broadcastEnabled` forced to false (the stack still
  /// builds in memory but the broadcast endpoint returns 404). Distinct
  /// from `livestackingPublicByDefault`, which only flips per-node
  /// defaults — this is a global override consulted at sequence-start
  /// and on live config changes. Off (broadcasts allowed) by default.
  final bool livestackingDisableEverywhere;

  const SequencerDefaults({
    required this.autofocusStepSize,
    required this.autofocusStepsOut,
    required this.autofocusExposureDuration,
    required this.autofocusIntervalFrames,
    required this.ditherPixels,
    required this.ditherSettleTime,
    required this.ditherSettlePixels,
    required this.ditherSettleTimeout,
    required this.ditherRaOnly,
    required this.exposureDuration,
    required this.isExposureDurationConfigured,
    required this.exposureCount,
    required this.exposureFilter,
    required this.exposureGain,
    required this.exposureOffset,
    required this.exposureBinning,
    required this.exposureDitherEvery,
    this.frameDownloadOverheadSecs = 2.0,
    required this.livestackingDefaultPort,
    required this.livestackingPublicByDefault,
    required this.livestackingDefaultStackMethod,
    required this.livestackingDefaultWatermark,
    required this.livestackingDefaultThumbnailSize,
    required this.livestackingDisableEverywhere,
  });

  /// The defaults held in the stored [rows]. A setting with no row, or one
  /// that cannot be read, is at its declared default.
  factory SequencerDefaults.fromRows(Map<String, String> rows) {
    T value<T>(Setting<T> setting) => setting.fromRows(rows, setting.fallback);
    final storedDuration = value(StoreSettings.sequencerExposureDuration);
    final durationChosen = storedDuration != null && storedDuration > 0;
    return SequencerDefaults(
      autofocusStepSize: value(StoreSettings.sequencerAutofocusStepSize),
      autofocusStepsOut: value(StoreSettings.sequencerAutofocusStepsOut),
      autofocusExposureDuration: value(
        StoreSettings.sequencerAutofocusExposure,
      ),
      autofocusIntervalFrames: value(
        StoreSettings.sequencerAutofocusIntervalFrames,
      ),
      ditherPixels: value(StoreSettings.sequencerDitherPixels),
      ditherSettleTime: value(StoreSettings.sequencerDitherSettleTime),
      ditherSettlePixels: value(StoreSettings.sequencerDitherSettlePixels),
      ditherSettleTimeout: value(StoreSettings.sequencerDitherSettleTimeout),
      ditherRaOnly: value(StoreSettings.sequencerDitherRaOnly),
      exposureDuration: durationChosen
          ? storedDuration
          : _exposureSecsBeforeOneIsChosen,
      isExposureDurationConfigured: durationChosen,
      exposureCount: value(StoreSettings.sequencerExposureCount),
      exposureFilter: value(StoreSettings.sequencerExposureFilter),
      exposureGain: value(StoreSettings.sequencerExposureGain),
      exposureOffset: value(StoreSettings.sequencerExposureOffset),
      exposureBinning: value(StoreSettings.sequencerExposureBinning),
      exposureDitherEvery: value(StoreSettings.sequencerExposureDitherEvery),
      livestackingDefaultPort: value(StoreSettings.liveStackingPort),
      livestackingPublicByDefault: value(
        StoreSettings.liveStackingPublicByDefault,
      ),
      livestackingDefaultStackMethod: LiveStackingMethod.fromStorageKey(
        value(StoreSettings.liveStackingStackMethod),
      ),
      livestackingDefaultWatermark: value(StoreSettings.liveStackingWatermark),
      livestackingDefaultThumbnailSize: value(
        StoreSettings.liveStackingThumbnailSize,
      ),
      livestackingDisableEverywhere: value(
        StoreSettings.liveStackingDisableEverywhere,
      ),
    );
  }

  /// Every default as declared, before anything is stored.
  static final SequencerDefaults initial = SequencerDefaults.fromRows(const {});

  static const double _exposureSecsBeforeOneIsChosen = 60.0;

  /// The settings these defaults are read from.
  static const List<Setting<Object?>> settings = [
    StoreSettings.sequencerAutofocusStepSize,
    StoreSettings.sequencerAutofocusStepsOut,
    StoreSettings.sequencerAutofocusExposure,
    StoreSettings.sequencerAutofocusIntervalFrames,
    StoreSettings.sequencerDitherPixels,
    StoreSettings.sequencerDitherSettleTime,
    StoreSettings.sequencerDitherSettlePixels,
    StoreSettings.sequencerDitherSettleTimeout,
    StoreSettings.sequencerDitherRaOnly,
    StoreSettings.sequencerExposureDuration,
    StoreSettings.sequencerExposureCount,
    StoreSettings.sequencerExposureFilter,
    StoreSettings.sequencerExposureGain,
    StoreSettings.sequencerExposureOffset,
    StoreSettings.sequencerExposureBinning,
    StoreSettings.sequencerExposureDitherEvery,
    StoreSettings.liveStackingPort,
    StoreSettings.liveStackingPublicByDefault,
    StoreSettings.liveStackingStackMethod,
    StoreSettings.liveStackingWatermark,
    StoreSettings.liveStackingThumbnailSize,
    StoreSettings.liveStackingDisableEverywhere,
  ];

  SequencerDefaults copyWith({
    int? autofocusStepSize,
    int? autofocusStepsOut,
    double? autofocusExposureDuration,
    int? autofocusIntervalFrames,
    double? ditherPixels,
    double? ditherSettleTime,
    double? ditherSettlePixels,
    double? ditherSettleTimeout,
    bool? ditherRaOnly,
    double? exposureDuration,
    bool? isExposureDurationConfigured,
    int? exposureCount,
    String? exposureFilter,
    int? exposureGain,
    int? exposureOffset,
    BinningMode? exposureBinning,
    int? exposureDitherEvery,
    double? frameDownloadOverheadSecs,
    int? livestackingDefaultPort,
    bool? livestackingPublicByDefault,
    LiveStackingMethod? livestackingDefaultStackMethod,
    Object? livestackingDefaultWatermark = _sentinel,
    LiveStackingThumbnailSize? livestackingDefaultThumbnailSize,
    bool? livestackingDisableEverywhere,
  }) {
    return SequencerDefaults(
      autofocusStepSize: autofocusStepSize ?? this.autofocusStepSize,
      autofocusStepsOut: autofocusStepsOut ?? this.autofocusStepsOut,
      autofocusExposureDuration:
          autofocusExposureDuration ?? this.autofocusExposureDuration,
      autofocusIntervalFrames:
          autofocusIntervalFrames ?? this.autofocusIntervalFrames,
      ditherPixels: ditherPixels ?? this.ditherPixels,
      ditherSettleTime: ditherSettleTime ?? this.ditherSettleTime,
      ditherSettlePixels: ditherSettlePixels ?? this.ditherSettlePixels,
      ditherSettleTimeout: ditherSettleTimeout ?? this.ditherSettleTimeout,
      ditherRaOnly: ditherRaOnly ?? this.ditherRaOnly,
      exposureDuration: exposureDuration ?? this.exposureDuration,
      isExposureDurationConfigured:
          isExposureDurationConfigured ?? this.isExposureDurationConfigured,
      exposureCount: exposureCount ?? this.exposureCount,
      exposureFilter: exposureFilter ?? this.exposureFilter,
      exposureGain: exposureGain ?? this.exposureGain,
      exposureOffset: exposureOffset ?? this.exposureOffset,
      exposureBinning: exposureBinning ?? this.exposureBinning,
      frameDownloadOverheadSecs:
          frameDownloadOverheadSecs ?? this.frameDownloadOverheadSecs,
      livestackingDefaultPort:
          livestackingDefaultPort ?? this.livestackingDefaultPort,
      livestackingPublicByDefault:
          livestackingPublicByDefault ?? this.livestackingPublicByDefault,
      livestackingDefaultStackMethod:
          livestackingDefaultStackMethod ?? this.livestackingDefaultStackMethod,
      livestackingDefaultWatermark: livestackingDefaultWatermark == _sentinel
          ? this.livestackingDefaultWatermark
          : livestackingDefaultWatermark as String?,
      livestackingDefaultThumbnailSize:
          livestackingDefaultThumbnailSize ??
          this.livestackingDefaultThumbnailSize,
      livestackingDisableEverywhere:
          livestackingDisableEverywhere ?? this.livestackingDisableEverywhere,
      exposureDitherEvery: exposureDitherEvery ?? this.exposureDitherEvery,
    );
  }
}

class SequencerDefaultsNotifier extends StateNotifier<SequencerDefaults> {
  final Ref _ref;

  SequencerDefaultsNotifier(this._ref) : super(SequencerDefaults.initial) {
    _loadFuture = _loadDefaults();
  }

  late final Future<void> _loadFuture;

  /// Wait until the saved defaults have been read from the database.
  ///
  /// Until then [state] holds the declared defaults. A start that is this
  /// provider's first reader -- every headless night -- otherwise pushed those
  /// to the executor instead of the operator's saved dither and autofocus
  /// cadence (dither settle 30 s instead of 3 s, refocus every 25 frames
  /// instead of 60, measured by the simulator soak).
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _loadDefaults() async {
    final rows = await _ref
        .read(settingsDaoProvider)
        .readRows(SequencerDefaults.settings);

    // The provider that started this read can be gone by now: a container
    // torn down while the read is in flight, which is what a run start does
    // when it instantiates the defaults on its way to seeding the executor.
    // Writing `state` on a disposed StateNotifier raises a Bad state that
    // surfaces as an unhandled async error against whatever runs next; with
    // the container gone there is no reader left for the value.
    if (!mounted) return;
    state = SequencerDefaults.fromRows(rows);
  }

  Future<void> _store(List<SettingValue<Object?>> values) async {
    if (values.isEmpty) return;
    await _ref.read(settingsDaoProvider).writeAll(values);
  }

  /// Persist the LiveStacking palette defaults so a
  /// "drop a Live Stacking node" emits a node with the user's preferred
  /// port / stack method / watermark template.
  Future<void> updateLiveStackingDefaults({
    int? defaultPort,
    bool? publicByDefault,
    LiveStackingMethod? defaultStackMethod,
    Object? defaultWatermark = _sentinel,
    LiveStackingThumbnailSize? defaultThumbnailSize,
    bool? disableEverywhere,
  }) async {
    final values = <SettingValue<Object?>>[];

    if (defaultPort != null) {
      // The Rust LiveStackingPortClashRule fails sequences that ship
      // with broadcast_port == 0 or matching the headless API server's
      // port. Editor surfaces that validation; the settings store
      // simply persists the raw value so re-edits are not lossy.
      values.add(StoreSettings.liveStackingPort.to(defaultPort));
      state = state.copyWith(livestackingDefaultPort: defaultPort);
    }
    if (publicByDefault != null) {
      values.add(StoreSettings.liveStackingPublicByDefault.to(publicByDefault));
      state = state.copyWith(livestackingPublicByDefault: publicByDefault);
    }
    if (defaultStackMethod != null) {
      values.add(
        StoreSettings.liveStackingStackMethod.to(defaultStackMethod.storageKey),
      );
      state = state.copyWith(
        livestackingDefaultStackMethod: defaultStackMethod,
      );
    }
    if (defaultWatermark != _sentinel) {
      final value = defaultWatermark as String?;
      values.add(StoreSettings.liveStackingWatermark.to(value));
      state = state.copyWith(livestackingDefaultWatermark: value);
    }
    if (defaultThumbnailSize != null) {
      values.add(
        StoreSettings.liveStackingThumbnailSize.to(defaultThumbnailSize),
      );
      state = state.copyWith(
        livestackingDefaultThumbnailSize: defaultThumbnailSize,
      );
    }
    if (disableEverywhere != null) {
      values.add(
        StoreSettings.liveStackingDisableEverywhere.to(disableEverywhere),
      );
      state = state.copyWith(livestackingDisableEverywhere: disableEverywhere);
    }

    await _store(values);
  }

  Future<void> updateAutofocusDefaults({
    int? stepSize,
    int? stepsOut,
    double? exposureDuration,
    int? intervalFrames,
  }) async {
    final values = <SettingValue<Object?>>[];

    if (stepSize != null) {
      values.add(StoreSettings.sequencerAutofocusStepSize.to(stepSize));
      state = state.copyWith(autofocusStepSize: stepSize);
    }
    if (stepsOut != null) {
      values.add(StoreSettings.sequencerAutofocusStepsOut.to(stepsOut));
      state = state.copyWith(autofocusStepsOut: stepsOut);
    }
    if (exposureDuration != null) {
      values.add(StoreSettings.sequencerAutofocusExposure.to(exposureDuration));
      state = state.copyWith(autofocusExposureDuration: exposureDuration);
    }
    if (intervalFrames != null) {
      final interval = StoreSettings.sequencerAutofocusIntervalFrames.to(
        intervalFrames,
      );
      values.add(interval);
      state = state.copyWith(autofocusIntervalFrames: interval.value);
    }

    await _store(values);
  }

  Future<void> updateDitherDefaults({
    double? pixels,
    double? settleTime,
    double? settlePixels,
    double? settleTimeout,
    bool? raOnly,
  }) async {
    final values = <SettingValue<Object?>>[];

    if (pixels != null) {
      values.add(StoreSettings.sequencerDitherPixels.to(pixels));
      state = state.copyWith(ditherPixels: pixels);
    }
    if (settleTime != null) {
      values.add(StoreSettings.sequencerDitherSettleTime.to(settleTime));
      state = state.copyWith(ditherSettleTime: settleTime);
    }
    if (settlePixels != null) {
      values.add(StoreSettings.sequencerDitherSettlePixels.to(settlePixels));
      state = state.copyWith(ditherSettlePixels: settlePixels);
    }
    if (settleTimeout != null) {
      values.add(StoreSettings.sequencerDitherSettleTimeout.to(settleTimeout));
      state = state.copyWith(ditherSettleTimeout: settleTimeout);
    }
    if (raOnly != null) {
      values.add(StoreSettings.sequencerDitherRaOnly.to(raOnly));
      state = state.copyWith(ditherRaOnly: raOnly);
    }

    await _store(values);
  }

  Future<void> updateExposureDefaults({
    double? duration,
    int? count,
    String? filter,
    int? gain,
    int? offset,
    BinningMode? binning,
    int? ditherEvery,
  }) async {
    final values = <SettingValue<Object?>>[];

    if (duration != null) {
      values.add(StoreSettings.sequencerExposureDuration.to(duration));
      state = state.copyWith(
        exposureDuration: duration,
        isExposureDurationConfigured: true,
      );
    }
    if (count != null) {
      values.add(StoreSettings.sequencerExposureCount.to(count));
      state = state.copyWith(exposureCount: count);
    }
    if (filter != null) {
      values.add(StoreSettings.sequencerExposureFilter.to(filter));
      state = state.copyWith(exposureFilter: filter);
    }
    if (gain != null) {
      values.add(StoreSettings.sequencerExposureGain.to(gain));
      state = state.copyWith(exposureGain: gain);
    }
    if (offset != null) {
      values.add(StoreSettings.sequencerExposureOffset.to(offset));
      state = state.copyWith(exposureOffset: offset);
    }
    if (binning != null) {
      values.add(StoreSettings.sequencerExposureBinning.to(binning));
      state = state.copyWith(exposureBinning: binning);
    }
    if (ditherEvery != null) {
      values.add(StoreSettings.sequencerExposureDitherEvery.to(ditherEvery));
      state = state.copyWith(exposureDitherEvery: ditherEvery);
    }

    await _store(values);
  }
}
