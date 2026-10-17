import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_core/nightshade_core.dart';
// ignore: implementation_imports
import 'package:nightshade_core/src/providers/hardware_presets_provider.dart';
import 'package:nightshade_ui/nightshade_ui.dart';

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
  final SmartNightStrategy strategy;
  final AutoBuildEnd end;
  final double hours;
  final bool useCalculator;
  final Map<String, double> exposures;
  final int? gain;
  final int? offset;
  final bool shutdown;

  const AutoBuildOptions({
    required this.strategy,
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
Future<AutoBuildOptions?> showAutoBuildOptions(
  BuildContext context,
  WidgetRef ref,
  TargetSuggestion target,
) async {
  final profile = ref.read(activeEquipmentProfileProvider);
  if (profile == null) {
    throw const SmartNightBuildException('Select an equipment profile first.');
  }
  final backend = ref.read(backendProvider);
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
  if (!context.mounted ||
      (!identical(backend, ref.read(backendProvider)) ||
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
      filters: filters,
      target: target,
      saved: saved,
      onSave: (recipe) => dao.setSetting(key, jsonEncode(recipe)),
    ),
  );
  if (!context.mounted ||
      (!identical(backend, ref.read(backendProvider)) ||
          ref.read(activeEquipmentProfileProvider)?.id != profile.id ||
          ref.read(cameraStateProvider).deviceId != camera.deviceId)) {
    return null;
  }
  return result;
}

class AutoBuildOptionsDialog extends StatefulWidget {
  final EquipmentProfileModel profile;
  final String? cameraName;
  final CameraDefaultsPreset? cameraPreset;
  final List<String> filters;
  final TargetSuggestion target;
  final Map<String, dynamic> saved;
  final Future<void> Function(Map<String, dynamic>) onSave;

  const AutoBuildOptionsDialog(
      {super.key,
      required this.profile,
      this.cameraName,
      this.cameraPreset,
      required this.filters,
      required this.target,
      required this.saved,
      required this.onSave});

  @override
  State<AutoBuildOptionsDialog> createState() => _AutoBuildOptionsDialogState();
}

class _AutoBuildOptionsDialogState extends State<AutoBuildOptionsDialog> {
  final _form = GlobalKey<FormState>();
  final _durations = <String, TextEditingController>{};
  late SmartNightStrategy _strategy;
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
    final strategyName =
        (widget.saved['strategies'] as Map<String, dynamic>?)?[_targetKey];
    _strategy = SmartNightStrategy.values.firstWhere(
        (s) =>
            s.name == strategyName &&
            resolveSmartNightFilterSet(
                    strategy: s,
                    availableFilters: smartNightPlanningFilters(widget.filters))
                .isNotEmpty,
        orElse: () => inferSmartNightStrategy(widget.target, widget.filters));
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
      final seconds = savedExposures[filter] ??
          const SmartNightSettings().defaultFrameDurationSecs[spec.name] ??
          180;
      _durations[filter] = TextEditingController(text: '$seconds');
    }
  }

  @override
  void dispose() {
    for (final c in [..._durations.values, _gain, _offset, _hours]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _targetKey => widget.target.catalogId ?? widget.target.targetName;

  List<String> get _filters => resolveSmartNightFilterSet(
      strategy: _strategy,
      availableFilters: smartNightPlanningFilters(widget.filters));

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
    return AlertDialog(
      title: Text('Build sequence · ${widget.target.targetName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
              key: _form,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                        'Frame center: ${widget.target.raHours.toStringAsFixed(5)}h, ${widget.target.decDegrees.toStringAsFixed(4)}°'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<SmartNightStrategy>(
                      isExpanded: true,
                      initialValue: _strategy,
                      decoration: const InputDecoration(
                        labelText: 'Filters',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      ),
                      items: SmartNightStrategy.values
                          .where((s) => resolveSmartNightFilterSet(
                                  strategy: s,
                                  availableFilters:
                                      smartNightPlanningFilters(widget.filters))
                              .isNotEmpty)
                          .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(switch (s) {
                                SmartNightStrategy.autoLrgb =>
                                  'LRGB · more luminance',
                                SmartNightStrategy.monoLrgb =>
                                  'LRGB · equal time',
                                SmartNightStrategy.narrowbandHoo =>
                                  'HOO · Ha + OIII',
                                SmartNightStrategy.narrowbandSho =>
                                  'SHO · SII + Ha + OIII',
                                SmartNightStrategy.oscOneShot =>
                                  'Single filter / OSC',
                              })))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          _rememberCaptureSettings();
                          setState(() {
                            _strategy = v;
                            _loadCaptureSettings();
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                        'Target type: ${widget.target.objectType ?? 'unknown'} · check the filter choice before building.'),
                    const SizedBox(height: 16),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Calculate exposure lengths'),
                        subtitle: const Text(
                            'Off uses your per-filter recipe below.'),
                        value: _calculator,
                        onChanged: (v) => setState(() => _calculator = v)),
                    if (!_calculator) ...[
                      const SizedBox(height: 16),
                      for (final filter in _filters)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _number(
                              '${smartNightFilterLabel(filter)} exposure (seconds)',
                              _durations[filter]!),
                        ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                        '${widget.cameraName ?? widget.profile.cameraName ?? 'Equipment profile'} · ${_filterGroup.name} gain / offset'),
                    const SizedBox(height: 16),
                    LayoutBuilder(builder: (context, constraints) {
                      final gain =
                          _number('Gain', _gain, optional: true, integer: true);
                      final offset = _number('Offset', _offset,
                          optional: true, integer: true);
                      if (constraints.maxWidth < 340) {
                        return Column(children: [
                          gain,
                          const SizedBox(height: 16),
                          offset,
                        ]);
                      }
                      return Row(children: [
                        Expanded(child: gain),
                        const SizedBox(width: 16),
                        Expanded(child: offset),
                      ]);
                    }),
                    const SizedBox(height: 8),
                    const Text('Leave blank to use camera defaults.'),
                    const SizedBox(height: 24),
                    DropdownButtonFormField<AutoBuildEnd>(
                      isExpanded: true,
                      initialValue: _end,
                      decoration: const InputDecoration(
                        labelText: 'Image until',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      ),
                      items: AutoBuildEnd.values
                          .map((e) =>
                              DropdownMenuItem(value: e, child: Text(e.label)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _end = v);
                      },
                    ),
                    if (_end == AutoBuildEnd.integration) ...[
                      const SizedBox(height: 16),
                      _number('Integration hours', _hours),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                        'The target can finish earlier if it drops below your minimum altitude. Dawn times apply to this night.'),
                    const SizedBox(height: 16),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title:
                            const Text('Warm camera and park mount at the end'),
                        subtitle: const Text(
                            'Park uses the mount driver’s configured park position.'),
                        value: _shutdown,
                        onChanged: (v) => setState(() => _shutdown = v)),
                    if (_error != null)
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                  ])),
        ),
      ),
      actions: [
        NightshadeButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: _saving ? null : () => Navigator.pop(context)),
        NightshadeButton(
            label: 'Build sequence',
            isLoading: _saving,
            onPressed: _saving ? null : _accept),
      ],
    );
  }

  Future<void> _accept() async {
    if (!_form.currentState!.validate()) return;
    final options = AutoBuildOptions(
        strategy: _strategy,
        end: _end,
        hours: double.tryParse(_hours.text) ?? 4,
        useCalculator: _calculator,
        exposures: {
          for (final f in _filters)
            f: double.tryParse(_durations[f]!.text) ?? 180
        },
        gain: int.tryParse(_gain.text.trim()),
        offset: int.tryParse(_offset.text.trim()),
        shutdown: _shutdown);
    _rememberCaptureSettings();
    setState(() => _saving = true);
    try {
      await widget.onSave({
        'strategies': {
          ...?widget.saved['strategies'] as Map<String, dynamic>?,
          _targetKey: _strategy.name
        },
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
      if (mounted) Navigator.pop(context, options);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save recipe: $e';
        });
      }
    }
  }
}
