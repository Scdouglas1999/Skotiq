import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../panel_widgets.dart';
import 'depthlock_pickers.dart';
import 'depthlock_presentation.dart';
import 'depthlock_presets.dart';

/// A calibration master as the editor shows it: what went into it, not where
/// it lives.
@immutable
class DepthLockMasterChoice {
  const DepthLockMasterChoice({
    required this.path,
    this.summary,
    this.unmatchedReason,
  });

  /// Absolute path. Required by the native calibrator; shown only on hover.
  final String path;

  /// "20 × 120 s · −10 °C", from the calibration library's record.
  final String? summary;

  /// Why the library could not match one, when it could not.
  final String? unmatchedReason;

  bool get isSet => path.trim().isNotEmpty;

  DepthLockMasterChoice withPath(String value) =>
      DepthLockMasterChoice(path: value, unmatchedReason: unmatchedReason);
}

/// Create or revise one DepthLock goal.
///
/// The form asks two questions an observer can answer — how deep, and is the
/// calibration right — and keeps every number that follows from those behind
/// **Advanced**. The error floor in particular is no longer typed: it is
/// derived from the operator's own masters, because a number invented at the
/// keyboard is the one input that can make a calibration artefact look like
/// sky signal.
///
/// The same form creates and revises, because a revision IS a replacement
/// definition: showing a thinner dialog for an edit would let someone change
/// the depth without seeing the calibration it is measured through. What
/// changes between the two is the warning at the top and the verb on the
/// button.
class DepthLockGoalEditor extends ConsumerStatefulWidget {
  const DepthLockGoalEditor({
    super.key,
    required this.initialDefinition,
    this.existing,
    this.filterChoices = const <String>[],
    this.dark,
    this.flat,
    this.onEditRegion,
  });

  /// The definition the form opens on.
  final DepthLockGoalDefinition initialDefinition;

  /// The goal being revised, or null when creating. Its revision is what the
  /// save is pinned to, so a goal edited elsewhere meanwhile refuses this
  /// write rather than losing it.
  final DepthLockGoal? existing;

  /// Filter names from the active profile, offered when the operator
  /// overrides the one the reference frame's header carries.
  final List<String> filterChoices;

  /// What the calibration library matched, when it matched anything.
  final DepthLockMasterChoice? dark;
  final DepthLockMasterChoice? flat;

  /// Re-open the region tool on this goal's rectangles. Null when the editor
  /// was opened from a freshly drawn region, which already is the tool's
  /// output.
  final VoidCallback? onEditRegion;

  bool get isRevision => existing != null;

  /// Show the editor and return the goal that was written, or null when the
  /// operator backed out.
  static Future<DepthLockGoal?> show(
    BuildContext context, {
    required DepthLockGoalDefinition initialDefinition,
    DepthLockGoal? existing,
    List<String> filterChoices = const <String>[],
    DepthLockMasterChoice? dark,
    DepthLockMasterChoice? flat,
    VoidCallback? onEditRegion,
  }) {
    return showDialog<DepthLockGoal>(
      context: context,
      builder: (_) => DepthLockGoalEditor(
        initialDefinition: initialDefinition,
        existing: existing,
        filterChoices: filterChoices,
        dark: dark,
        flat: flat,
        onEditRegion: onEditRegion,
      ),
    );
  }

  @override
  ConsumerState<DepthLockGoalEditor> createState() =>
      _DepthLockGoalEditorState();
}

String _fileName(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

class _DepthLockGoalEditorState extends ConsumerState<DepthLockGoalEditor> {
  late final TextEditingController _label = TextEditingController(
    text: widget.initialDefinition.label,
  );
  late final TextEditingController _floorSource = TextEditingController(
    text: widget.initialDefinition.measurement.systematicFloorSource,
  );

  late DepthLockMeasurement _measurement = widget.initialDefinition.measurement;
  late String _filterName = widget.initialDefinition.filterName;
  late int? _filterIndex = widget.initialDefinition.filterIndex;
  late DepthLockMasterChoice _dark = widget.dark ??
      DepthLockMasterChoice(path: widget.initialDefinition.darkPath);
  late DepthLockMasterChoice _flat = widget.flat ??
      DepthLockMasterChoice(path: widget.initialDefinition.flatPath);
  late double _temperatureTolerance =
      widget.initialDefinition.temperatureToleranceC;
  late bool _enabled = widget.initialDefinition.enabled;
  late bool _automaticCompletion = widget.initialDefinition.automaticCompletion;

  bool _overrideFilter = false;
  bool _advancedOpen = false;
  bool _derivationOpen = false;

  /// True once the operator has typed a floor of their own, or once the
  /// suggestion failed and there is nothing to fall back on. While it is
  /// false the derived floor owns both the value and the source note.
  bool _manualFloor = false;

  /// The derivation sentence the native side writes; a stored source that
  /// does not start with it was typed by the operator and is kept as theirs
  /// when a goal is reopened for revision.
  static const String _derivedSourcePrefix = 'Derived from the masters';

  DepthLockFloorSuggestion? _floor;
  String? _floorIssue;
  bool _floorInFlight = false;
  int _floorGeneration = 0;

  int? _apertureCount;
  String? _measurementIssue;
  int _checkGeneration = 0;

  String? _saveError;
  bool _saving = false;

  double get _pixelScale => widget.initialDefinition.reference.pixelScaleArcsec;

  @override
  void initState() {
    super.initState();
    // A revision reopened with a floor the operator typed keeps it as theirs;
    // a fresh goal (seed defaults) and a derived floor defer to the masters.
    final storedSource =
        widget.initialDefinition.measurement.systematicFloorSource;
    _manualFloor = widget.isRevision &&
        storedSource.trim().isNotEmpty &&
        !storedSource.startsWith(_derivedSourcePrefix);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _check();
      _suggestFloor();
    });
  }

  @override
  void dispose() {
    _label.dispose();
    _floorSource.dispose();
    super.dispose();
  }

  /// Ask the native validator what the current measurement yields.
  ///
  /// Runs on every committed edit rather than only on save, so a region that
  /// cannot hold sixteen apertures at the chosen preset says so while the
  /// preset can still be changed.
  Future<void> _check() async {
    final int generation = ++_checkGeneration;
    final backend = ref.read(depthLockBackendProvider);
    try {
      final cells = await backend.checkDepthLockMeasurement(_measurement);
      if (!mounted || generation != _checkGeneration) return;
      setState(() {
        _apertureCount = cells;
        _measurementIssue = null;
      });
    } catch (error) {
      if (!mounted || generation != _checkGeneration) return;
      setState(() {
        _apertureCount = null;
        _measurementIssue = depthLockErrorMessage(error);
      });
    }
  }

  /// Derive the calibration error floor from the reference sub and the two
  /// masters at the current aperture.
  ///
  /// The floor depends on the aperture — it is a per-cell quantity — so this
  /// re-runs whenever the scale or either master changes, not only on open.
  Future<void> _suggestFloor() async {
    if (!_dark.isSet || !_flat.isSet) {
      // Nothing to derive from yet. This is not an override: the moment
      // both masters are chosen the suggestion runs and, unless the
      // operator has typed a floor, takes over.
      setState(() {
        _floor = null;
        _floorIssue = null;
      });
      return;
    }
    final int generation = ++_floorGeneration;
    setState(() => _floorInFlight = true);
    final backend = ref.read(depthLockBackendProvider);
    try {
      final suggestion = await backend.suggestDepthLockFloor(
        referencePath: widget.initialDefinition.referencePath,
        darkPath: _dark.path,
        flatPath: _flat.path,
        scaleArcsec: _measurement.scaleArcsec,
        pixelScaleArcsec: _pixelScale > 0 ? _pixelScale : null,
      );
      if (!mounted || generation != _floorGeneration) return;
      setState(() {
        _floorInFlight = false;
        _floor = suggestion;
        _floorIssue = null;
        if (!_manualFloor) _applySuggestion(suggestion);
      });
    } catch (error) {
      if (!mounted || generation != _floorGeneration) return;
      setState(() {
        _floorInFlight = false;
        _floor = null;
        _floorIssue = depthLockErrorMessage(error);
        // Nothing can be derived, so the operator has to supply the number
        // and say where it came from. Advanced opens so the two fields are
        // in front of them rather than behind a disclosure.
        _manualFloor = true;
        _advancedOpen = true;
      });
    }
  }

  void _applySuggestion(DepthLockFloorSuggestion suggestion) {
    _measurement = _measurement.copyWith(
      systematicFloorAdu: suggestion.floorAdu,
      systematicFloorSource: suggestion.source,
    );
    _floorSource.text = suggestion.source;
  }

  void _updateMeasurement(
    DepthLockMeasurement next, {
    bool refreshFloor = false,
  }) {
    setState(() => _measurement = next);
    _check();
    if (refreshFloor) _suggestFloor();
  }

  void _selectPreset(DepthLockPreset preset) {
    _updateMeasurement(
      depthLockApplyPreset(
        _measurement,
        preset,
        pixelScaleArcsec: _pixelScale,
      ),
      refreshFloor: true,
    );
  }

  DepthLockGoalDefinition _definition() => widget.initialDefinition.copyWith(
        label: _label.text.trim(),
        filterName: _filterName,
        filterIndex: _filterIndex,
        darkPath: _dark.path,
        flatPath: _flat.path,
        temperatureToleranceC: _temperatureTolerance,
        measurement: _measurement.copyWith(
          systematicFloorSource: _floorSource.text.trim(),
        ),
        enabled: _enabled,
        automaticCompletion: _automaticCompletion,
      );

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final notifier = ref.read(depthLockGoalsProvider.notifier);
    try {
      final definition = _definition();
      final goal = widget.isRevision
          ? await notifier.reviseGoal(
              goalId: widget.existing!.id,
              expectedRevision: widget.existing!.revision,
              definition: definition,
            )
          : await notifier.createGoal(definition);
      if (!mounted) return;
      Navigator.of(context).pop(goal);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = depthLockErrorMessage(error);
      });
    }
  }

  Future<void> _pickMaster({required bool dark}) async {
    final picker = ref.read(depthLockFilePickerProvider);
    final path = await picker(
      dark ? 'Select master dark' : 'Select master flat',
    );
    if (path == null || path.isEmpty || !mounted) return;
    setState(() {
      if (dark) {
        _dark = _dark.withPath(path);
      } else {
        _flat = _flat.withPath(path);
      }
    });
    await _suggestFloor();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final definition = widget.initialDefinition;
    final reference = definition.reference;
    final acquisition = definition.acquisition;
    final DepthLockPreset? preset = depthLockPresetOf(
      _measurement,
      pixelScaleArcsec: _pixelScale,
    );
    final bool floorReady = _manualFloor
        ? _measurement.systematicFloorAdu > 0 &&
            _floorSource.text.trim().isNotEmpty
        : _floor != null;
    final bool ready = _measurementIssue == null &&
        _apertureCount != null &&
        _label.text.trim().isNotEmpty &&
        _dark.isSet &&
        _flat.isSet &&
        floorReady;

    return SkotiqDialog(
      title: widget.isRevision ? 'Edit DepthLock goal' : 'New DepthLock goal',
      icon: SkotiqIcons.target,
      width: SkotiqDialog.widthForm,
      closeEnabled: !_saving,
      actions: <Widget>[
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: widget.isRevision ? 'Save new revision' : 'Create goal',
          icon: SkotiqIcons.check,
          size: ButtonSize.small,
          isLoading: _saving,
          onPressed: ready && !_saving ? _save : null,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.isRevision) ...<Widget>[
            SkotiqBanner(
              title: 'Saving this starts the evidence over',
              message:
                  'A revision is a new definition, so the exposures collected '
                  'for revision ${widget.existing!.revision} are archived and '
                  'this goal begins again from zero. A Smart Exposure plan '
                  'bound to the old revision runs to its count until you '
                  'rebind it.',
              tone: BannerTone.warning,
              icon: SkotiqIcons.warning,
            ),
            const SizedBox(height: SidePanel.sectionGap),
          ],
          const SectionTitle(icon: SkotiqIcons.tag, title: 'Goal'),
          FormRow(
            label: 'Name',
            child: Semantics(
              label: 'Goal name',
              child: SkotiqTextField(
                controller: _label,
                hint: 'What this region is',
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Filter',
            help: _overrideFilter
                ? 'Only frames taken through this filter become evidence.'
                : 'Read from the reference frame\'s header.',
            child: _overrideFilter && widget.filterChoices.isNotEmpty
                ? Semantics(
                    label: 'Filter',
                    child: SkotiqDropdown(
                      value: widget.filterChoices.contains(_filterName)
                          ? _filterName
                          : null,
                      items: widget.filterChoices,
                      isExpanded: true,
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _filterName = value;
                          _filterIndex = widget.filterChoices.indexOf(value);
                        });
                      },
                    ),
                  )
                : Row(
                    children: <Widget>[
                      Expanded(child: ReadOnlyField(value: _filterName)),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      SkotiqButton(
                        label: 'Change',
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                        semanticsHint:
                            'Choose a different filter than the reference '
                            'frame recorded',
                        onPressed: widget.filterChoices.isEmpty
                            ? null
                            : () => setState(() => _overrideFilter = true),
                      ),
                    ],
                  ),
          ),
          if (widget.onEditRegion != null) ...<Widget>[
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Region',
              help: 'Reopens the two boxes on the frame so you can adjust '
                  'them.',
              child: Align(
                alignment: Alignment.centerLeft,
                child: SkotiqButton(
                  label: 'Edit region',
                  icon: SkotiqIcons.crosshair,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onEditRegion!();
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: SidePanel.sectionGap),
          const SectionTitle(
            icon: SkotiqIcons.target,
            title: 'How faint',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              label: 'Depth preset',
              child: SegmentedControl(
                segments: <String>[
                  for (final value in DepthLockPreset.values) value.label,
                ],
                selectedIndex: preset == null ? -1 : preset.index,
                onSelected: (index) =>
                    _selectPreset(DepthLockPreset.values[index]),
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            preset?.description ??
                'Custom: ${_measurement.scaleArcsec.toStringAsFixed(1)}″ '
                    'squares, signal-to-noise '
                    '${_measurement.threshold.toStringAsFixed(1)}.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _MeasurementVerdict(
            apertureCount: _apertureCount,
            issue: _measurementIssue,
          ),
          const SizedBox(height: SidePanel.sectionGap),
          const SectionTitle(
            icon: SkotiqIcons.layers,
            title: 'Calibration',
          ),
          _MasterRow(
            label: 'Master dark',
            choice: _dark,
            onBrowse: () => _pickMaster(dark: true),
          ),
          const SizedBox(height: FormRow.rowGap),
          _MasterRow(
            label: 'Master flat',
            choice: _flat,
            onBrowse: () => _pickMaster(dark: false),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _FloorLine(
            suggestion: _floor,
            issue: _floorIssue,
            inFlight: _floorInFlight,
            manual: _manualFloor,
            manualAdu: _measurement.systematicFloorAdu,
            expanded: _derivationOpen,
            onToggleDerivation: () =>
                setState(() => _derivationOpen = !_derivationOpen),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'DepthLock measures signed ADU, so it needs Skotiq-format '
            'masters: FRAMETYP=MASTER, a flat normalised to unit mean, and at '
            'least 8 frames behind each one.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: SidePanel.sectionGap),
          const SectionTitle(
            icon: SkotiqIcons.settings,
            title: 'Automation',
          ),
          SkotiqSwitchRow(
            label: 'Collect evidence',
            subtitle:
                'Offer every matching light this goal\'s setup produces to the '
                'measurement.',
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          SkotiqSwitchRow(
            label: 'Automatic completion',
            subtitle:
                'Let a bound Smart Exposure plan finish this filter early once '
                'the goal is reliably achieved; count, time, visibility and '
                'safety limits still apply.',
            value: _automaticCompletion,
            onChanged: (value) => setState(() => _automaticCompletion = value),
          ),
          const SizedBox(height: SidePanel.sectionGap),
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              toggled: _advancedOpen,
              child: SkotiqButton(
                label: 'Advanced',
                icon: _advancedOpen
                    ? SkotiqIcons.chevronUp
                    : SkotiqIcons.chevronDown,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                semanticsHint:
                    'Aperture, threshold, coverage, error floor and the '
                    'reference frame this goal is anchored to',
                onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
              ),
            ),
          ),
          if (_advancedOpen) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceMd),
            FormRow(
              label: 'Aperture',
              help: _pixelScale > 0
                  ? '${(_measurement.scaleArcsec / _pixelScale).toStringAsFixed(1)} '
                      'native pixels across (the sampler accepts 4 to 64)'
                  : null,
              child: InlineNumberField(
                value: _measurement.scaleArcsec.toStringAsFixed(1),
                suffix: 'arcsec',
                semanticLabel: 'Aperture size in arcseconds',
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed == null || parsed <= 0) return;
                  _updateMeasurement(
                    _measurement.copyWith(scaleArcsec: parsed),
                    refreshFloor: true,
                  );
                },
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Signal-to-noise',
              help: 'The ratio the weakest quarter of the area must reach: its '
                  'light above the sky divided by the noise in that '
                  'measurement, per square. 3 is "something is there", 5 is '
                  'clearly present, 10 is clean. 3 to 100. '
                  '${DepthLockPreset.scalingNote}',
              child: InlineNumberField(
                value: _measurement.threshold.toStringAsFixed(1),
                semanticLabel: 'Signal-to-noise threshold',
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed == null) return;
                  _updateMeasurement(
                    _measurement.copyWith(threshold: parsed),
                  );
                },
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Coverage',
              help: 'How much of the region must stay measurable, 90 to 100%.',
              child: InlineNumberField(
                value: (_measurement.minCoverage * 100).toStringAsFixed(0),
                suffix: '%',
                semanticLabel: 'Minimum coverage percent',
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed == null) return;
                  _updateMeasurement(
                    _measurement.copyWith(minCoverage: parsed / 100.0),
                  );
                },
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Error floor',
              help: 'Calibration error that never averages down with more '
                  'exposures. Must be greater than zero.',
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: InlineNumberField(
                      value: _measurement.systematicFloorAdu.toStringAsFixed(2),
                      suffix: 'ADU',
                      semanticLabel: 'Systematic error floor in ADU',
                      onChanged: (value) {
                        final parsed = double.tryParse(value);
                        if (parsed == null) return;
                        setState(() {
                          _manualFloor = true;
                          _measurement = _measurement.copyWith(
                            systematicFloorAdu: parsed,
                          );
                        });
                        _check();
                      },
                    ),
                  ),
                  if (_floor != null) ...<Widget>[
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    SkotiqButton(
                      label: 'Use suggested',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      semanticsHint:
                          'Go back to the floor derived from your masters, '
                          '${_floor!.floorAdu.toStringAsFixed(2)} ADU',
                      onPressed: () {
                        setState(() {
                          _manualFloor = false;
                          _applySuggestion(_floor!);
                        });
                        _check();
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Floor source',
              help: 'Where that number came from. Recorded with the goal.',
              child: Semantics(
                label: 'Error floor source',
                child: SkotiqTextField(
                  controller: _floorSource,
                  enabled: _manualFloor,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Temp. tolerance',
              help: 'How far a later frame\'s sensor temperature may differ.',
              child: InlineNumberField(
                value: _temperatureTolerance.toStringAsFixed(1),
                suffix: '°C',
                semanticLabel: 'Temperature tolerance in degrees Celsius',
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed == null) return;
                  setState(() => _temperatureTolerance = parsed);
                },
              ),
            ),
            const SizedBox(height: SidePanel.sectionGap),
            const SectionTitle(
              icon: SkotiqIcons.image,
              title: 'Reference',
            ),
            FormRow(
              label: 'Frame',
              child: ReadOnlyField(
                value: definition.referencePath,
                mono: true,
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            KeyValueList(
              rows: <(String, String)>[
                ('Size', '${reference.width} × ${reference.height} px'),
                ('Pixel scale', '${_pixelScale.toStringAsFixed(2)} arcsec/px'),
              ],
            ),
            const SizedBox(height: SidePanel.sectionGap),
            const SectionTitle(
              icon: SkotiqIcons.camera,
              title: 'Acquisition',
            ),
            KeyValueList(
              rows: <(String, String)>[
                ('Camera', acquisition.instrument),
                (
                  'Exposure',
                  '${acquisition.exposureSecs.toStringAsFixed(1)} s',
                ),
                (
                  'Gain / offset',
                  '${acquisition.gain?.toString() ?? '—'} / '
                      '${acquisition.offset?.toString() ?? '—'}',
                ),
                ('Binning', '${acquisition.binX}×${acquisition.binY}'),
                (
                  'Sensor temperature',
                  acquisition.ccdTempC == null
                      ? '—'
                      : '${acquisition.ccdTempC!.toStringAsFixed(1)} °C',
                ),
              ],
            ),
          ],
          if (_saveError != null) ...<Widget>[
            const SizedBox(height: SidePanel.sectionGap),
            SkotiqBanner(
              title: widget.isRevision
                  ? 'The revision was refused'
                  : 'The goal was not created',
              message: _saveError!,
              tone: BannerTone.error,
              icon: SkotiqIcons.error,
            ),
          ],
        ],
      ),
    );
  }
}

/// The live answer from the native validator: an aperture count, or the
/// reason the geometry is refused, in the engine's own words.
class _MeasurementVerdict extends StatelessWidget {
  const _MeasurementVerdict({required this.apertureCount, required this.issue});

  final int? apertureCount;
  final String? issue;

  @override
  Widget build(BuildContext context) {
    if (issue != null) {
      return SkotiqBanner(
        title: 'This region cannot be measured',
        message: issue!,
        tone: BannerTone.error,
        icon: SkotiqIcons.error,
      );
    }
    if (apertureCount == null) {
      return const SizedBox.shrink();
    }
    return SkotiqInlineBanner(
      message: '$apertureCount apertures across the region.',
      severity: SkotiqAlertSeverity.success,
    );
  }
}

/// The error floor as one read-only line, with its derivation one press away.
///
/// Read-only on purpose: the floor is the number that decides whether a
/// persistent calibration residual can pass for sky signal, and it is worth
/// far more measured from the operator's own masters than typed from memory.
/// Advanced still lets it be overridden, and this line keeps showing what the
/// masters said so an override is visibly an override.
class _FloorLine extends StatelessWidget {
  const _FloorLine({
    required this.suggestion,
    required this.issue,
    required this.inFlight,
    required this.manual,
    required this.manualAdu,
    required this.expanded,
    required this.onToggleDerivation,
  });

  final DepthLockFloorSuggestion? suggestion;
  final String? issue;
  final bool inFlight;
  final bool manual;
  final double manualAdu;
  final bool expanded;
  final VoidCallback onToggleDerivation;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    if (issue != null) {
      return SkotiqBanner(
        title: 'The error floor could not be derived',
        message:
            '$issue Enter a floor and say where it came from under Advanced.',
        tone: BannerTone.warning,
        icon: SkotiqIcons.warning,
      );
    }
    if (inFlight && suggestion == null) {
      return Text(
        'Deriving the error floor from your masters…',
        style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
      );
    }
    if (suggestion == null) {
      return Text(
        'Choose both masters and the error floor is derived from them.',
        style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
      );
    }

    final value = suggestion!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                manual
                    ? 'Error floor ${manualAdu.toStringAsFixed(2)} ADU — '
                        'yours (masters suggest '
                        '${value.floorAdu.toStringAsFixed(2)})'
                    : 'Error floor ${value.floorAdu.toStringAsFixed(2)} ADU — '
                        'from your masters',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            SkotiqButton(
              label: expanded ? 'Hide working' : 'Show working',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              semanticsHint: 'How the error floor was derived',
              onPressed: onToggleDerivation,
            ),
          ],
        ),
        if (expanded) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceSm),
          KeyValueList(
            rows: <(String, String)>[
              (
                'Dark noise',
                '${value.darkNoiseAdu.toStringAsFixed(3)} ADU/px',
              ),
              (
                'Flat noise',
                '${(value.flatRelativeNoise * 1000).toStringAsFixed(2)} '
                    'per 1000',
              ),
              ('Sky level', '${value.skyAdu.toStringAsFixed(1)} ADU/px'),
              (
                'Aperture',
                '${value.aperturePixels.toStringAsFixed(1)} px across',
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            value.source,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// One master, described by what went into it. The path is a tooltip, not the
/// line: an operator recognises "20 × 120 s at −10 °C", not a directory.
class _MasterRow extends StatelessWidget {
  const _MasterRow({
    required this.label,
    required this.choice,
    required this.onBrowse,
  });

  final String label;
  final DepthLockMasterChoice choice;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    if (!choice.isSet) {
      return FormRow(
        label: label,
        help: choice.unmatchedReason ??
            'Your calibration library has nothing matching this sub.',
        child: Row(
          children: <Widget>[
            const Expanded(
              child: ReadOnlyField(value: 'Not set', muted: true),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqButton(
              label: 'Choose…',
              icon: SkotiqIcons.folderOpen,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              semanticsHint: 'Choose the $label file',
              onPressed: onBrowse,
            ),
          ],
        ),
      );
    }

    return FormRow(
      label: label,
      child: Row(
        children: <Widget>[
          Expanded(
            child: SkotiqTooltip(
              message: choice.path,
              child: Text(
                choice.summary == null
                    ? '${_fileName(choice.path)} · chosen by you'
                    : '${choice.summary} · matched to this sub',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Change…',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            semanticsHint: 'Choose a different $label',
            onPressed: onBrowse,
          ),
        ],
      ),
    );
  }
}
