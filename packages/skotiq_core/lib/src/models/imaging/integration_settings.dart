import 'dart:convert';

part 'integration_settings/integration_enums.dart';

/// Immutable, fully-specified settings for one post-session batch integration
/// run — every advanced knob the native `api_integrate_session` pipeline
/// exposes, with smart defaults.
///
/// The model is the single source of truth the [PostSessionIntegrationService]
/// serialises into the native JSON `settings` block. It is intentionally a flat
/// value type (not freezed-generated, to avoid a codegen dependency in
/// `skotiq_core`) with value equality, `copyWith`, JSON round-trip, and
/// named presets.
///
/// JSON layout (`toBridgeSettings`) matches the native
/// `IntegrationSettingsArgs`:
/// `{ align:{...}, weighting:{...}, normalization:{...}, integration:{...} }`.
class IntegrationSettings {
  // Alignment
  /// Geometric transform model. Default: [TransformModel.affine].
  final TransformModel model;

  /// Resampling kernel. Default: [Resampler.lanczos3].
  final Resampler resampler;

  /// RANSAC inlier threshold in reference pixels. Default 2.0.
  final double ransacThresholdPx;

  /// Brightest-N reference stars used for matching. Default 60.
  final int maxRefStars;

  // Weighting
  /// Whether per-sub weighting is applied. Default true.
  final bool weightingEnabled;

  /// Weighting formula. Default [WeightFormula.snrSquared].
  final WeightFormula weighting;

  /// Custom SNR exponent (used only when [weighting] == custom). Default 2.0.
  final double snrPow;

  /// Custom FWHM exponent (used only when [weighting] == custom). Default 1.0.
  final double fwhmPow;

  /// Custom eccentricity exponent (custom only). Default 1.0.
  final double eccPow;

  // Normalization
  /// Whether normalization to the reference is applied. Default true.
  final bool normalizationEnabled;

  /// Normalization mode. Default [NormalizationMode.global].
  final NormalizationMode normalization;

  /// Local-grid rows (mode == local only). Default 8.
  final int localRows;

  /// Local-grid cols (mode == local only). Default 8.
  final int localCols;

  // Integration
  /// Pixel combine operator. Default [CombineMode.mean].
  final CombineMode combine;

  /// Rejection algorithm. Default [RejectAlgorithm.auto].
  final RejectAlgorithm reject;

  /// Low rejection threshold (σ for sigma family, fraction for percentile).
  /// Default 3.0.
  final double rejectLow;

  /// High rejection threshold. Default 3.0.
  final double rejectHigh;

  /// MinMax low count (reject == minMax only). Default 1.
  final int minMaxLow;

  /// MinMax high count (reject == minMax only). Default 1.
  final int minMaxHigh;

  /// Emit the per-pixel rejection-count map alongside the master. Default true.
  final bool generateRejectionMap;

  /// Apply self-derived cosmetic (hot/cold transient) correction per light
  /// before registration. Default true.
  final bool cosmeticCorrection;

  /// Output sample format. Default [OutputBitDepth.f32].
  final OutputBitDepth outputBitDepth;

  // Cull recommendation (advisory; consumed by the UI, not the native side)
  /// Whether to recommend an auto-cull of the worst subs. Default true.
  final bool autoCull;

  /// Cull percentile (drop subs below this weight percentile, 0..1). Default
  /// 0.10 (worst 10%).
  final double cullPercentile;

  /// The preset this configuration was materialised from, or null if it was
  /// hand-edited away from any preset. Persisted for UI round-trip only.
  final IntegrationPreset? sourcePreset;

  // Drizzle (variable-pixel reconstruction; off by default — heavy)
  /// Whether to drizzle-integrate instead of plain resample-and-combine.
  /// Default false. Routes through native `api_drizzle_integrate`.
  final bool drizzle;

  /// Linear output/input scale factor for drizzle. Default 2.0.
  final double drizzleScale;

  /// Drop-shrink fraction in (0, 1]. Default 0.9.
  final double drizzlePixfrac;

  /// Drizzle drop-deposition kernel. Default [DrizzleKernel.square].
  final DrizzleKernel drizzleKernel;

  /// Bayer-CFA drizzle (drizzle the raw mosaic into RGB, no debayer interp).
  /// Default false.
  final bool bayerDrizzle;

  // Deconvolution (preview finishing pass; off by default — heavy)
  /// Whether to run a Richardson–Lucy deconvolution finishing pass. Default
  /// false. Routes through native `api_deconvolve_preview`.
  final bool deconvolve;

  /// Richardson–Lucy iteration count. Default 30.
  final int deconIterations;

  /// Total-variation regularization strength λ. Default 0.01 (small).
  final double deconRegularization;

  /// PSF family used by the deconvolution. Default [PsfKind.empirical] (the
  /// PSF is estimated from the frame's own stars).
  final PsfKind psfKind;

  // Star reduction (preview finishing pass; off by default)
  /// Whether to run a star-size-reduction finishing pass. Default false.
  /// Routes through native `api_reduce_stars_preview`.
  final bool reduceStars;

  /// Star-reduction strength in [0, 1]. Default 0.5 (0 is identity).
  final double starReductionStrength;

  /// Star-reduction algorithm. Default [StarReduceMethod.screenedResidual].
  final StarReduceMethod starReduceMethod;

  // Background extraction (gradient removal; on by smart default)
  /// Whether to fit + subtract a star-masked low-order polynomial background.
  /// Default false on the bare model; [smartDefaults] turns it ON. Routes
  /// through native `api_extract_background`.
  final bool extractBackground;

  /// Fitted background polynomial degree (0..6). Default 4.
  final int backgroundPolyDegree;

  /// Add the model's mean back on subtraction (remove gradient only, keep the
  /// pedestal). Default true.
  final bool backgroundPreserveMean;

  // Colour calibration (photometric white balance; off by default)
  /// Whether to solve + apply a catalogue-referenced per-channel white balance.
  /// Default false.
  ///
  /// Unlike the other finishing knobs this does **not** ride inside the
  /// `api_integrate_session` settings block (the native integrate path ignores
  /// it). It is consumed Dart-side by `ColorCalibrationService`, which detects +
  /// photometers stars on the finished master, cross-matches catalogue B–V using
  /// the master's solved WCS, then calls native `api_color_calibrate` to solve
  /// and apply the per-channel balance. It is therefore a no-op until the master
  /// has a plate-solved WCS.
  final bool colorCalibrate;

  /// White-reference B–V colour index the SPCC fit balances to. Default 0.65
  /// (a G2V / sun-like reference).
  final double whiteRefBv;

  // Narrowband palette (channel combine; off by default)
  /// Narrowband palette mix. Default [NarrowbandPalette.none]. When `custom`,
  /// [customWeights] supplies the per-input `[r, g, b]` triples. Routes through
  /// native `api_combine_channels`.
  final NarrowbandPalette narrowbandPalette;

  /// Optional per-input `[r, g, b]` weight triples used only when
  /// [narrowbandPalette] == [NarrowbandPalette.custom]. Placeholder for the
  /// custom-mix UI; null when unused.
  final List<List<double>>? customWeights;

  const IntegrationSettings({
    this.model = TransformModel.affine,
    this.resampler = Resampler.lanczos3,
    this.ransacThresholdPx = 2.0,
    this.maxRefStars = 60,
    this.weightingEnabled = true,
    this.weighting = WeightFormula.snrSquared,
    this.snrPow = 2.0,
    this.fwhmPow = 1.0,
    this.eccPow = 1.0,
    this.normalizationEnabled = true,
    this.normalization = NormalizationMode.global,
    this.localRows = 8,
    this.localCols = 8,
    this.combine = CombineMode.mean,
    this.reject = RejectAlgorithm.auto,
    this.rejectLow = 3.0,
    this.rejectHigh = 3.0,
    this.minMaxLow = 1,
    this.minMaxHigh = 1,
    this.generateRejectionMap = true,
    this.cosmeticCorrection = true,
    this.outputBitDepth = OutputBitDepth.f32,
    this.autoCull = true,
    this.cullPercentile = 0.10,
    this.sourcePreset,
    this.drizzle = false,
    this.drizzleScale = 2.0,
    this.drizzlePixfrac = 0.9,
    this.drizzleKernel = DrizzleKernel.square,
    this.bayerDrizzle = false,
    this.deconvolve = false,
    this.deconIterations = 30,
    this.deconRegularization = 0.01,
    this.psfKind = PsfKind.empirical,
    this.reduceStars = false,
    this.starReductionStrength = 0.5,
    this.starReduceMethod = StarReduceMethod.screenedResidual,
    this.extractBackground = false,
    this.backgroundPolyDegree = 4,
    this.backgroundPreserveMean = true,
    this.colorCalibrate = false,
    this.whiteRefBv = 0.65,
    this.narrowbandPalette = NarrowbandPalette.none,
    this.customWeights,
  });

  /// The app-wide default (== [IntegrationPreset.balanced]).
  static const IntegrationSettings defaults = IntegrationSettings(
    sourcePreset: IntegrationPreset.balanced,
  );

  /// Materialise a named [preset].
  factory IntegrationSettings.preset(IntegrationPreset preset) {
    switch (preset) {
      case IntegrationPreset.fast:
        return const IntegrationSettings(
          resampler: Resampler.bilinear,
          weighting: WeightFormula.snr,
          generateRejectionMap: false,
          cosmeticCorrection: false,
          sourcePreset: IntegrationPreset.fast,
        );
      case IntegrationPreset.balanced:
        return const IntegrationSettings(
          sourcePreset: IntegrationPreset.balanced,
        );
      case IntegrationPreset.maximumQuality:
        // Maximum Quality must remain behaviorally distinct from Balanced:
        //  * ransacThresholdPx 1.0 (vs 2.0) — the transform is fit only to
        //    close star pairs, trading robustness for precision.
        //  * maxRefStars 120 (vs 60) — better-conditioned matching at extra cost.
        //  * normalization local (vs global) — per-cell background matching.
        return const IntegrationSettings(
          ransacThresholdPx: 1.0,
          maxRefStars: 120,
          normalization: NormalizationMode.local,
          sourcePreset: IntegrationPreset.maximumQuality,
        );
      case IntegrationPreset.fewSubs:
        return const IntegrationSettings(
          reject: RejectAlgorithm.percentile,
          // Percentile thresholds are fractions in (0, 1), not σ.
          rejectLow: 0.2,
          rejectHigh: 0.1,
          sourcePreset: IntegrationPreset.fewSubs,
        );
      case IntegrationPreset.longNightGradient:
        return const IntegrationSettings(
          normalization: NormalizationMode.local,
          sourcePreset: IntegrationPreset.longNightGradient,
        );
    }
  }

  /// Build settings with the *smart* knobs auto-chosen from the sub population.
  ///
  /// This is the "smart" entry point: it starts from [IntegrationPreset.balanced]
  /// and adapts the few knobs that genuinely depend on the data:
  ///
  /// - **Rejection** is left as [RejectAlgorithm.auto] (the native side then
  ///   resolves it by [subCount]); the resolved algorithm is surfaced via
  ///   [resolvedReject].
  /// - **Percentile thresholds** are substituted when `subCount < 8` so the
  ///   in-(0,1) fractions are used instead of σ.
  /// - **Normalization** switches to [NormalizationMode.local] when
  ///   [longNight] is set (gradient drift through the night).
  /// - **Resampler** drops to bilinear only when [preferSpeed] is set (e.g. a
  ///   very large sub count where the user opted for the Fast preset).
  ///
  /// Destructive post-stacking steps (background extraction, colour
  /// calibration, deconvolution, star reduction, drizzle, narrowband combine)
  /// stay OFF here, so the output is an unmodified linear master FITS plus a
  /// stretched preview. They are explicit opt-ins and write *sibling* files,
  /// leaving the linear master intact. ([dithered]/[underSampled] are accepted
  /// for API compatibility and not yet read.)
  factory IntegrationSettings.smartDefaults({
    required int subCount,
    bool longNight = false,
    bool preferSpeed = false,
    bool dithered = false,
    bool underSampled = false,
  }) {
    final base = preferSpeed
        ? IntegrationSettings.preset(IntegrationPreset.fast)
        : IntegrationSettings.preset(IntegrationPreset.balanced);

    final wantsPercentile = subCount < 8;
    return base.copyWith(
      reject: RejectAlgorithm.auto,
      rejectLow: wantsPercentile ? 0.2 : base.rejectLow,
      rejectHigh: wantsPercentile ? 0.1 : base.rejectHigh,
      normalization: longNight ? NormalizationMode.local : base.normalization,
      // Pristine-master-by-default: NO destructive post-stacking processing is
      // enabled here (background extraction, colour calibration, deconvolution,
      // star reduction, drizzle, narrowband all stay OFF). They are opt-in and
      // write sibling files, so the persisted master is always the unmodified
      // linear integration the user imports to start from scratch.
      clearSourcePreset: true,
    );
  }

  /// The concrete rejection algorithm this configuration will use for a stack of
  /// [subCount] subs (resolving [RejectAlgorithm.auto] via the native rule).
  RejectAlgorithm resolvedReject(int subCount) {
    if (reject == RejectAlgorithm.auto) {
      return RejectAlgorithm.resolveAuto(subCount);
    }
    return reject;
  }

  IntegrationSettings copyWith({
    TransformModel? model,
    Resampler? resampler,
    double? ransacThresholdPx,
    int? maxRefStars,
    bool? weightingEnabled,
    WeightFormula? weighting,
    double? snrPow,
    double? fwhmPow,
    double? eccPow,
    bool? normalizationEnabled,
    NormalizationMode? normalization,
    int? localRows,
    int? localCols,
    CombineMode? combine,
    RejectAlgorithm? reject,
    double? rejectLow,
    double? rejectHigh,
    int? minMaxLow,
    int? minMaxHigh,
    bool? generateRejectionMap,
    bool? cosmeticCorrection,
    OutputBitDepth? outputBitDepth,
    bool? autoCull,
    double? cullPercentile,
    IntegrationPreset? sourcePreset,
    bool clearSourcePreset = false,
    bool? drizzle,
    double? drizzleScale,
    double? drizzlePixfrac,
    DrizzleKernel? drizzleKernel,
    bool? bayerDrizzle,
    bool? deconvolve,
    int? deconIterations,
    double? deconRegularization,
    PsfKind? psfKind,
    bool? reduceStars,
    double? starReductionStrength,
    StarReduceMethod? starReduceMethod,
    bool? extractBackground,
    int? backgroundPolyDegree,
    bool? backgroundPreserveMean,
    bool? colorCalibrate,
    double? whiteRefBv,
    NarrowbandPalette? narrowbandPalette,
    List<List<double>>? customWeights,
    bool clearCustomWeights = false,
  }) {
    return IntegrationSettings(
      model: model ?? this.model,
      resampler: resampler ?? this.resampler,
      ransacThresholdPx: ransacThresholdPx ?? this.ransacThresholdPx,
      maxRefStars: maxRefStars ?? this.maxRefStars,
      weightingEnabled: weightingEnabled ?? this.weightingEnabled,
      weighting: weighting ?? this.weighting,
      snrPow: snrPow ?? this.snrPow,
      fwhmPow: fwhmPow ?? this.fwhmPow,
      eccPow: eccPow ?? this.eccPow,
      normalizationEnabled: normalizationEnabled ?? this.normalizationEnabled,
      normalization: normalization ?? this.normalization,
      localRows: localRows ?? this.localRows,
      localCols: localCols ?? this.localCols,
      combine: combine ?? this.combine,
      reject: reject ?? this.reject,
      rejectLow: rejectLow ?? this.rejectLow,
      rejectHigh: rejectHigh ?? this.rejectHigh,
      minMaxLow: minMaxLow ?? this.minMaxLow,
      minMaxHigh: minMaxHigh ?? this.minMaxHigh,
      generateRejectionMap: generateRejectionMap ?? this.generateRejectionMap,
      cosmeticCorrection: cosmeticCorrection ?? this.cosmeticCorrection,
      outputBitDepth: outputBitDepth ?? this.outputBitDepth,
      autoCull: autoCull ?? this.autoCull,
      cullPercentile: cullPercentile ?? this.cullPercentile,
      sourcePreset: clearSourcePreset
          ? null
          : (sourcePreset ?? this.sourcePreset),
      drizzle: drizzle ?? this.drizzle,
      drizzleScale: drizzleScale ?? this.drizzleScale,
      drizzlePixfrac: drizzlePixfrac ?? this.drizzlePixfrac,
      drizzleKernel: drizzleKernel ?? this.drizzleKernel,
      bayerDrizzle: bayerDrizzle ?? this.bayerDrizzle,
      deconvolve: deconvolve ?? this.deconvolve,
      deconIterations: deconIterations ?? this.deconIterations,
      deconRegularization: deconRegularization ?? this.deconRegularization,
      psfKind: psfKind ?? this.psfKind,
      reduceStars: reduceStars ?? this.reduceStars,
      starReductionStrength:
          starReductionStrength ?? this.starReductionStrength,
      starReduceMethod: starReduceMethod ?? this.starReduceMethod,
      extractBackground: extractBackground ?? this.extractBackground,
      backgroundPolyDegree: backgroundPolyDegree ?? this.backgroundPolyDegree,
      backgroundPreserveMean:
          backgroundPreserveMean ?? this.backgroundPreserveMean,
      colorCalibrate: colorCalibrate ?? this.colorCalibrate,
      whiteRefBv: whiteRefBv ?? this.whiteRefBv,
      narrowbandPalette: narrowbandPalette ?? this.narrowbandPalette,
      customWeights: clearCustomWeights
          ? null
          : (customWeights ?? this.customWeights),
    );
  }

  /// The native `settings` block for `api_integrate_session` /
  /// `api_master_accumulate` (the `IntegrationSettingsArgs` shape). Keys are
  /// camelCase to match the native `#[serde(rename_all = "camelCase")]`.
  ///
  /// `cosmeticCorrection` is intentionally NOT in this map — it lives on the
  /// native `calibration` block, and [PostSessionIntegrationService] places it
  /// there.
  Map<String, dynamic> toBridgeSettings() {
    return {
      'align': {
        'model': model.wire,
        'resampler': resampler.wire,
        'ransacThresholdPx': ransacThresholdPx,
        'maxRefStars': maxRefStars,
      },
      'weighting': {
        'enabled': weightingEnabled,
        'formula': weighting.wire,
        'snrPow': snrPow,
        'fwhmPow': fwhmPow,
        'eccPow': eccPow,
      },
      'normalization': {
        'enabled': normalizationEnabled,
        'mode': normalization.wire,
        'localRows': localRows,
        'localCols': localCols,
      },
      'integration': {
        'combine': combine.wire,
        'reject': reject.wire,
        'rejectLow': rejectLow,
        'rejectHigh': rejectHigh,
        'minMaxLow': minMaxLow,
        'minMaxHigh': minMaxHigh,
        'generateRejectionMap': generateRejectionMap,
        'outputBitDepth': outputBitDepth.wire,
      },
      // Post-integration finishing knobs. Each sub-block carries the
      // enabled flag plus the native config field names (camelCase, matching
      // the `#[serde(rename_all = "camelCase")]` *Args DTOs in
      // bridge/src/api/finishing_*.rs). They ride inside the integration JSON
      // so a new knob never needs an FFI regen.
      'finishing': {
        // Drizzle config mirrors DrizzleConfigArgs (+ top-level `bayer`).
        'drizzle': {
          'enabled': drizzle,
          'scale': drizzleScale,
          'pixfrac': drizzlePixfrac,
          'kernel': drizzleKernel.wire,
          'bayer': bayerDrizzle,
        },
        // Deconvolution mirrors the native DeconvolvePreviewArgs shape
        // (finishing_enhance.rs): a top-level `estimatePsf` bool, a nested
        // `psf` (PsfArgs.kind) used only when estimatePsf is false, and a
        // nested `config` (DeconvConfigArgs.iterations/regularization). The
        // empirical PSF can only be produced by the estimate-from-stars path,
        // so psfKind == empirical maps to estimatePsf: true; the analytic
        // kinds (gaussian/moffat) map to estimatePsf: false and route the kind
        // through psf.kind.
        'deconvolution': {
          'enabled': deconvolve,
          'estimatePsf': psfKind == PsfKind.empirical,
          'psf': {'kind': psfKind.wire},
          'config': {
            'iterations': deconIterations,
            'regularization': deconRegularization,
          },
        },
        // Star reduction mirrors ReduceStarsConfigArgs.
        'starReduction': {
          'enabled': reduceStars,
          'strength': starReductionStrength,
          'method': starReduceMethod.wire,
        },
        // Background extraction mirrors BackgroundConfigArgs.
        'backgroundExtraction': {
          'enabled': extractBackground,
          'polyDegree': backgroundPolyDegree,
          'preserveMean': backgroundPreserveMean,
        },
        // Colour calibration (the catalogue match is Dart-side; whiteRefBv is
        // the photometric white reference the native solve balances to).
        'colorCalibration': {
          'enabled': colorCalibrate,
          'whiteRefBv': whiteRefBv,
        },
        // Narrowband mirrors the native CombineChannelsArgs two-mode contract
        // (finishing_combine.rs): `palette` is an Option<String> that the
        // native parser accepts ONLY as "sho" or "hoo"; the custom path
        // requires `palette` ABSENT with a non-empty `weights` table. So the
        // 'palette' key is emitted only for the sho/hoo presets. `none` means
        // the narrowband combine step is skipped entirely (no palette, no
        // weights), and `custom` carries explicit weights with no palette.
        'narrowband': {
          if (narrowbandPalette == NarrowbandPalette.sho ||
              narrowbandPalette == NarrowbandPalette.hoo)
            'palette': narrowbandPalette.wire,
          if (customWeights != null) 'weights': customWeights,
        },
      },
    };
  }

  /// Full persistence map (every knob, including the advisory cull knobs and the
  /// source preset). Stored as JSON in the `integrated_masters.settings_json`
  /// column and the app-settings default key.
  Map<String, dynamic> toJson() {
    return {
      'model': model.wire,
      'resampler': resampler.wire,
      'ransacThresholdPx': ransacThresholdPx,
      'maxRefStars': maxRefStars,
      'weightingEnabled': weightingEnabled,
      'weighting': weighting.wire,
      'snrPow': snrPow,
      'fwhmPow': fwhmPow,
      'eccPow': eccPow,
      'normalizationEnabled': normalizationEnabled,
      'normalization': normalization.wire,
      'localRows': localRows,
      'localCols': localCols,
      'combine': combine.wire,
      'reject': reject.wire,
      'rejectLow': rejectLow,
      'rejectHigh': rejectHigh,
      'minMaxLow': minMaxLow,
      'minMaxHigh': minMaxHigh,
      'generateRejectionMap': generateRejectionMap,
      'cosmeticCorrection': cosmeticCorrection,
      'outputBitDepth': outputBitDepth.wire,
      'autoCull': autoCull,
      'cullPercentile': cullPercentile,
      if (sourcePreset != null) 'sourcePreset': sourcePreset!.wire,
      'drizzle': drizzle,
      'drizzleScale': drizzleScale,
      'drizzlePixfrac': drizzlePixfrac,
      'drizzleKernel': drizzleKernel.wire,
      'bayerDrizzle': bayerDrizzle,
      'deconvolve': deconvolve,
      'deconIterations': deconIterations,
      'deconRegularization': deconRegularization,
      'psfKind': psfKind.wire,
      'reduceStars': reduceStars,
      'starReductionStrength': starReductionStrength,
      'starReduceMethod': starReduceMethod.wire,
      'extractBackground': extractBackground,
      'backgroundPolyDegree': backgroundPolyDegree,
      'backgroundPreserveMean': backgroundPreserveMean,
      'colorCalibrate': colorCalibrate,
      'whiteRefBv': whiteRefBv,
      'narrowbandPalette': narrowbandPalette.wire,
      if (customWeights != null) 'customWeights': customWeights,
    };
  }

  /// Inverse of [toJson]. Missing keys fall back to the [defaults] value for
  /// that field, so older persisted blobs forward-migrate without error rather
  /// than throwing on a newly-added knob.
  factory IntegrationSettings.fromJson(Map<String, dynamic> json) {
    const d = IntegrationSettings.defaults;
    T pick<T>(String key, T fallback) =>
        json.containsKey(key) && json[key] is T ? json[key] as T : fallback;
    double pickNum(String key, double fallback) {
      final v = json[key];
      if (v is num) return v.toDouble();
      return fallback;
    }

    final presetWire = json['sourcePreset'];
    return IntegrationSettings(
      model: json.containsKey('model')
          ? TransformModel.fromWire(json['model'] as String)
          : d.model,
      resampler: json.containsKey('resampler')
          ? Resampler.fromWire(json['resampler'] as String)
          : d.resampler,
      ransacThresholdPx: pickNum('ransacThresholdPx', d.ransacThresholdPx),
      maxRefStars: pick<int>('maxRefStars', d.maxRefStars),
      weightingEnabled: pick<bool>('weightingEnabled', d.weightingEnabled),
      weighting: json.containsKey('weighting')
          ? WeightFormula.fromWire(json['weighting'] as String)
          : d.weighting,
      snrPow: pickNum('snrPow', d.snrPow),
      fwhmPow: pickNum('fwhmPow', d.fwhmPow),
      eccPow: pickNum('eccPow', d.eccPow),
      normalizationEnabled: pick<bool>(
        'normalizationEnabled',
        d.normalizationEnabled,
      ),
      normalization: json.containsKey('normalization')
          ? NormalizationMode.fromWire(json['normalization'] as String)
          : d.normalization,
      localRows: pick<int>('localRows', d.localRows),
      localCols: pick<int>('localCols', d.localCols),
      combine: json.containsKey('combine')
          ? CombineMode.fromWire(json['combine'] as String)
          : d.combine,
      reject: json.containsKey('reject')
          ? RejectAlgorithm.fromWire(json['reject'] as String)
          : d.reject,
      rejectLow: pickNum('rejectLow', d.rejectLow),
      rejectHigh: pickNum('rejectHigh', d.rejectHigh),
      minMaxLow: pick<int>('minMaxLow', d.minMaxLow),
      minMaxHigh: pick<int>('minMaxHigh', d.minMaxHigh),
      generateRejectionMap: pick<bool>(
        'generateRejectionMap',
        d.generateRejectionMap,
      ),
      cosmeticCorrection: pick<bool>(
        'cosmeticCorrection',
        d.cosmeticCorrection,
      ),
      outputBitDepth: json.containsKey('outputBitDepth')
          ? OutputBitDepth.fromWire(json['outputBitDepth'] as String)
          : d.outputBitDepth,
      autoCull: pick<bool>('autoCull', d.autoCull),
      cullPercentile: pickNum('cullPercentile', d.cullPercentile),
      sourcePreset: presetWire is String
          ? IntegrationPreset.fromWire(presetWire)
          : null,
      drizzle: pick<bool>('drizzle', d.drizzle),
      drizzleScale: pickNum('drizzleScale', d.drizzleScale),
      drizzlePixfrac: pickNum('drizzlePixfrac', d.drizzlePixfrac),
      drizzleKernel: json.containsKey('drizzleKernel')
          ? DrizzleKernel.fromWire(json['drizzleKernel'] as String)
          : d.drizzleKernel,
      bayerDrizzle: pick<bool>('bayerDrizzle', d.bayerDrizzle),
      deconvolve: pick<bool>('deconvolve', d.deconvolve),
      deconIterations: pick<int>('deconIterations', d.deconIterations),
      deconRegularization: pickNum(
        'deconRegularization',
        d.deconRegularization,
      ),
      psfKind: json.containsKey('psfKind')
          ? PsfKind.fromWire(json['psfKind'] as String)
          : d.psfKind,
      reduceStars: pick<bool>('reduceStars', d.reduceStars),
      starReductionStrength: pickNum(
        'starReductionStrength',
        d.starReductionStrength,
      ),
      starReduceMethod: json.containsKey('starReduceMethod')
          ? StarReduceMethod.fromWire(json['starReduceMethod'] as String)
          : d.starReduceMethod,
      extractBackground: pick<bool>('extractBackground', d.extractBackground),
      backgroundPolyDegree: pick<int>(
        'backgroundPolyDegree',
        d.backgroundPolyDegree,
      ),
      backgroundPreserveMean: pick<bool>(
        'backgroundPreserveMean',
        d.backgroundPreserveMean,
      ),
      colorCalibrate: pick<bool>('colorCalibrate', d.colorCalibrate),
      whiteRefBv: pickNum('whiteRefBv', d.whiteRefBv),
      narrowbandPalette: json.containsKey('narrowbandPalette')
          ? NarrowbandPalette.fromWire(json['narrowbandPalette'] as String)
          : d.narrowbandPalette,
      customWeights: _decodeCustomWeights(json['customWeights']),
    );
  }

  /// Decode the optional `[[r,g,b], ...]` custom narrowband weight table,
  /// tolerating ragged / non-numeric rows (returns null when absent or
  /// unusable rather than throwing).
  static List<List<double>>? _decodeCustomWeights(Object? raw) {
    if (raw is! List) return null;
    final out = <List<double>>[];
    for (final row in raw) {
      if (row is List) {
        out.add([
          for (final v in row)
            if (v is num) v.toDouble(),
        ]);
      }
    }
    return out.isEmpty ? null : out;
  }

  /// JSON string form (for the `settings_json` DB column / app-settings value).
  String toJsonString() => jsonEncode(toJson());

  /// Parse a [toJsonString] blob. Returns [defaults] for null / blank / corrupt
  /// input rather than throwing — a stored-settings read should never crash the
  /// review screen.
  static IntegrationSettings fromJsonStringOrDefault(String? source) {
    if (source == null || source.trim().isEmpty) return defaults;
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) {
        return IntegrationSettings.fromJson(decoded);
      }
    } catch (_) {
      // Fall through to defaults on any decode/parse error.
    }
    return defaults;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntegrationSettings &&
          model == other.model &&
          resampler == other.resampler &&
          ransacThresholdPx == other.ransacThresholdPx &&
          maxRefStars == other.maxRefStars &&
          weightingEnabled == other.weightingEnabled &&
          weighting == other.weighting &&
          snrPow == other.snrPow &&
          fwhmPow == other.fwhmPow &&
          eccPow == other.eccPow &&
          normalizationEnabled == other.normalizationEnabled &&
          normalization == other.normalization &&
          localRows == other.localRows &&
          localCols == other.localCols &&
          combine == other.combine &&
          reject == other.reject &&
          rejectLow == other.rejectLow &&
          rejectHigh == other.rejectHigh &&
          minMaxLow == other.minMaxLow &&
          minMaxHigh == other.minMaxHigh &&
          generateRejectionMap == other.generateRejectionMap &&
          cosmeticCorrection == other.cosmeticCorrection &&
          outputBitDepth == other.outputBitDepth &&
          autoCull == other.autoCull &&
          cullPercentile == other.cullPercentile &&
          sourcePreset == other.sourcePreset &&
          drizzle == other.drizzle &&
          drizzleScale == other.drizzleScale &&
          drizzlePixfrac == other.drizzlePixfrac &&
          drizzleKernel == other.drizzleKernel &&
          bayerDrizzle == other.bayerDrizzle &&
          deconvolve == other.deconvolve &&
          deconIterations == other.deconIterations &&
          deconRegularization == other.deconRegularization &&
          psfKind == other.psfKind &&
          reduceStars == other.reduceStars &&
          starReductionStrength == other.starReductionStrength &&
          starReduceMethod == other.starReduceMethod &&
          extractBackground == other.extractBackground &&
          backgroundPolyDegree == other.backgroundPolyDegree &&
          backgroundPreserveMean == other.backgroundPreserveMean &&
          colorCalibrate == other.colorCalibrate &&
          whiteRefBv == other.whiteRefBv &&
          narrowbandPalette == other.narrowbandPalette &&
          _customWeightsEqual(customWeights, other.customWeights);

  @override
  int get hashCode => Object.hashAll([
    model,
    resampler,
    ransacThresholdPx,
    maxRefStars,
    weightingEnabled,
    weighting,
    snrPow,
    fwhmPow,
    eccPow,
    normalizationEnabled,
    normalization,
    localRows,
    localCols,
    combine,
    reject,
    rejectLow,
    rejectHigh,
    minMaxLow,
    minMaxHigh,
    generateRejectionMap,
    cosmeticCorrection,
    outputBitDepth,
    autoCull,
    cullPercentile,
    sourcePreset,
    drizzle,
    drizzleScale,
    drizzlePixfrac,
    drizzleKernel,
    bayerDrizzle,
    deconvolve,
    deconIterations,
    deconRegularization,
    psfKind,
    reduceStars,
    starReductionStrength,
    starReduceMethod,
    extractBackground,
    backgroundPolyDegree,
    backgroundPreserveMean,
    colorCalibrate,
    whiteRefBv,
    narrowbandPalette,
    _customWeightsHash(customWeights),
  ]);

  /// Order-sensitive deep equality for the optional custom-weight table.
  static bool _customWeightsEqual(
    List<List<double>>? a,
    List<List<double>>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ra = a[i];
      final rb = b[i];
      if (ra.length != rb.length) return false;
      for (var j = 0; j < ra.length; j++) {
        if (ra[j] != rb[j]) return false;
      }
    }
    return true;
  }

  /// Order-sensitive hash for the optional custom-weight table (null ⇒ 0).
  static int _customWeightsHash(List<List<double>>? weights) {
    if (weights == null) return 0;
    return Object.hashAll(weights.map((row) => Object.hashAll(row)));
  }
}
