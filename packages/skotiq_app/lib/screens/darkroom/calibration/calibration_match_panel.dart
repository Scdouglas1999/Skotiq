import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'calibration_panel.dart';

/// Matching-preview pane: enter a light-frame context, see the auto-pick per
/// type with scores, reasons, and warnings.
class CalibrationMatchPanel extends ConsumerStatefulWidget {
  /// Download + merge a REMOTE shared candidate the preview surfaced.
  final Future<void> Function(CalibrationMasterRecord) onAccept;

  const CalibrationMatchPanel({super.key, required this.onAccept});

  @override
  ConsumerState<CalibrationMatchPanel> createState() =>
      _CalibrationMatchPanelState();
}

class _CalibrationMatchPanelState extends ConsumerState<CalibrationMatchPanel> {
  final _gain = TextEditingController(text: '100');
  final _offset = TextEditingController(text: '50');
  final _exposure = TextEditingController(text: '300');
  final _temp = TextEditingController(text: '-10');
  final _filter = TextEditingController();
  final _binX = TextEditingController(text: '1');
  final _binY = TextEditingController(text: '1');
  // Camera + sensor geometry feed the quality gate: a shared master is only
  // foldable when shot on the same camera + sensor dimensions, so leaving these
  // blank refuses every remote candidate (the gate fails closed).
  final _camera = TextEditingController();
  final _sensorWidth = TextEditingController();
  final _sensorHeight = TextEditingController();
  final _opticalTrain = TextEditingController();

  bool _running = false;
  bool _more = false;
  Object? _error;
  CalibrationMatchSet? _result;

  @override
  void dispose() {
    _gain.dispose();
    _offset.dispose();
    _exposure.dispose();
    _temp.dispose();
    _filter.dispose();
    _binX.dispose();
    _binY.dispose();
    _camera.dispose();
    _sensorWidth.dispose();
    _sensorHeight.dispose();
    _opticalTrain.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final lightContext = _validatedContext();
    if (lightContext == null) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final result =
          await ref.read(calibrationLibraryServiceProvider).match(lightContext);
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  LightFrameContext? _validatedContext() {
    final errors = <String>[];

    int? wholeNumber(
      TextEditingController controller,
      String label, {
      required int minimum,
      int? maximum,
      bool optional = false,
    }) {
      final text = controller.text.trim();
      if (optional && text.isEmpty) return null;
      final value = int.tryParse(text);
      if (value == null ||
          value < minimum ||
          (maximum != null && value > maximum)) {
        final range =
            maximum == null ? '$minimum or greater' : '$minimum–$maximum';
        errors.add('$label must be a whole number ($range).');
        return null;
      }
      return value;
    }

    final gain = wholeNumber(_gain, 'Gain', minimum: 0);
    final offset = wholeNumber(_offset, 'Offset', minimum: 0);
    final binX = wholeNumber(_binX, 'Bin X', minimum: 1, maximum: 16);
    final binY = wholeNumber(_binY, 'Bin Y', minimum: 1, maximum: 16);
    final sensorWidth = wholeNumber(
      _sensorWidth,
      'Sensor width',
      minimum: 1,
      optional: true,
    );
    final sensorHeight = wholeNumber(
      _sensorHeight,
      'Sensor height',
      minimum: 1,
      optional: true,
    );
    if ((_sensorWidth.text.trim().isEmpty) !=
        (_sensorHeight.text.trim().isEmpty)) {
      errors.add(
          'Enter both sensor width and sensor height, or leave both blank.');
    }

    final exposureText = _exposure.text.trim();
    final exposure = double.tryParse(exposureText);
    if (exposure == null || !exposure.isFinite || exposure <= 0) {
      errors.add('Exposure must be a finite number greater than 0 seconds.');
    }

    double? temperature;
    final temperatureText = _temp.text.trim();
    if (temperatureText.isNotEmpty) {
      temperature = double.tryParse(temperatureText);
      if (temperature == null || !temperature.isFinite) {
        errors.add('Temperature must be a finite number or left blank.');
      }
    }

    if (errors.isNotEmpty) {
      setState(() {
        _error = errors.join(' ');
        _result = null;
      });
      return null;
    }

    return LightFrameContext(
      gain: gain!,
      offset: offset!,
      exposureSeconds: exposure!,
      temperature: temperature,
      filter: _filter.text.trim().isEmpty ? null : _filter.text.trim(),
      binX: binX!,
      binY: binY!,
      cameraId: _camera.text.trim().isEmpty ? null : _camera.text.trim(),
      sensorWidth: sensorWidth,
      sensorHeight: sensorHeight,
      opticalTrainId:
          _opticalTrain.text.trim().isEmpty ? null : _opticalTrain.text.trim(),
    );
  }

  Future<void> _accept(CalibrationMasterRecord remote) async {
    await widget.onAccept(remote);
    if (!mounted) return;
    // Re-run the preview so the now-local master (or refusal) is reflected.
    await _run();
  }

  @override
  void initState() {
    super.initState();
    _prefillFromLatestLight();
  }

  /// Start from the settings of the newest light frame on this computer, so
  /// the check answers "what would my last night get" without typing.
  Future<void> _prefillFromLatestLight() async {
    if (ref.read(backendProvider) is NetworkBackend) return;
    try {
      final db = ref.read(databaseProvider);
      final latest = await (db.select(db.capturedImages)
            ..where((t) => t.frameType.equals('light'))
            ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)])
            ..limit(1))
          .getSingleOrNull();
      if (latest == null || !mounted) return;
      String num(double v) =>
          v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
      setState(() {
        if (latest.gain != null) _gain.text = '${latest.gain}';
        if (latest.offset != null) _offset.text = '${latest.offset}';
        _exposure.text = num(latest.exposureDuration);
        _temp.text = latest.sensorTemp == null
            ? ''
            : latest.sensorTemp!.round().toString();
        _filter.text = latest.filter ?? '';
        _binX.text = '${latest.binX}';
        _binY.text = '${latest.binY}';
      });
    } on Object {
      // The defaults stay; the check still runs on whatever is typed.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return CalibrationSection(
      title: 'Check a match',
      note: 'Which masters a light frame would get, and why',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              _field(_exposure, 'Exposure s', 92),
              _field(_gain, 'Gain', 72),
              _field(_offset, 'Offset', 72),
              _field(_temp, 'Temp °C', 72),
              _field(_filter, 'Filter', 80),
              _field(_binX, 'Bin X', 60),
              _field(_binY, 'Bin Y', 60),
            ],
          ),
          if (_more) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                _field(_camera, 'Camera', 150),
                _field(_sensorWidth, 'Sensor width', 100),
                _field(_sensorHeight, 'Sensor height', 100),
                _field(_opticalTrain, 'Optical train', 150),
              ],
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            children: [
              SkotiqButton(
                label: 'Check',
                icon: LucideIcons.search,
                size: ButtonSize.small,
                variant: ButtonVariant.secondary,
                isLoading: _running,
                onPressed: _running ? null : _run,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqButton(
                label: _more ? 'Fewer fields' : 'Camera and train',
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                onPressed: () => setState(() => _more = !_more),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Text(
                '$_error',
                style: SkotiqTypography.bodySm.copyWith(color: colors.error),
              ),
            ),
          if (_result != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _buildResult(context, _result!),
          ],
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, double width) {
    return SizedBox(
      width: width,
      child: SkotiqTextField(controller: c, label: label, enabled: !_running),
    );
  }

  Widget _buildResult(BuildContext context, CalibrationMatchSet set) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _matchRow(context, 'Dark', set.dark),
        _matchRow(context, 'Bias', set.bias),
        _matchRow(context, 'Flat', set.flat),
        _matchRow(context, 'Defect map', set.defectMap, last: true),
        for (final w in set.warnings)
          Padding(
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
            child: Text(
              w,
              style: SkotiqTypography.caption.copyWith(color: colors.warning),
            ),
          ),
      ],
    );
  }

  Widget _matchRow(
    BuildContext context,
    String label,
    CalibrationMatch? match, {
    bool last = false,
  }) {
    final colors = context.skotiqColors;
    final record = match?.record;
    return CalibrationRow(
      last: last,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  label,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  record == null
                      ? 'No match'
                      : (record.filePath ?? '#${record.id}')
                          .split(RegExp(r'[/\\]'))
                          .last,
                  style: (record == null
                          ? SkotiqTypography.bodySm
                          : SkotiqTypography.monoXs)
                      .copyWith(
                    color: record == null
                        ? colors.textMuted
                        : colors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (match != null) ...[
                if (match.exposureScaled)
                  Padding(
                    padding: const EdgeInsets.only(left: SkotiqTokens.spaceSm),
                    child: SkotiqChip(
                      label: match.exposureScaleFactor != null
                          ? 'scaled x${match.exposureScaleFactor!.toStringAsFixed(2)}'
                          : 'scaled',
                      tone: ChipTone.warning,
                    ),
                  ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  '${match.score.toStringAsFixed(0)}/100',
                  style: SkotiqTypography.monoSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                if (record!.isRemote)
                  Padding(
                    padding: const EdgeInsets.only(left: SkotiqTokens.spaceSm),
                    child: SkotiqButton(
                      label: 'Pull',
                      icon: LucideIcons.download,
                      size: ButtonSize.small,
                      variant: ButtonVariant.secondary,
                      onPressed: () => _accept(record),
                    ),
                  ),
              ],
            ],
          ),
          if (match != null)
            Padding(
              padding: const EdgeInsets.only(left: 76, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in match.reasons)
                    Text(
                      r,
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  for (final w in match.warnings)
                    Text(
                      w,
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.warning,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
