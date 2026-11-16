import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/held_future.dart';
import 'filter_set_picker.dart';
import 'sensitivity_field.dart';

enum AutoBuildEnd {
  integration('Integration budget'),
  astronomical('Astronomical dawn'),
  nautical('Nautical dawn'),
  civil('Civil dawn'),
  sunrise('Sunrise');

  const AutoBuildEnd(this.label);
  final String label;
}

class AutoBuildOptions {
  final FilterSet filterSet;

  /// One exposure per filter in turn (true), or each filter's frames
  /// together.
  final bool rotateFilters;
  final AutoBuildEnd end;
  final double hours;
  final bool useCalculator;
  final Map<String, double> exposures;
  final int? gain;
  final int? offset;
  final bool shutdown;

  const AutoBuildOptions({
    required this.filterSet,
    required this.rotateFilters,
    this.end = AutoBuildEnd.astronomical,
    this.hours = 4,
    this.useCalculator = false,
    this.exposures = const {},
    this.gain,
    this.offset,
    this.shutdown = true,
  });
}

/// A single recipe review shared by Plan and Framing. Does not run equipment.
///
/// The recipe opens on [filterSet] when given (the set the planner's picker
/// shows), else on the set remembered for [target] or Skotiq's choice. A
/// set picked here is remembered for the target when the sequence is built.
Future<AutoBuildOptions?> showAutoBuildOptions(
  BuildContext context,
  WidgetRef ref,
  TargetSuggestion target, {
  FilterSet? filterSet,
}) async {
  final profile = ref.read(activeEquipmentProfileProvider);
  if (profile == null) {
    throw const SmartNightBuildException('Select an equipment profile first.');
  }
  final host = ref.backendScope();
  final filters = ref.read(effectiveFiltersProvider);
  final camera = ref.read(cameraStateProvider);
  final cameraName = camera.connectionState == DeviceConnectionState.connected
      ? camera.deviceName
      : profile.cameraName;
  final cameraKey = CameraSensorDatabase.normalize(
      cameraName ?? profile.cameraId ?? 'unknown');
  final key = 'auto_build.recipe.${profile.id}.$cameraKey';
  await ref.read(hardwarePresetsServiceProvider.notifier).loaded;
  final preset = ref
      .read(hardwarePresetsServiceProvider)
      .matchCameraByName(cameraName, exactOnly: true);
  final dao = ref.read(settingsDaoProvider);
  final raw = await dao.getSetting(key);
  final filterChoice = await readHeld(ref, targetFilterChoiceProvider(target));
  final initialSet = filterSet ??
      await readHeld<FilterSet>(ref, targetFilterSetProvider(target));
  final exposureContext =
      await readHeld(ref, smartNightExposureContextProvider);
  final calculatedSeconds = _calculatedSubLengths(
    ref.read(smartNightServiceProvider),
    profile.copyWith(cameraName: cameraName),
    smartNightPlanningFilters(filters),
    exposureContext,
  );
  if (!context.mounted ||
      (host.isStale ||
          ref.read(activeEquipmentProfileProvider)?.id != profile.id ||
          ref.read(cameraStateProvider).deviceId != camera.deviceId)) {
    return null;
  }
  final saved = raw == null
      ? <String, dynamic>{}
      : jsonDecode(raw) as Map<String, dynamic>;
  final result = await showDialog<AutoBuildOptions>(
    context: context,
    builder: (_) => AutoBuildOptionsDialog(
      profile: profile,
      cameraName: cameraName,
      cameraPreset: preset,
      sensitivity: ref.read(cameraSensitivityProvider),
      filters: filters,
      filterChoice: filterChoice,
      initialSet: initialSet,
      target: target,
      saved: saved,
      calculatedSeconds: calculatedSeconds,
      onSave: (recipe) => dao.setSetting(key, jsonEncode(recipe)),
      onFilterSetChosen: (set) => ref
          .read(filterSetPreferencesProvider.notifier)
          .choose(target, set, recommended: filterChoice.recommended),
    ),
  );
  if (!context.mounted ||
      (host.isStale ||
          ref.read(activeEquipmentProfileProvider)?.id != profile.id ||
          ref.read(cameraStateProvider).deviceId != camera.deviceId)) {
    return null;
  }
  return result;
}

/// The exposure calculator's sub length for each of [filters], the length
/// the recipe fills in for a filter it has no length for. Empty when the
/// profile lacks the optics or pixel size the calculator needs; the recipe
/// then falls back to its fixed lengths.
Map<String, double> _calculatedSubLengths(
  SmartNightService service,
  EquipmentProfileModel profile,
  List<String> filters,
  SmartNightExposureContext? exposureContext,
) {
  try {
    return {
      for (final filter in filters)
        filter: service
            .smartExposureRows(
              profile: profile,
              filterSet: FilterSet.single(filter),
              plannedSecs: 3600,
              exposureContext: exposureContext,
            )
            .single
            .durationSecs,
    };
  } on SmartNightBuildException {
    return const {};
  }
}

class AutoBuildOptionsDialog extends StatefulWidget {
  final EquipmentProfileModel profile;
  final String? cameraName;
  final CameraDefaultsPreset? cameraPreset;

  /// The camera's gain or ISO range: a DSLR's recipe asks for ISO.
  final ExposureSensitivity sensitivity;
  final List<String> filters;

  /// Skotiq's filter choice for [target] on this rig.
  final SmartNightFilterChoice filterChoice;

  /// The set the recipe opens on.
  final FilterSet initialSet;
  final TargetSuggestion target;
  final Map<String, dynamic> saved;
  final Future<void> Function(Map<String, dynamic>) onSave;

  /// Remembers the set the sequence was built with for [target].
  final Future<void> Function(FilterSet) onFilterSetChosen;

  /// The exposure calculator's sub length per filter, for a filter the saved
  /// recipe has no length for.
  final Map<String, double> calculatedSeconds;

  const AutoBuildOptionsDialog(
      {super.key,
      required this.profile,
      this.cameraName,
      this.cameraPreset,
      this.sensitivity = const GainSensitivity(),
      required this.filters,
      required this.filterChoice,
      required this.initialSet,
      required this.target,
      required this.saved,
      this.calculatedSeconds = const {},
      required this.onSave,
      required this.onFilterSetChosen});

  @override
  State<AutoBuildOptionsDialog> createState() => _AutoBuildOptionsDialogState();
}

class _AutoBuildOptionsDialogState extends State<AutoBuildOptionsDialog> {
  final _form = GlobalKey<FormState>();
  final _durations = <String, TextEditingController>{};
  late FilterSet _set;
  late bool _rotate;
  late AutoBuildEnd _end;
  late bool _calculator;
  late bool _shutdown;
  late TextEditingController _gain;
  late TextEditingController _offset;
  late TextEditingController _hours;
  bool _saving = false;
  String? _error;
  late Map<String, dynamic> _captureSettings;

  @override
  void initState() {
    super.initState();
    _set = widget.initialSet;
    _rotate = smartNightRotatesFilters(widget.profile);
    _end = AutoBuildEnd.values.firstWhere((e) => e.name == widget.saved['end'],
        orElse: () => AutoBuildEnd.astronomical);
    _calculator = widget.saved['calculator'] == true;
    _shutdown = widget.saved['shutdown'] != false;
    _captureSettings = Map<String, dynamic>.from(
        widget.saved['captureSettings'] as Map<String, dynamic>? ?? {});
    _gain = TextEditingController();
    _offset = TextEditingController();
    _loadCaptureSettings();
    _hours =
        TextEditingController(text: (widget.saved['hours'] ?? 4).toString());
    final savedExposures =
        widget.saved['exposures'] as Map<String, dynamic>? ?? {};
    for (final filter in smartNightPlanningFilters(widget.filters)) {
      final spec = FilterExposureSpec.fromName(filter);
      final num seconds = savedExposures[filter] as num? ??
          widget.calculatedSeconds[filter]?.round() ??
          const SmartNightSettings().defaultFrameDurationSecs[spec.name] ??
          180;
      // Whole seconds read as "300", not "300.0".
      _durations[filter] = TextEditingController(
          text: seconds == seconds.roundToDouble()
              ? '${seconds.round()}'
              : '$seconds');
    }
  }

  @override
  void dispose() {
    for (final c in [..._durations.values, _gain, _offset, _hours]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _filters => _set.filters;

  void _choose(FilterSet set) {
    _rememberCaptureSettings();
    setState(() {
      _set = set;
      for (final filter in set.filters) {
        _durations.putIfAbsent(
            filter,
            () => TextEditingController(
                text: '${(widget.calculatedSeconds[filter] ?? 180).round()}'));
      }
      _loadCaptureSettings();
    });
  }

  CaptureFilterGroup get _filterGroup => captureFilterGroup(_filters.first);

  void _rememberCaptureSettings() {
    _captureSettings[_filterGroup.name] = {
      'gain': int.tryParse(_gain.text.trim()),
      'offset': int.tryParse(_offset.text.trim()),
    };
  }

  void _loadCaptureSettings() {
    final defaults = resolveCameraCaptureDefaults(
        cameraName: widget.cameraName ?? widget.profile.cameraName,
        filterName: _filters.first,
        preset: widget.cameraPreset,
        profileGain: widget.profile.defaultGain,
        profileOffset: widget.profile.defaultOffset);
    final saved = _captureSettings[_filterGroup.name] as Map<String, dynamic>?;
    _gain.text = (saved?['gain'] ?? defaults.gain)?.toString() ?? '';
    _offset.text = (saved?['offset'] ?? defaults.offset)?.toString() ?? '';
  }

  Widget _number(String label, TextEditingController controller,
      {bool optional = false, bool integer = false}) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        errorMaxLines: 2,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (value) {
        if (optional && (value == null || value.trim().isEmpty)) return null;
        final number = double.tryParse(value ?? '');
        if (number == null ||
            !number.isFinite ||
            (optional ? number < 0 : number <= 0) ||
            (integer && number != number.roundToDouble())) {
          return 'Enter a valid ${integer ? 'whole number' : 'number'}';
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);
    final iso = widget.sensitivity is IsoSensitivity;
    final multiFilter = _filters.length > 1;
    return SkotiqDialog(
      title: 'Build sequence · ${widget.target.targetName}',
      closeEnabled: !_saving,
      actions: [
        SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: _saving ? null : () => Navigator.pop(context)),
        SkotiqButton(
            label: 'Build sequence',
            isLoading: _saving,
            onPressed: _saving ? null : _accept),
      ],
      child: Form(
          key: _form,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                    'Frame center: ${CoordinateFormat.raReadout(widget.target.raHours)} '
                    '${CoordinateFormat.decReadout(widget.target.decDegrees)}',
                    style: muted),
                const SizedBox(height: SkotiqTokens.spaceLg),
                FormRow(
                  label: 'Filters',
                  child: FilterSetPicker(
                    choice: widget.filterChoice,
                    value: _set,
                    onChanged: _choose,
                  ),
                ),
                if (multiFilter) ...[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  FormRow(
                    label: 'Order',
                    child: FilterOrderControl(
                      rotate: _rotate,
                      onChanged: (v) => setState(() => _rotate = v),
                    ),
                  ),
                ],
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqSwitchRow(
                    label: 'Calculate exposure lengths',
                    subtitle: 'Off uses your per-filter recipe below.',
                    value: _calculator,
                    onChanged: (v) => setState(() => _calculator = v)),
                if (!_calculator) ...[
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  for (final filter in _filters)
                    Padding(
                      key: ValueKey('recipe-exposure-$filter'),
                      padding:
                          const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
                      child: _number(
                          '${smartNightFilterLabel(filter)} exposure (seconds)',
                          _durations[filter]!),
                    ),
                ],
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                    '${widget.cameraName ?? widget.profile.cameraName ?? 'Equipment profile'} · ${_filterGroup.name} ${iso ? 'ISO' : 'gain / offset'}',
                    style: muted),
                const SizedBox(height: SkotiqTokens.spaceLg),
                LayoutBuilder(builder: (context, constraints) {
                  final gain = SensitivityField(
                    sensitivity: widget.sensitivity,
                    value: int.tryParse(_gain.text.trim()),
                    onChanged: (v) => setState(() => _gain.text = '$v'),
                    unsetHint: 'Camera default',
                    labelled: true,
                    gainField: (_) =>
                        _number('Gain', _gain, optional: true, integer: true),
                  );
                  if (!widget.sensitivity.hasOffset) return gain;
                  final offset =
                      _number('Offset', _offset, optional: true, integer: true);
                  if (constraints.maxWidth < 340) {
                    return Column(children: [
                      gain,
                      const SizedBox(height: SkotiqTokens.spaceLg),
                      offset,
                    ]);
                  }
                  return Row(children: [
                    Expanded(child: gain),
                    const SizedBox(width: SkotiqTokens.spaceLg),
                    Expanded(child: offset),
                  ]);
                }),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text('Leave blank to use camera defaults.', style: muted),
                const SizedBox(height: SkotiqTokens.space2xl),
                FormRow(
                  label: 'Image until',
                  child: SkotiqDropdown(
                    value: _end.name,
                    items: [for (final e in AutoBuildEnd.values) e.name],
                    itemLabels: [for (final e in AutoBuildEnd.values) e.label],
                    isExpanded: true,
                    onChanged: (name) {
                      final picked = AutoBuildEnd.values
                          .where((e) => e.name == name)
                          .firstOrNull;
                      if (picked != null) setState(() => _end = picked);
                    },
                  ),
                ),
                if (_end == AutoBuildEnd.integration) ...[
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  _number('Integration hours', _hours),
                ],
                const SizedBox(height: SkotiqTokens.spaceMd),
                Text(
                    'The target can finish earlier if it drops below your minimum altitude. Dawn times apply to this night.',
                    style: muted),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqSwitchRow(
                    label: 'Warm camera and park mount at the end',
                    subtitle:
                        'Park uses the mount driver’s configured park position.',
                    value: _shutdown,
                    onChanged: (v) => setState(() => _shutdown = v)),
                if (_error != null)
                  Text(_error!,
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.error)),
                const SizedBox(height: SkotiqTokens.spaceLg),
              ])),
    );
  }

  Future<void> _accept() async {
    if (!_form.currentState!.validate()) return;
    final options = AutoBuildOptions(
        filterSet: _set,
        rotateFilters: _rotate,
        end: _end,
        hours: double.tryParse(_hours.text) ?? 4,
        useCalculator: _calculator,
        exposures: {
          for (final f in _filters)
            f: double.tryParse(_durations[f]!.text) ?? 180
        },
        gain: int.tryParse(_gain.text.trim()),
        offset: widget.sensitivity.hasOffset
            ? int.tryParse(_offset.text.trim())
            : null,
        shutdown: _shutdown);
    _rememberCaptureSettings();
    setState(() => _saving = true);
    try {
      await widget.onSave({
        'end': _end.name,
        'hours': options.hours,
        'calculator': _calculator,
        'exposures': {
          for (final e in _durations.entries)
            if (double.tryParse(e.value.text) != null)
              e.key: double.parse(e.value.text)
        },
        'captureSettings': _captureSettings,
        'shutdown': _shutdown
      });
      await widget.onFilterSetChosen(_set);
      if (mounted) Navigator.pop(context, options);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save recipe: ${userFacingError(e)}';
        });
      }
    }
  }
}
