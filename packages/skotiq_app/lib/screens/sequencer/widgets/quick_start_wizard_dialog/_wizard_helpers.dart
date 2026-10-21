// ignore_for_file: invalid_use_of_protected_member
// Initialisation, target search, preset and estimate helpers of the quick-start wizard state.
part of '../quick_start_wizard_dialog.dart';

extension _QuickStartWizardHelpers on _QuickStartWizardDialogState {
  /// Pulls the user's persisted Sequencer Settings / equipment profile /
  /// app settings once at wizard open and overwrites the in-class fallback
  /// constants. Read-only — the wizard is a one-shot dialog, so we don't
  /// need a stream subscription; reading once via `ref.read` keeps the
  /// state simple and consistent across the five steps.
  Future<void> _initializeWizard() async {
    final authority = ref.read(backendProvider);
    final generation = _authorityGeneration;
    try {
      final settingsFuture = ref.read(appSettingsProvider.future);
      final profilesFuture = ref.read(equipmentProfilesProvider.future);
      final settings = await settingsFuture;
      final profiles = await profilesFuture;
      if (!_isCurrentAuthority(authority, generation)) return;

      final activeProfile = profiles.activeProfile;
      _initializedProfile = activeProfile;
      _hasConfiguredFilters = activeProfile?.filterNames.isNotEmpty ?? false;
      _applyUserDefaults(settings, activeProfile);
      _initFilterConfigs(activeProfile?.filterNames ?? const []);
      _seedScalarControllers();
      setState(() {
        _initializationError = null;
        _initializing = false;
      });
      unawaited(_loadExposureContext());
    } catch (error) {
      if (!_isCurrentAuthority(authority, generation)) return;
      setState(() {
        _initializationError = error;
        _initializing = false;
      });
    }
  }

  void _retryInitialization() {
    ref.invalidate(appSettingsProvider);
    ref.invalidate(equipmentProfilesProvider);
    setState(() {
      _initializationError = null;
      _initializing = true;
    });
    _initializeWizard();
  }

  void _applyUserDefaults(
    AppSettingsState appSettings,
    EquipmentProfileModel? activeProfile,
  ) {
    final sequencerDefaults = ref.read(sequencerDefaultsProvider);

    bool populated = false;

    // Sequencer-Defaults-sourced values. These are always present (the
    // provider seeds defaults synchronously in its constructor) so we use
    // them unconditionally and only flip the hint if anything diverges
    // from the in-class fallbacks.
    if (sequencerDefaults.autofocusIntervalFrames > 0) {
      _autofocusEveryFrames = sequencerDefaults.autofocusIntervalFrames;
      if (sequencerDefaults.autofocusIntervalFrames !=
          _kWizardAutofocusEveryFramesFallback) {
        populated = true;
      }
    }
    if (sequencerDefaults.ditherPixels > 0) {
      _ditherPixels = sequencerDefaults.ditherPixels;
      if (sequencerDefaults.ditherPixels != _kWizardDitherPixelsFallback) {
        populated = true;
      }
    }
    if (sequencerDefaults.exposureCount > 0) {
      _loopCount = sequencerDefaults.exposureCount;
      if (sequencerDefaults.exposureCount != _kWizardExposureCountFallback) {
        populated = true;
      }
    }

    // App-settings authority has resolved before the wizard becomes editable,
    // so these safety choices never flash or persist fabricated fallbacks.
    _enableMeridianFlip = appSettings.enableMeridianFlip;
    _weatherAbort = appSettings.parkOnUnsafeWeather;
    _dawnShutdown = appSettings.parkBeforeDawn;
    populated = true;

    // Cooling temp lives on the active equipment profile, not in app
    // settings. `defaultCoolingTemp` is nullable; the user may simply not
    // have set one yet, in which case the fallback constant kicks in.
    // The wizard's "Cool camera" toggle itself stays user-facing — the
    // profile's `coolOnConnect` is about device-connect behaviour, not
    // sequence-start behaviour, so we don't tie them together here.
    if (activeProfile != null) {
      final profileCoolingTemp = activeProfile.defaultCoolingTemp;
      if (profileCoolingTemp != null && profileCoolingTemp.isFinite) {
        _coolingTemp = profileCoolingTemp;
        populated = true;
      }
    }

    _populatedFromSavedDefaults = populated;
  }

  Future<void> _loadExposureContext() async {
    final backend = ref.read(backendProvider);
    final generation = _authorityGeneration;
    final SmartNightExposureContext? context;
    try {
      context = await ref.read(smartNightExposureContextProvider.future);
    } catch (_) {
      return;
    }
    if (!_isCurrentAuthority(backend, generation) || context == null) return;
    setState(() {
      _exposureContext = context;
      for (final config in _filterConfigs) {
        if (!config.exposureEdited) {
          config.exposureSecs = _defaultExposureForFilter(config.filterName);
        }
      }
      // Async smart-context arrival is an external source; push the
      // recomputed exposures into the row controllers (guarded so any
      // user-edited row, which has exposureEdited=true, keeps its text).
      _syncFilterControllers();
    });
  }

  void _initFilterConfigs(List<String> filters) {
    if (filters.isEmpty) {
      // No filter wheel or no filters configured - default to a single "Light" entry
      _filterConfigs = [
        _FilterExposureConfig(
          filterName: 'Light',
          filterIndex: 0,
          enabled: true,
          exposureSecs: _defaultExposureForFilter('Light'),
        ),
      ];
    } else {
      _filterConfigs = filters.asMap().entries.map((entry) {
        return _FilterExposureConfig(
          filterName: entry.value,
          filterIndex: entry.key,
          enabled: _isCommonFilter(entry.value),
          exposureSecs: _defaultExposureForFilter(entry.value),
        );
      }).toList();
    }
    _syncFilterControllers();
  }

  bool _isCommonFilter(String name) {
    final lower = name.toLowerCase();
    return lower == 'l' ||
        lower == 'r' ||
        lower == 'g' ||
        lower == 'b' ||
        lower == 'ha' ||
        lower == 'h-alpha' ||
        lower == 'oiii' ||
        lower == 'sii';
  }

  double _defaultExposureForFilter(String name) {
    final smartExposure = _exposureContext?.recommendForFilter(name).seconds;
    if (smartExposure != null && smartExposure.isFinite && smartExposure > 0) {
      return smartExposure;
    }

    final lower = name.toLowerCase();
    if (lower == 'ha' ||
        lower == 'h-alpha' ||
        lower == 'oiii' ||
        lower == 'sii') {
      return _kWizardNarrowbandFallbackSecs; // 5 minutes for narrowband
    }
    return _kWizardBroadbandFallbackSecs; // 2 minutes for broadband
  }

  bool _isCurrentAuthority(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _authorityGeneration &&
      identical(ref.read(backendProvider), backend);

  // Target search

  void _onTargetSearch(String query) {
    _searchDebounce?.cancel();
    final revision = ++_searchRevision;
    final trimmed = query.trim();
    // Typing a different name drops the previous pick, so its coordinates are
    // never saved under a name that does not describe them.
    final keepSelection = _selectedTarget != null &&
        normalizeTargetName(_selectedTarget!.name) ==
            normalizeTargetName(trimmed);
    if (!keepSelection) _dropSelectedTarget();
    if (trimmed.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
        _searchCompleted = false;
        _searchError = null;
        _onlineLookupMessage = null;
        _lastSearchQuery = trimmed;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _searchCompleted = false;
      _searchError = null;
      _onlineLookupMessage = null;
      _lastSearchQuery = trimmed;
    });

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _runTargetSearch(trimmed, revision);
    });
  }

  /// Ranks [query] against the installed catalog and the saved target library
  /// and shows the result. Returns the candidates, or null when a newer search
  /// or an authority change made this one stale.
  Future<List<_TargetCandidate>?> _runTargetSearch(
    String query,
    int revision,
  ) async {
    final authority = ref.read(backendProvider);
    final generation = _authorityGeneration;
    bool current() =>
        revision == _searchRevision &&
        _isCurrentAuthority(authority, generation);

    Object? failure;
    var catalog = const <RankedTarget>[];
    try {
      final dsos = await ref.read(loadedDsosProvider.future);
      catalog = TargetNameResolver.rank(query, dsos, limit: 20);
    } catch (e) {
      failure = e;
    }

    var library = const <DbTarget>[];
    try {
      // On a remote-client slave the local targets table is never populated
      // (targets only arrive over the wire), so the search goes to the host's
      // `/api/targets/search`; the host searches its own DAO.
      final backend = ref.read(backendProvider);
      if (backend is NetworkBackend) {
        final rows = await backend.searchTargets(query);
        library = rows.map(DbTarget.fromJson).toList();
      } else {
        library = await ref.read(targetsDaoProvider).searchTargets(query);
      }
    } catch (e) {
      failure ??= e;
    }
    if (!current()) return null;

    // Objects the query names outright come first, then saved targets, then
    // catalog objects that only contain the text.
    final catalogCandidates = catalog.map(_TargetCandidate.fromCatalog);
    final results = <_TargetCandidate>[
      ...catalogCandidates.where((c) => c.exact),
      ...library.map((t) => _TargetCandidate.fromLibrary(t, query)),
      ...catalogCandidates.where((c) => !c.exact),
    ];
    setState(() {
      _searchResults = results;
      _isSearching = false;
      _searchCompleted = true;
      // A failure only matters when it left nothing to show.
      _searchError = results.isEmpty ? failure : null;
    });
    return results;
  }

  /// Enter in the target field: select the one object the text names, keep
  /// the list open when several do, and ask SIMBAD when nothing local does.
  Future<void> _submitTargetSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchDebounce?.cancel();
    final revision = ++_searchRevision;
    setState(() {
      _isSearching = true;
      _onlineLookupMessage = null;
      _lastSearchQuery = trimmed;
    });
    final results = await _runTargetSearch(trimmed, revision);
    if (results == null || !mounted) return;

    final exact = results.where((c) => c.exact).toList();
    if (exact.length == 1) {
      _selectTarget(exact.single);
      return;
    }
    if (exact.length > 1) return;
    await _lookUpTargetOnline(trimmed);
  }

  /// Resolves [query] through SIMBAD's exact name resolver. Never takes an
  /// object that merely contains the text in one of its identifiers.
  Future<void> _lookUpTargetOnline(String query) async {
    final revision = ++_searchRevision;
    final authority = ref.read(backendProvider);
    final generation = _authorityGeneration;
    setState(() {
      _isSearching = true;
      _onlineLookupMessage = null;
    });
    String? message;
    _TargetCandidate? found;
    try {
      final resolved = await ref.read(sesameNameResolverProvider).resolve(
            query,
          );
      if (resolved == null) {
        message = 'SIMBAD has no object named "$query". Check the spelling, '
            'or enter RA/Dec below.';
      } else {
        found = _TargetCandidate(
          name: resolved.mainId,
          ra: resolved.raHours,
          dec: resolved.decDegrees,
          objectType: resolved.objectType,
          source: _TargetSource.simbad,
          exact: true,
        );
      }
    } on TargetNameLookupUnavailable catch (e) {
      message = '"$query" is not in the installed catalog or your library, '
          'and SIMBAD could not be reached to look it up (${e.message}). '
          'Enter RA/Dec below instead.';
    }
    if (revision != _searchRevision ||
        !_isCurrentAuthority(authority, generation)) {
      return;
    }
    if (found != null) {
      _selectTarget(found);
      return;
    }
    setState(() {
      _isSearching = false;
      _searchCompleted = true;
      _onlineLookupMessage = message;
    });
  }

  /// Forgets the picked target, and its coordinates too while the RA/Dec
  /// fields still hold them unedited; coordinates the user typed stay.
  void _dropSelectedTarget() {
    final dropped = _selectedTarget;
    if (dropped == null) return;
    _selectedTarget = null;
    if (_raController.text == _formatRa(dropped.ra) &&
        _decController.text == _formatDec(dropped.dec)) {
      _raController.clear();
      _decController.clear();
    }
  }

  void _selectTarget(_TargetCandidate target) {
    _searchDebounce?.cancel();
    _searchRevision++;
    setState(() {
      _selectedTarget = target;
      _targetNameController.text = target.name;
      _raController.text = _formatRa(target.ra);
      _decController.text = _formatDec(target.dec);
      _searchResults = [];
      _isSearching = false;
      // The list is collapsing because the user picked something, not
      // because the search failed — do not raise the empty-state message.
      _searchCompleted = false;
      _searchError = null;
      _onlineLookupMessage = null;
    });
  }

  String _formatRa(double raHours) =>
      CoordinateFormat.ra(raHours, style: SexagesimalStyle.plainLetters);

  String _formatDec(double decDeg) {
    final sign = decDeg >= 0 ? '+' : '-';
    final abs = decDeg.abs();
    final d = abs.floor();
    final m = ((abs - d) * 60).floor();
    final s = ((abs - d - m / 60) * 3600).toStringAsFixed(0);
    return "$sign${d}d $m' $s\"";
  }

  double? _parseRa(String text) {
    // Accept formats: "12.5", "12h 30m 0s", "12:30:00"
    text = text.trim();
    if (text.isEmpty) return null;

    // Try simple decimal
    final decimal = double.tryParse(text);
    if (decimal != null) {
      return decimal.isFinite && decimal >= 0 && decimal < 24 ? decimal : null;
    }

    return CoordinateParser.parseRa(text);
  }

  double? _parseDec(String text) {
    // Accept formats: "45.5", "+45d 30' 0\"", "+45:30:00"
    text = text.trim();
    if (text.isEmpty) return null;

    // Try simple decimal
    final decimal = double.tryParse(text);
    if (decimal != null) {
      return decimal.isFinite && decimal >= -90 && decimal <= 90
          ? decimal
          : null;
    }

    return CoordinateParser.parseDec(text);
  }

  // Preset application

  void _applyPreset(_ExposurePreset preset) {
    setState(() {
      _selectedPreset = preset;

      for (final config in _filterConfigs) {
        final lower = config.filterName.toLowerCase();

        switch (preset) {
          case _ExposurePreset.lrgbBroadband:
            config.enabled =
                lower == 'l' || lower == 'r' || lower == 'g' || lower == 'b';
            config.exposureSecs = _defaultExposureForFilter(config.filterName);
            config.exposureEdited = false;
            config.binning = BinningMode.one;

          case _ExposurePreset.narrowbandSho:
            config.enabled = lower == 'sii' ||
                lower == 'ha' ||
                lower == 'h-alpha' ||
                lower == 'oiii';
            config.exposureSecs = _defaultExposureForFilter(config.filterName);
            config.exposureEdited = false;
            config.binning = BinningMode.one;

          case _ExposurePreset.narrowbandHaOiii:
            config.enabled =
                lower == 'ha' || lower == 'h-alpha' || lower == 'oiii';
            config.exposureSecs = _defaultExposureForFilter(config.filterName);
            config.exposureEdited = false;
            config.binning = BinningMode.one;

          case _ExposurePreset.oscNoFilter:
            config.enabled = config.filterIndex == 0;
            config.exposureSecs = _defaultExposureForFilter(config.filterName);
            config.exposureEdited = false;
            config.binning = BinningMode.one;

          case _ExposurePreset.custom:
            // Don't change anything
            break;
        }
      }
      // Preset application is an external source — push the new
      // exposures/counts into the row controllers.
      _syncFilterControllers();
    });
  }

  /// Write the user's wizard choices back into their persisted Sequencer
  /// Settings / app settings so the next launch pre-fills with them.
  ///
  /// The chosen cooling temperature is written back to the active equipment
  /// profile's `defaultCoolingTemp` (the canonical home for it, owned by the
  /// equipment area). We only touch the profile when the user enabled cooling
  /// AND the value actually changed, and we use the equipment profiles
  /// notifier's [EquipmentProfilesNotifier.updateProfile] setter so the write
  /// goes through the same DAO/validation path the equipment editor uses.
  Future<void> _persistChoicesAsDefaults() async {
    final sequencerDefaults = ref.read(sequencerDefaultsProvider.notifier);
    final appSettings = ref.read(appSettingsProvider.notifier);
    final equipmentProfiles = ref.read(equipmentProfilesProvider.notifier);
    final activeProfile = _initializedProfile;
    // Derive a representative exposure count: the loop count is the wizard's
    // single iteration knob and is what the user most directly tuned.
    final exposureCount = _loopCount > 0 ? _loopCount : null;
    await sequencerDefaults.updateAutofocusDefaults(
      intervalFrames: _autofocusEveryFrames,
    );
    await sequencerDefaults.updateDitherDefaults(pixels: _ditherPixels);
    if (exposureCount != null) {
      await sequencerDefaults.updateExposureDefaults(count: exposureCount);
    }
    await appSettings.setEnableMeridianFlip(_enableMeridianFlip);
    await appSettings.setParkOnUnsafeWeather(_weatherAbort);
    await appSettings.setParkBeforeDawn(_dawnShutdown);
    // Persist the cooling setpoint onto the active equipment profile. Only
    // when cooling is enabled (otherwise the field is meaningless this run),
    // the profile has a DB id, and the value diverges from what the profile
    // already carries.
    if (_coolCamera &&
        activeProfile != null &&
        activeProfile.id != null &&
        _coolingTemp.isFinite &&
        activeProfile.defaultCoolingTemp != _coolingTemp) {
      await equipmentProfiles.updateProfile(
        activeProfile.copyWith(defaultCoolingTemp: _coolingTemp),
      );
    }
  }

  String _buildDescription(List<_FilterExposureConfig> enabledFilters) {
    final filterSummary = enabledFilters
        .map((f) => '${f.filterName}: ${_loopCount}x${f.exposureSecs.round()}s')
        .join(', ');
    final features = <String>[];
    if (_enableAutofocus) features.add('autofocus');
    if (_enableDithering) features.add('dithering');
    if (_enableMeridianFlip) features.add('meridian flip');
    if (_enableAutoGuide) features.add('auto-guide');
    if (_weatherAbort) features.add('weather safety');
    return '$filterSummary | ${features.join(", ")}';
  }

  // Estimated time calculation

  double _estimatedTotalSecs() {
    final enabledFilters = _filterConfigs.where((f) => f.enabled).toList();
    if (enabledFilters.isEmpty) return 0;

    // Per-iteration: sum of all filter exposures + dither settle time
    double perIterationSecs = 0;
    for (final f in enabledFilters) {
      perIterationSecs += f.exposureSecs;
    }
    if (_enableDithering) perIterationSecs += _ditherSettleSecsForEstimate();

    final totalSecs = perIterationSecs * _loopCount;

    // Add overhead: cooling ~5min, slew+center ~3min, autofocus ~2min, warm ~5min
    double overheadSecs = 0;
    if (_coolCamera) overheadSecs += 300;
    overheadSecs += 180; // slew + center
    if (_enableAutofocus) overheadSecs += 120;
    if (_coolCamera) overheadSecs += 300;

    return totalSecs + overheadSecs;
  }

  /// The wizard's "Estimated Duration" line, prefixed "~" because it is one.
  String _formatDuration(double totalSecs) =>
      '~${DurationFormat.seconds(totalSecs, style: DurationStyle.compact, roundToMinute: true)}';

  /// Per-iteration dither-settle estimate used by the duration preview.
  /// Reads the user's Sequencer-Defaults settle time so the wizard's
  /// "Estimated Duration" agrees with the value the sequence will
  /// actually run with.
  double _ditherSettleSecsForEstimate() {
    final sequencerDefaults = ref.read(sequencerDefaultsProvider);
    return sequencerDefaults.ditherSettleTime > 0
        ? sequencerDefaults.ditherSettleTime
        : _kWizardDitherSettleSecondsFallback;
  }

  // Validation

  bool _canAdvance() {
    switch (_currentStep) {
      case 0: // Target
        return _targetNameController.text.trim().isNotEmpty &&
            (_selectedTarget != null ||
                (_parseRa(_raController.text) != null &&
                    _parseDec(_decController.text) != null));
      case 1: // Filters
        return _filterConfigs.any((f) => f.enabled);
      case 2: // Automation
      case 3: // Safety
        return true;
      case 4: // Review
        return true;
      default:
        return false;
    }
  }

  void _update(VoidCallback callback) => setState(callback);

  /// Re-run the exposure recommendation against the latest
  /// [_exposureContext] and re-seed every non-user-edited filter row. Lets
  /// the user regenerate the preview after tweaking knobs on earlier steps.
  /// User-edited exposures (exposureEdited == true) are preserved.
  void _rePreviewExposures() {
    setState(() {
      for (final config in _filterConfigs) {
        if (!config.exposureEdited) {
          config.exposureSecs = _defaultExposureForFilter(config.filterName);
        }
      }
      _syncFilterControllers();
    });
    // Best-effort refresh of the smart context in case the active profile /
    // sky inputs changed since the wizard opened; its async arrival re-seeds
    // again via _loadExposureContext.
    _loadExposureContext();
  }
}
