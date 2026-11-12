part of '../science_provider.dart';

class ScienceSettings {
  final bool advancedModeEnabled;
  final bool overlayEnabled;
  final bool photometryEnabled;
  final bool photometricCalibrationEnabled;
  final bool transparencyEnabled;
  final bool psfMapEnabled;
  final bool astrometricResidualsEnabled;
  final bool movingObjectsEnabled;

  /// Whether solved lights fold into the Your Sky atlas (and First Light has
  /// a template to compare against). Off until the user turns it on.
  final bool skyAtlasEnabled;

  /// Largest size, in GB, the Your Sky atlas may reach before new frames stop
  /// being added to it. 0 means no limit. Reaching it never deletes anything.
  final int skyAtlasLimitGb;
  final bool narrowbandRatiosEnabled;
  final bool frameQualityMapsEnabled;
  final bool surface3dEnabled;
  final bool manualPurgeOnly;

  /// When true, after calibration + transparency complete the science
  /// pipeline writes a small set of standard keywords back onto the
  /// captured FITS file (MAGZP, MAGZPERR, MAGZPSRC, MAGZPNST, MAGLIM5,
  /// TRANSPAR, EXTINCT, SKHA_VER). This makes Skotiq's photometric and atmospheric
  /// measurements directly visible to PixInsight, AstroPixelProcessor,
  /// Siril, and any other tool that reads the original capture.
  ///
  /// Default true — explicit opt-out exists for users who want the
  /// captured frame's header to remain byte-identical to what the camera
  /// driver produced.
  final bool fitsHeaderWritebackEnabled;

  /// MPC observatory code (3 characters, e.g. "G40").
  /// Required for generating Minor Planet Center reports.
  final String mpcObservatoryCode;

  /// AAVSO observer code (up to 5 characters, e.g. "XYZ").
  /// Required for generating AAVSO Extended Format reports.
  final String aavsoObserverCode;

  /// Observer name written into the MPC ADES `observers`/`measurers` /
  /// `submitter` header blocks and the TNS `reporter` field. Free text.
  final String observerName;

  /// Astrometric reference catalog the plate-solver used (ADES `astCat`, e.g.
  /// "Gaia2"/"Gaia3"). Empty defaults to "UNK" in the ADES report (flagged).
  final String mpcAstrometricCatalog;

  // ── TNS bot credentials (non-secret identifiers; the API key is in the
  //    keyring via SecretField.tnsApiKey, never here). ──────────────────────

  /// TNS bot id (the integer in the mandatory `tns_marker` User-Agent header).
  final int tnsBotId;

  /// TNS bot name (the `name` field in the `tns_marker` User-Agent header).
  final String tnsBotName;

  /// TNS reporting-group id (`reporting_group_id` in the at_report JSON).
  final int tnsReportingGroupId;

  /// TNS data-source / survey id (`discovery_data_source_id`).
  final int tnsDataSourceId;

  /// Free-text reporter name(s) for the TNS `reporter` field. Falls back to
  /// [observerName] when empty.
  final String tnsReporterName;

  /// Use the TNS sandbox base URL (`sandbox.wis-tns.org`) instead of
  /// production. Production submits create real, public AT records.
  final bool tnsUseSandbox;

  /// When true, each captured light frame is evaluated against
  /// [frameGradeRulesJson] (or [FrameGradeRules.conservativeDefaults] when
  /// unset) and rejected in the database when it fails — same semantics as
  /// the Image Grader dialog, but automatic on every capture.
  final bool autoFrameGradingEnabled;

  /// JSON blob persisted via [FrameGradeRules.toJsonString]. Null uses
  /// conservative defaults while auto-grading is enabled.
  final String? frameGradeRulesJson;

  final bool scienceGuideCollapsed;

  const ScienceSettings({
    this.advancedModeEnabled = false,
    this.overlayEnabled = true,
    this.photometryEnabled = true,
    this.photometricCalibrationEnabled = true,
    this.transparencyEnabled = true,
    this.psfMapEnabled = true,
    this.astrometricResidualsEnabled = true,
    this.movingObjectsEnabled = false,
    this.skyAtlasEnabled = false,
    this.skyAtlasLimitGb = defaultSkyAtlasLimitGb,
    this.narrowbandRatiosEnabled = false,
    this.frameQualityMapsEnabled = true,
    this.surface3dEnabled = true,
    this.manualPurgeOnly = true,
    this.fitsHeaderWritebackEnabled = true,
    this.mpcObservatoryCode = '',
    this.aavsoObserverCode = '',
    this.observerName = '',
    this.mpcAstrometricCatalog = '',
    this.tnsBotId = 0,
    this.tnsBotName = '',
    this.tnsReportingGroupId = 0,
    this.tnsDataSourceId = 0,
    this.tnsReporterName = '',
    this.tnsUseSandbox = false,
    this.autoFrameGradingEnabled = false,
    this.frameGradeRulesJson,
    this.scienceGuideCollapsed = false,
  });

  /// What the stored [rows] hold. A switch or number that cannot be read
  /// throws [FormatException] rather than reading as its default: Science
  /// does not run on settings the operator did not choose.
  factory ScienceSettings.fromRows(Map<String, String> rows) {
    T read<T>(Setting<T> setting) => setting.decodeStrict(rows[setting.key]);
    return ScienceSettings(
      advancedModeEnabled: read(StoreSettings.scienceAdvancedMode),
      overlayEnabled: read(StoreSettings.scienceOverlay),
      photometryEnabled: read(StoreSettings.sciencePhotometry),
      photometricCalibrationEnabled: read(
        StoreSettings.sciencePhotometricCalibration,
      ),
      transparencyEnabled: read(StoreSettings.scienceTransparency),
      psfMapEnabled: read(StoreSettings.sciencePsfMap),
      astrometricResidualsEnabled: read(
        StoreSettings.scienceAstrometricResiduals,
      ),
      movingObjectsEnabled: read(StoreSettings.scienceMovingObjects),
      skyAtlasEnabled: read(StoreSettings.scienceSkyAtlas),
      skyAtlasLimitGb: parseSkyAtlasLimitGb(
        rows[StoreSettings.scienceSkyAtlasLimitGb.key],
      ),
      narrowbandRatiosEnabled: read(StoreSettings.scienceNarrowbandRatios),
      frameQualityMapsEnabled: read(StoreSettings.scienceFrameQualityMaps),
      surface3dEnabled: read(StoreSettings.scienceSurface3d),
      manualPurgeOnly: read(StoreSettings.scienceManualPurgeOnly),
      fitsHeaderWritebackEnabled: read(
        StoreSettings.scienceFitsHeaderWriteback,
      ),
      mpcObservatoryCode: read(StoreSettings.scienceMpcObservatoryCode),
      aavsoObserverCode: read(StoreSettings.scienceAavsoObserverCode),
      observerName: read(StoreSettings.scienceObserverName),
      mpcAstrometricCatalog: read(StoreSettings.scienceMpcAstrometricCatalog),
      tnsBotId: read(StoreSettings.scienceTnsBotId),
      tnsBotName: read(StoreSettings.scienceTnsBotName),
      tnsReportingGroupId: read(StoreSettings.scienceTnsReportingGroupId),
      tnsDataSourceId: read(StoreSettings.scienceTnsDataSourceId),
      tnsReporterName: read(StoreSettings.scienceTnsReporterName),
      tnsUseSandbox: read(StoreSettings.scienceTnsUseSandbox),
      // Frame grading was first a switch of the application settings; either
      // one being on grades frames.
      autoFrameGradingEnabled:
          read(StoreSettings.scienceAutoFrameGrading) ||
          read(AppSettingDefs.enableImageGrading),
      frameGradeRulesJson: read(StoreSettings.scienceFrameGradeRules),
      scienceGuideCollapsed: read(StoreSettings.scienceGuideCollapsed),
    );
  }

  /// Rules applied by [FrameAutoGrader] and shown in the Image Grader UI.
  FrameGradeRules resolvedFrameGradeRules() {
    final parsed = FrameGradeRules.fromJsonString(frameGradeRulesJson);
    if (parsed != null && !parsed.isEmpty) return parsed;
    if (autoFrameGradingEnabled) return FrameGradeRules.conservativeDefaults;
    return const FrameGradeRules();
  }

  ScienceSettings copyWith({
    bool? advancedModeEnabled,
    bool? overlayEnabled,
    bool? photometryEnabled,
    bool? photometricCalibrationEnabled,
    bool? transparencyEnabled,
    bool? psfMapEnabled,
    bool? astrometricResidualsEnabled,
    bool? movingObjectsEnabled,
    bool? skyAtlasEnabled,
    int? skyAtlasLimitGb,
    bool? narrowbandRatiosEnabled,
    bool? frameQualityMapsEnabled,
    bool? surface3dEnabled,
    bool? manualPurgeOnly,
    bool? fitsHeaderWritebackEnabled,
    String? mpcObservatoryCode,
    String? aavsoObserverCode,
    String? observerName,
    String? mpcAstrometricCatalog,
    int? tnsBotId,
    String? tnsBotName,
    int? tnsReportingGroupId,
    int? tnsDataSourceId,
    String? tnsReporterName,
    bool? tnsUseSandbox,
    bool? autoFrameGradingEnabled,
    String? frameGradeRulesJson,
    bool clearFrameGradeRulesJson = false,
    bool? scienceGuideCollapsed,
  }) {
    return ScienceSettings(
      advancedModeEnabled: advancedModeEnabled ?? this.advancedModeEnabled,
      overlayEnabled: overlayEnabled ?? this.overlayEnabled,
      photometryEnabled: photometryEnabled ?? this.photometryEnabled,
      photometricCalibrationEnabled:
          photometricCalibrationEnabled ?? this.photometricCalibrationEnabled,
      transparencyEnabled: transparencyEnabled ?? this.transparencyEnabled,
      psfMapEnabled: psfMapEnabled ?? this.psfMapEnabled,
      astrometricResidualsEnabled:
          astrometricResidualsEnabled ?? this.astrometricResidualsEnabled,
      movingObjectsEnabled: movingObjectsEnabled ?? this.movingObjectsEnabled,
      skyAtlasEnabled: skyAtlasEnabled ?? this.skyAtlasEnabled,
      skyAtlasLimitGb: skyAtlasLimitGb ?? this.skyAtlasLimitGb,
      narrowbandRatiosEnabled:
          narrowbandRatiosEnabled ?? this.narrowbandRatiosEnabled,
      frameQualityMapsEnabled:
          frameQualityMapsEnabled ?? this.frameQualityMapsEnabled,
      surface3dEnabled: surface3dEnabled ?? this.surface3dEnabled,
      manualPurgeOnly: manualPurgeOnly ?? this.manualPurgeOnly,
      fitsHeaderWritebackEnabled:
          fitsHeaderWritebackEnabled ?? this.fitsHeaderWritebackEnabled,
      mpcObservatoryCode: mpcObservatoryCode ?? this.mpcObservatoryCode,
      aavsoObserverCode: aavsoObserverCode ?? this.aavsoObserverCode,
      observerName: observerName ?? this.observerName,
      mpcAstrometricCatalog:
          mpcAstrometricCatalog ?? this.mpcAstrometricCatalog,
      tnsBotId: tnsBotId ?? this.tnsBotId,
      tnsBotName: tnsBotName ?? this.tnsBotName,
      tnsReportingGroupId: tnsReportingGroupId ?? this.tnsReportingGroupId,
      tnsDataSourceId: tnsDataSourceId ?? this.tnsDataSourceId,
      tnsReporterName: tnsReporterName ?? this.tnsReporterName,
      tnsUseSandbox: tnsUseSandbox ?? this.tnsUseSandbox,
      autoFrameGradingEnabled:
          autoFrameGradingEnabled ?? this.autoFrameGradingEnabled,
      frameGradeRulesJson: clearFrameGradeRulesJson
          ? null
          : (frameGradeRulesJson ?? this.frameGradeRulesJson),
      scienceGuideCollapsed:
          scienceGuideCollapsed ?? this.scienceGuideCollapsed,
    );
  }
}

class ScienceSettingsNotifier extends AsyncNotifier<ScienceSettings> {
  @override
  Future<ScienceSettings> build() async =>
      ScienceSettings.fromRows(await _loadScienceSettingsMap(ref));

  Future<void> _writeTail = Future<void>.value();

  Future<void> _serialized(
    Future<void> Function(ScienceSettings current) operation,
  ) {
    final result = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Science settings are not loaded; refusing to overwrite them '
          'with defaults.',
        );
      }
      await operation(current);
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _update<T>(
    Setting<T> setting,
    T value,
    ScienceSettings Function(ScienceSettings current) change,
  ) {
    return _serialized((current) async {
      final updated = change(current);
      await _writeScienceSettings(ref, setting.toRows(value));
      state = AsyncData(updated);
    });
  }

  Future<void> setAdvancedModeEnabled(bool enabled) => _update(
    StoreSettings.scienceAdvancedMode,
    enabled,
    (current) => current.copyWith(advancedModeEnabled: enabled),
  );

  Future<void> setOverlayEnabled(bool enabled) => _update(
    StoreSettings.scienceOverlay,
    enabled,
    (current) => current.copyWith(overlayEnabled: enabled),
  );

  static const _featureSettings = {
    ScienceFeature.photometry: StoreSettings.sciencePhotometry,
    ScienceFeature.photometricCalibration:
        StoreSettings.sciencePhotometricCalibration,
    ScienceFeature.transparency: StoreSettings.scienceTransparency,
    ScienceFeature.psfMap: StoreSettings.sciencePsfMap,
    ScienceFeature.astrometricResiduals:
        StoreSettings.scienceAstrometricResiduals,
    ScienceFeature.movingObjects: StoreSettings.scienceMovingObjects,
    ScienceFeature.narrowbandRatios: StoreSettings.scienceNarrowbandRatios,
    ScienceFeature.frameQualityMaps: StoreSettings.scienceFrameQualityMaps,
    ScienceFeature.skyAtlas: StoreSettings.scienceSkyAtlas,
    ScienceFeature.surface3d: StoreSettings.scienceSurface3d,
  };

  Future<void> setFeatureEnabled(ScienceFeature feature, bool enabled) {
    return _update(_featureSettings[feature]!, enabled, (current) {
      return switch (feature) {
        ScienceFeature.photometry => current.copyWith(
          photometryEnabled: enabled,
        ),
        ScienceFeature.photometricCalibration => current.copyWith(
          photometricCalibrationEnabled: enabled,
        ),
        ScienceFeature.transparency => current.copyWith(
          transparencyEnabled: enabled,
        ),
        ScienceFeature.psfMap => current.copyWith(psfMapEnabled: enabled),
        ScienceFeature.astrometricResiduals => current.copyWith(
          astrometricResidualsEnabled: enabled,
        ),
        ScienceFeature.movingObjects => current.copyWith(
          movingObjectsEnabled: enabled,
        ),
        ScienceFeature.narrowbandRatios => current.copyWith(
          narrowbandRatiosEnabled: enabled,
        ),
        ScienceFeature.frameQualityMaps => current.copyWith(
          frameQualityMapsEnabled: enabled,
        ),
        ScienceFeature.surface3d => current.copyWith(surface3dEnabled: enabled),
        ScienceFeature.skyAtlas => current.copyWith(skyAtlasEnabled: enabled),
      };
    });
  }

  Future<void> setSkyAtlasLimitGb(int gb) {
    final value = StoreSettings.scienceSkyAtlasLimitGb.clean(gb);
    return _update(
      StoreSettings.scienceSkyAtlasLimitGb,
      value,
      (current) => current.copyWith(skyAtlasLimitGb: value),
    );
  }

  Future<void> setMpcObservatoryCode(String code) => _update(
    StoreSettings.scienceMpcObservatoryCode,
    code,
    (current) => current.copyWith(mpcObservatoryCode: code),
  );

  Future<void> setAavsoObserverCode(String code) => _update(
    StoreSettings.scienceAavsoObserverCode,
    code,
    (current) => current.copyWith(aavsoObserverCode: code),
  );

  Future<void> setObserverName(String name) => _update(
    StoreSettings.scienceObserverName,
    name,
    (current) => current.copyWith(observerName: name),
  );

  Future<void> setMpcAstrometricCatalog(String catalog) => _update(
    StoreSettings.scienceMpcAstrometricCatalog,
    catalog,
    (current) => current.copyWith(mpcAstrometricCatalog: catalog),
  );

  Future<void> setTnsBotId(int id) => _update(
    StoreSettings.scienceTnsBotId,
    id,
    (current) => current.copyWith(tnsBotId: id),
  );

  Future<void> setTnsBotName(String name) => _update(
    StoreSettings.scienceTnsBotName,
    name,
    (current) => current.copyWith(tnsBotName: name),
  );

  Future<void> setTnsReportingGroupId(int id) => _update(
    StoreSettings.scienceTnsReportingGroupId,
    id,
    (current) => current.copyWith(tnsReportingGroupId: id),
  );

  Future<void> setTnsDataSourceId(int id) => _update(
    StoreSettings.scienceTnsDataSourceId,
    id,
    (current) => current.copyWith(tnsDataSourceId: id),
  );

  Future<void> setTnsReporterName(String name) => _update(
    StoreSettings.scienceTnsReporterName,
    name,
    (current) => current.copyWith(tnsReporterName: name),
  );

  Future<void> setTnsUseSandbox(bool enabled) => _update(
    StoreSettings.scienceTnsUseSandbox,
    enabled,
    (current) => current.copyWith(tnsUseSandbox: enabled),
  );

  Future<void> setFitsHeaderWritebackEnabled(bool enabled) => _update(
    StoreSettings.scienceFitsHeaderWriteback,
    enabled,
    (current) => current.copyWith(fitsHeaderWritebackEnabled: enabled),
  );

  Future<void> setAutoFrameGradingEnabled(bool enabled) {
    return _serialized((current) async {
      await ref.read(appSettingsProvider.future);
      await ref
          .read(appSettingsProvider.notifier)
          .setEnableImageGrading(enabled);
      await _writeScienceSettings(
        ref,
        StoreSettings.scienceAutoFrameGrading.toRows(enabled),
      );
      state = AsyncData(current.copyWith(autoFrameGradingEnabled: enabled));
    });
  }

  Future<void> setScienceGuideCollapsed(bool collapsed) => _update(
    StoreSettings.scienceGuideCollapsed,
    collapsed,
    (current) => current.copyWith(scienceGuideCollapsed: collapsed),
  );

  Future<void> setFrameGradeRules(FrameGradeRules rules) {
    final json = rules.isEmpty ? null : rules.toJsonString();
    return _update(
      StoreSettings.scienceFrameGradeRules,
      json,
      (current) => json == null
          ? current.copyWith(clearFrameGradeRulesJson: true)
          : current.copyWith(frameGradeRulesJson: json),
    );
  }
}

final scienceSettingsProvider =
    AsyncNotifierProvider<ScienceSettingsNotifier, ScienceSettings>(
      ScienceSettingsNotifier.new,
    );
