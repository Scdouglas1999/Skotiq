// Master tiles, badges, freshness chips and the matching preview.
part of '../calibration_library_settings.dart';

/// One master row: type badge, capture params, freshness, tags, actions.
class _MasterTile extends StatelessWidget {
  final CalibrationMasterRecord record;
  final VoidCallback onEditTags;
  final VoidCallback onDelete;

  /// Share-to-hub action, or null when this master is not shareable (a remote
  /// candidate, a defect map, a raw frame, or one already published).
  final VoidCallback? onPublish;

  /// Un-share (retract) action, or null when this master is not currently
  /// published to the hub.
  final VoidCallback? onRetract;

  const _MasterTile({
    required this.record,
    required this.onEditTags,
    required this.onDelete,
    this.onPublish,
    this.onRetract,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final age = record.ageDays(now);
    final freshness = record.freshness(now);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _TypeBadge(type: record.type),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      Text(_summary(record), style: theme.textTheme.bodyMedium),
                ),
                _FreshnessChip(freshness: freshness, ageDays: age),
                if (onPublish != null)
                  SkotiqIconButton(
                    icon: LucideIcons.share2,
                    tooltip: 'Share to hub',
                    onPressed: onPublish,
                    size: IconButtonSize.md,
                  ),
                if (onRetract != null)
                  SkotiqIconButton(
                    icon: LucideIcons.link2Off,
                    tooltip: 'Un-share from hub',
                    onPressed: onRetract,
                    size: IconButtonSize.md,
                  ),
                SkotiqIconButton(
                  icon: LucideIcons.tag,
                  tooltip: 'Edit tags / notes',
                  onPressed: onEditTags,
                  size: IconButtonSize.md,
                ),
                SkotiqIconButton(
                  icon: LucideIcons.trash2,
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  size: IconButtonSize.md,
                  color: theme.colorScheme.error,
                ),
              ],
            ),
            if (record.filePath != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(record.filePath!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor)),
              ),
            if (record.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in record.tags)
                      Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
              ),
            if (record.notes != null && record.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(record.notes!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontStyle: FontStyle.italic)),
              ),
          ],
        ),
      ),
    );
  }

  static String _summary(CalibrationMasterRecord r) {
    final parts = <String>[];
    if (r.exposureSeconds != null) {
      parts.add(_fmtSecs(r.exposureSeconds!));
    }
    if (r.gain != null) parts.add('gain ${r.gain}');
    if (r.offset != null) parts.add('offset ${r.offset}');
    parts.add('bin ${r.binX}x${r.binY}');
    if (r.temperature != null) {
      parts.add('${r.temperature!.toStringAsFixed(1)}°C');
    }
    if (r.filter != null && r.filter!.isNotEmpty) parts.add(r.filter!);
    if (r.cameraId != null && r.cameraId!.isNotEmpty) parts.add(r.cameraId!);
    if (r.frameCount != null) parts.add('${r.frameCount} frames');
    return parts.join(' · ');
  }

  static String _fmtSecs(double secs) =>
      secs == secs.roundToDouble() ? '${secs.round()}s' : '${secs}s';
}

class _TypeBadge extends StatelessWidget {
  final CalibrationMasterType type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (type) {
      CalibrationMasterType.dark => (scheme.primary, 'DARK'),
      CalibrationMasterType.bias => (scheme.tertiary, 'BIAS'),
      CalibrationMasterType.flat => (scheme.secondary, 'FLAT'),
      CalibrationMasterType.defectMap => (scheme.error, 'DEFECT'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      ),
      child: Text(label,
          style: SkotiqTypography.eyebrow.copyWith(
            color: color,
          )),
    );
  }
}

class _FreshnessChip extends StatelessWidget {
  final CalibrationFreshness freshness;
  final int ageDays;
  const _FreshnessChip({required this.freshness, required this.ageDays});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final color = switch (freshness) {
      CalibrationFreshness.fresh => colors.success,
      CalibrationFreshness.aging => colors.warning,
      CalibrationFreshness.stale => colors.error,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: freshness.name,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.clock, size: 13, color: color),
            const SizedBox(width: 3),
            Text('${ageDays}d',
                style: SkotiqTypography.caption.copyWith(
                  color: color,
                )),
          ],
        ),
      ),
    );
  }
}

/// Matching-preview pane: enter a light-frame context, see the auto-pick per
/// type with scores, reasons, and warnings.
class _MatchingPreview extends StatefulWidget {
  final CalibrationLibraryService service;

  /// Download + merge a REMOTE shared candidate the preview surfaced.
  final Future<void> Function(CalibrationMasterRecord) onAccept;

  const _MatchingPreview({
    super.key,
    required this.service,
    required this.onAccept,
  });

  @override
  State<_MatchingPreview> createState() => _MatchingPreviewState();
}

class _MatchingPreviewState extends State<_MatchingPreview> {
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
      final result = await widget.service.match(lightContext);
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
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _field(_gain, 'Gain', 90),
            _field(_offset, 'Offset', 90),
            _field(_exposure, 'Exposure (s)', 110),
            _field(_temp, 'Temp (°C)', 90),
            _field(_filter, 'Filter', 110),
            _field(_binX, 'Bin X', 70),
            _field(_binY, 'Bin Y', 70),
            _field(_camera, 'Camera', 140),
            _field(_sensorWidth, 'Sensor W', 90),
            _field(_sensorHeight, 'Sensor H', 90),
            _field(_opticalTrain, 'Optical train', 140),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _running ? null : _run,
          icon: const Icon(LucideIcons.search, size: 16),
          label: const Text('Preview auto-selection'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.alertTriangle,
                  size: 14, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Preview failed: $_error',
                    style: SkotiqTypography.body.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    )),
              ),
            ],
          ),
        ],
        if (_result != null) ...[
          const SizedBox(height: 16),
          _buildResult(context, _result!),
        ],
      ],
    );
  }

  Widget _field(TextEditingController c, String label, double width) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        enabled: !_running,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context, CalibrationMatchSet set) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _matchCard(context, 'Dark', set.dark),
        _matchCard(context, 'Bias', set.bias),
        _matchCard(context, 'Flat', set.flat),
        _matchCard(context, 'Defect map', set.defectMap),
        if (set.warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final w in set.warnings)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.alertTriangle,
                    size: 14, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(w,
                        style: SkotiqTypography.body.copyWith(
                          color: theme.colorScheme.error,
                        ))),
              ],
            ),
        ],
      ],
    );
  }

  Widget _matchCard(
      BuildContext context, String label, CalibrationMatch? match) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);
    if (match == null) {
      return ListTile(
        dense: true,
        leading: const Icon(LucideIcons.minusCircle, size: 18),
        title: Text('$label: no match'),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('$label  ·  ${match.score.toStringAsFixed(0)}/100',
                    style: theme.textTheme.titleSmall),
                const Spacer(),
                if (match.exposureScaled)
                  Chip(
                    label: Text(match.exposureScaleFactor != null
                        ? 'scaled ${match.exposureScaleFactor!.toStringAsFixed(2)}x'
                        : 'scaled'),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                if (match.record.isRemote) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.download, size: 15),
                    label: const Text('Pull'),
                    onPressed: () => _accept(match.record),
                  ),
                ],
              ],
            ),
            if (match.record.filePath != null)
              Text(match.record.filePath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor)),
            for (final r in match.reasons)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.check, size: 13, color: colors.success),
                    const SizedBox(width: 6),
                    Expanded(child: Text(r, style: theme.textTheme.bodySmall)),
                  ],
                ),
              ),
            for (final w in match.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.alertTriangle,
                        size: 13, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(w,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _typeLabel(CalibrationMasterType type) => switch (type) {
      CalibrationMasterType.dark => 'Dark',
      CalibrationMasterType.bias => 'Bias',
      CalibrationMasterType.flat => 'Flat',
      CalibrationMasterType.defectMap => 'Defect map',
    };
