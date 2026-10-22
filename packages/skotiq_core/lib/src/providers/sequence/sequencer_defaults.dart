import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/sequence/sequence_models.dart'
    show BinningMode, LiveStackingMethod, SequenceOverheadConfig;
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
  // Autofocus defaults
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

  // Dither defaults
  final double ditherPixels;
  final double ditherSettleTime;
  final double ditherSettlePixels;
  final double ditherSettleTimeout;
  final bool ditherRaOnly;

  // Exposure defaults
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
    this.autofocusStepSize = 100,
    this.autofocusStepsOut = 7,
    this.autofocusExposureDuration = 3.0,
    this.autofocusIntervalFrames = 25,
    this.ditherPixels = 5.0,
    this.ditherSettleTime = 30.0,
    this.ditherSettlePixels = 1.5,
    this.ditherSettleTimeout = 120.0,
    this.ditherRaOnly = false,
    this.exposureDuration = 60.0,
    this.isExposureDurationConfigured = false,
    this.exposureCount = 10,
    this.exposureFilter,
    this.exposureGain,
    this.exposureOffset,
    this.exposureBinning = BinningMode.one,
    this.exposureDitherEvery = 3,
    this.frameDownloadOverheadSecs = 2.0,
    this.livestackingDefaultPort = 8081,
    this.livestackingPublicByDefault = false,
    this.livestackingDefaultStackMethod = LiveStackingMethod.average,
    this.livestackingDefaultWatermark,
    this.livestackingDefaultThumbnailSize = LiveStackingThumbnailSize.medium,
    this.livestackingDisableEverywhere = false,
  });

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

/// Friendly thumbnail-size preset for the Settings UI.
///
/// Maps to width × height pairs the broadcast service consumes. The
/// LiveStacking properties editor still exposes width / height directly
/// for power users; this preset only governs the default applied when a
/// fresh node is dropped into the editor.
enum LiveStackingThumbnailSize {
  small,
  medium,
  large;

  /// Width in pixels.
  int get width => switch (this) {
    LiveStackingThumbnailSize.small => 640,
    LiveStackingThumbnailSize.medium => 1280,
    LiveStackingThumbnailSize.large => 1920,
  };

  /// Height in pixels (16:9 aspect ratio).
  int get height => switch (this) {
    LiveStackingThumbnailSize.small => 360,
    LiveStackingThumbnailSize.medium => 720,
    LiveStackingThumbnailSize.large => 1080,
  };

  String get label => switch (this) {
    LiveStackingThumbnailSize.small => 'Small (640×360)',
    LiveStackingThumbnailSize.medium => 'Medium (1280×720)',
    LiveStackingThumbnailSize.large => 'Large (1920×1080)',
  };

  String get storageKey => switch (this) {
    LiveStackingThumbnailSize.small => 'small',
    LiveStackingThumbnailSize.medium => 'medium',
    LiveStackingThumbnailSize.large => 'large',
  };

  static LiveStackingThumbnailSize fromStorageKey(String? key) => switch (key) {
    'small' => LiveStackingThumbnailSize.small,
    'large' => LiveStackingThumbnailSize.large,
    _ => LiveStackingThumbnailSize.medium,
  };
}

class SequencerDefaultsNotifier extends StateNotifier<SequencerDefaults> {
  final Ref _ref;

  SequencerDefaultsNotifier(this._ref) : super(const SequencerDefaults()) {
    _loadFuture = _loadDefaults();
  }

  late final Future<void> _loadFuture;

  /// Wait until the saved defaults have been read from the database.
  ///
  /// Until then [state] holds the library defaults. A start that is this
  /// provider's first reader -- every headless night -- otherwise pushed those
  /// to the executor instead of the operator's saved dither and autofocus
  /// cadence (dither settle 30 s instead of 3 s, refocus every 25 frames
  /// instead of 60, measured by the simulator soak).
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _loadDefaults() async {
    final settingsDao = _ref.read(settingsDaoProvider);

    final stepSize =
        int.tryParse(
          await settingsDao.getSetting('sequencer_autofocus_step_size') ??
              '100',
        ) ??
        100;
    final stepsOut =
        int.tryParse(
          await settingsDao.getSetting('sequencer_autofocus_steps_out') ?? '7',
        ) ??
        7;
    final exposureDuration =
        double.tryParse(
          await settingsDao.getSetting(
                'sequencer_autofocus_exposure_duration',
              ) ??
              '3.0',
        ) ??
        3.0;
    // Persisted autofocus-interval cadence.
    final autofocusIntervalFrames =
        int.tryParse(
          await settingsDao.getSetting('sequencer_autofocus_interval_frames') ??
              '25',
        ) ??
        25;

    final ditherPixels =
        double.tryParse(
          await settingsDao.getSetting('sequencer_dither_pixels') ?? '5.0',
        ) ??
        5.0;
    final ditherSettleTime =
        double.tryParse(
          await settingsDao.getSetting('sequencer_dither_settle_time') ??
              '30.0',
        ) ??
        30.0;
    final ditherSettlePixels =
        double.tryParse(
          await settingsDao.getSetting('sequencer_dither_settle_pixels') ??
              '1.5',
        ) ??
        1.5;
    final ditherSettleTimeout =
        double.tryParse(
          await settingsDao.getSetting('sequencer_dither_settle_timeout') ??
              '120.0',
        ) ??
        120.0;
    final ditherRaOnly =
        (await settingsDao.getSetting('sequencer_dither_ra_only') ?? 'false') ==
        'true';

    final exposureDurationRaw = await settingsDao.getSetting(
      'sequencer_exposure_duration',
    );
    final parsedExposureDuration = exposureDurationRaw == null
        ? null
        : double.tryParse(exposureDurationRaw);
    final exposureDurationDefault =
        parsedExposureDuration != null && parsedExposureDuration > 0
        ? parsedExposureDuration
        : 60.0;
    final exposureCount =
        int.tryParse(
          await settingsDao.getSetting('sequencer_exposure_count') ?? '10',
        ) ??
        10;
    final exposureFilter = await settingsDao.getSetting(
      'sequencer_exposure_filter',
    );
    final exposureGainStr = await settingsDao.getSetting(
      'sequencer_exposure_gain',
    );
    final exposureGain = exposureGainStr != null
        ? int.tryParse(exposureGainStr)
        : null;
    final exposureOffsetStr = await settingsDao.getSetting(
      'sequencer_exposure_offset',
    );
    final exposureOffset = exposureOffsetStr != null
        ? int.tryParse(exposureOffsetStr)
        : null;
    final exposureBinningStr =
        await settingsDao.getSetting('sequencer_exposure_binning') ?? 'one';
    final exposureBinning = BinningMode.values.firstWhere(
      (e) => e.name == exposureBinningStr,
      orElse: () => BinningMode.one,
    );
    final exposureDitherEvery =
        int.tryParse(
          await settingsDao.getSetting('sequencer_exposure_dither_every') ??
              '3',
        ) ??
        3;

    // LiveStacking defaults.
    final livestackingPort =
        int.tryParse(
          await settingsDao.getSetting('livestacking_default_port') ?? '8081',
        ) ??
        8081;
    final livestackingPublic =
        (await settingsDao.getSetting('livestacking_public_by_default')) ==
        'true';
    final livestackingStackMethodKey =
        await settingsDao.getSetting('livestacking_default_stack_method') ??
        'average';
    final livestackingStackMethod = LiveStackingMethod.fromStorageKey(
      livestackingStackMethodKey,
    );
    final livestackingWatermark = await settingsDao.getSetting(
      'livestacking_default_watermark',
    );
    final livestackingThumbnailKey = await settingsDao.getSetting(
      'livestacking_default_thumbnail_size',
    );
    final livestackingThumbnail = LiveStackingThumbnailSize.fromStorageKey(
      livestackingThumbnailKey,
    );
    final livestackingDisableAll =
        (await settingsDao.getSetting('livestacking_disable_everywhere')) ==
        'true';

    // Twenty-odd awaited DAO reads happened above; the provider that started
    // them can be gone by now — a container torn down while the first read of
    // this notifier is still in flight, which is what a run start does when it
    // instantiates the defaults on its way to seeding the executor. Writing
    // `state` on a disposed StateNotifier raises a Bad state that belongs to
    // nobody: the launch has already returned, so it surfaces as an unhandled
    // async error against whatever runs next. Nothing is being hidden — with
    // the container gone there is no reader left for the value.
    if (!mounted) return;
    state = SequencerDefaults(
      autofocusStepSize: stepSize,
      autofocusStepsOut: stepsOut,
      autofocusExposureDuration: exposureDuration,
      autofocusIntervalFrames: autofocusIntervalFrames,
      ditherPixels: ditherPixels,
      ditherSettleTime: ditherSettleTime,
      ditherSettlePixels: ditherSettlePixels,
      ditherSettleTimeout: ditherSettleTimeout,
      ditherRaOnly: ditherRaOnly,
      exposureDuration: exposureDurationDefault,
      isExposureDurationConfigured:
          parsedExposureDuration != null && parsedExposureDuration > 0,
      exposureCount: exposureCount,
      exposureFilter: exposureFilter,
      exposureGain: exposureGain,
      exposureOffset: exposureOffset,
      exposureBinning: exposureBinning,
      exposureDitherEvery: exposureDitherEvery,
      livestackingDefaultPort: livestackingPort,
      livestackingPublicByDefault: livestackingPublic,
      livestackingDefaultStackMethod: livestackingStackMethod,
      livestackingDefaultWatermark:
          (livestackingWatermark != null && livestackingWatermark.isEmpty)
          ? null
          : livestackingWatermark,
      livestackingDefaultThumbnailSize: livestackingThumbnail,
      livestackingDisableEverywhere: livestackingDisableAll,
    );
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
    final settingsDao = _ref.read(settingsDaoProvider);
    final updates = <String, String>{};

    if (defaultPort != null) {
      // The Rust LiveStackingPortClashRule fails sequences that ship
      // with broadcast_port == 0 or matching the headless API server's
      // port. Editor surfaces that validation; the settings store
      // simply persists the raw value so re-edits are not lossy.
      updates['livestacking_default_port'] = defaultPort.toString();
      state = state.copyWith(livestackingDefaultPort: defaultPort);
    }
    if (publicByDefault != null) {
      updates['livestacking_public_by_default'] = publicByDefault.toString();
      state = state.copyWith(livestackingPublicByDefault: publicByDefault);
    }
    if (defaultStackMethod != null) {
      updates['livestacking_default_stack_method'] =
          defaultStackMethod.storageKey;
      state = state.copyWith(
        livestackingDefaultStackMethod: defaultStackMethod,
      );
    }
    if (defaultWatermark != _sentinel) {
      final value = defaultWatermark as String?;
      // Persist empty string when explicitly cleared so the load path
      // can distinguish "user cleared the watermark" from "field never
      // set" (latter falls back to the in-memory default of null).
      updates['livestacking_default_watermark'] = value ?? '';
      state = state.copyWith(livestackingDefaultWatermark: value);
    }
    if (defaultThumbnailSize != null) {
      updates['livestacking_default_thumbnail_size'] =
          defaultThumbnailSize.storageKey;
      state = state.copyWith(
        livestackingDefaultThumbnailSize: defaultThumbnailSize,
      );
    }
    if (disableEverywhere != null) {
      updates['livestacking_disable_everywhere'] = disableEverywhere.toString();
      state = state.copyWith(livestackingDisableEverywhere: disableEverywhere);
    }

    if (updates.isNotEmpty) {
      await settingsDao.setSettings(updates);
    }
  }

  Future<void> updateAutofocusDefaults({
    int? stepSize,
    int? stepsOut,
    double? exposureDuration,
    int? intervalFrames,
  }) async {
    final settingsDao = _ref.read(settingsDaoProvider);
    final updates = <String, String>{};

    if (stepSize != null) {
      updates['sequencer_autofocus_step_size'] = stepSize.toString();
      state = state.copyWith(autofocusStepSize: stepSize);
    }
    if (stepsOut != null) {
      updates['sequencer_autofocus_steps_out'] = stepsOut.toString();
      state = state.copyWith(autofocusStepsOut: stepsOut);
    }
    if (exposureDuration != null) {
      updates['sequencer_autofocus_exposure_duration'] = exposureDuration
          .toString();
      state = state.copyWith(autofocusExposureDuration: exposureDuration);
    }
    if (intervalFrames != null) {
      // Persist and push to the live executor so the
      // autofocus-interval trigger cadence updates without a sequence reload.
      // Validation: Rust rejects 0; clamp here as well so the UI doesn't
      // round-trip a value that the backend will refuse.
      final clamped = intervalFrames < 1 ? 1 : intervalFrames;
      updates['sequencer_autofocus_interval_frames'] = clamped.toString();
      state = state.copyWith(autofocusIntervalFrames: clamped);
    }

    if (updates.isNotEmpty) {
      await settingsDao.setSettings(updates);
    }
  }

  Future<void> updateDitherDefaults({
    double? pixels,
    double? settleTime,
    double? settlePixels,
    double? settleTimeout,
    bool? raOnly,
  }) async {
    final settingsDao = _ref.read(settingsDaoProvider);
    final updates = <String, String>{};

    if (pixels != null) {
      updates['sequencer_dither_pixels'] = pixels.toString();
      state = state.copyWith(ditherPixels: pixels);
    }
    if (settleTime != null) {
      updates['sequencer_dither_settle_time'] = settleTime.toString();
      state = state.copyWith(ditherSettleTime: settleTime);
    }
    if (settlePixels != null) {
      updates['sequencer_dither_settle_pixels'] = settlePixels.toString();
      state = state.copyWith(ditherSettlePixels: settlePixels);
    }
    if (settleTimeout != null) {
      updates['sequencer_dither_settle_timeout'] = settleTimeout.toString();
      state = state.copyWith(ditherSettleTimeout: settleTimeout);
    }
    if (raOnly != null) {
      updates['sequencer_dither_ra_only'] = raOnly.toString();
      state = state.copyWith(ditherRaOnly: raOnly);
    }

    if (updates.isNotEmpty) {
      await settingsDao.setSettings(updates);
    }
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
    final settingsDao = _ref.read(settingsDaoProvider);
    final updates = <String, String>{};

    if (duration != null) {
      updates['sequencer_exposure_duration'] = duration.toString();
      state = state.copyWith(
        exposureDuration: duration,
        isExposureDurationConfigured: true,
      );
    }
    if (count != null) {
      updates['sequencer_exposure_count'] = count.toString();
      state = state.copyWith(exposureCount: count);
    }
    if (filter != null) {
      updates['sequencer_exposure_filter'] = filter;
      state = state.copyWith(exposureFilter: filter);
    }
    if (gain != null) {
      updates['sequencer_exposure_gain'] = gain.toString();
      state = state.copyWith(exposureGain: gain);
    }
    if (offset != null) {
      updates['sequencer_exposure_offset'] = offset.toString();
      state = state.copyWith(exposureOffset: offset);
    }
    if (binning != null) {
      updates['sequencer_exposure_binning'] = binning.name;
      state = state.copyWith(exposureBinning: binning);
    }
    if (ditherEvery != null) {
      updates['sequencer_exposure_dither_every'] = ditherEvery.toString();
      state = state.copyWith(exposureDitherEvery: ditherEvery);
    }

    if (updates.isNotEmpty) {
      await settingsDao.setSettings(updates);
    }
  }
}
