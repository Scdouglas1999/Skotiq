// Predictive autofocus settings + per-camera/filter model viewer.
//
// Lives next to the legacy `autofocus_settings.dart` so a user clicking the
// "Autofocus" entry in the side bar sees the new "Predictive" subsection
// underneath the existing AF tuning. The page consumes
// [PredictiveAfService] for the model data and listens to its
// [PredictiveAfService.driftEvents] stream so it can render an inline "Your
// Ha filter focus model has drifted by 1200 steps over the last 5 runs.
// Consider re-training" banner.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// Hide skotiq_core's ConnectionState — Flutter's async.ConnectionState
// is what FutureBuilder needs in this file, and the two collide via the
// barrel. (See skotiq_core.dart re: device_types.dart.)
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';

/// Settings page: "Autofocus → Predictive". Surfaces the auto-learn toggle,
/// the confidence thresholds, the drift-detection knobs, and a viewer that
/// lists every persisted per-filter model with re-train / export actions.
class PredictiveAfSettingsPage extends ConsumerStatefulWidget {
  final bool isMobile;

  /// When true, render without an own scroll view / header (embedded in a
  /// merged section's single outer scroll).
  final bool embedded;

  const PredictiveAfSettingsPage({
    super.key,
    this.isMobile = false,
    this.embedded = false,
  });

  @override
  ConsumerState<PredictiveAfSettingsPage> createState() =>
      _PredictiveAfSettingsPageState();
}

class _PredictiveAfSettingsPageState
    extends ConsumerState<PredictiveAfSettingsPage> {
  StreamSubscription<DriftStatus>? _driftSub;
  ProviderSubscription<SkotiqBackend>? _backendSub;
  ProviderSubscription<EquipmentProfileModel?>? _profileSub;
  String? _latestDriftWarning;
  Future<PredictiveAfSettingsSnapshot>? _snapshotFuture;
  Future<void> _configWriteTail = Future<void>.value();
  PredictiveAfConfig? _requestedConfig;
  int _loadRevision = 0;
  int _authorityRevision = 0;
  int _driftRevision = 0;

  @override
  void initState() {
    super.initState();
    _backendSub = ref.listenManual<SkotiqBackend>(backendProvider, (
      previous,
      next,
    ) {
      if (!mounted) return;
      _authorityRevision++;
      _latestDriftWarning = null;
      _requestedConfig = null;
      _configWriteTail = Future<void>.value();
      _attachDriftListener();
      _reload();
    });
    _profileSub = ref.listenManual<EquipmentProfileModel?>(
      activeEquipmentProfileProvider,
      (previous, next) {
        if (mounted && previous?.id != next?.id) {
          setState(() => _latestDriftWarning = null);
          _reload();
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachDriftListener();
      _reload();
    });
  }

  void _attachDriftListener() {
    final revision = ++_driftRevision;
    _driftSub?.cancel();
    if (ref.read(backendProvider) is NetworkBackend) {
      _driftSub = null;
      return;
    }
    final service = ref.read(predictiveAfServiceProvider);
    _driftSub = service.driftEvents.listen((status) {
      if (!mounted || revision != _driftRevision) return;
      if (status is ShouldWarn) {
        setState(() => _latestDriftWarning = status.message);
      }
    });
  }

  void _reload() {
    final revision = ++_loadRevision;
    final controller = ref.read(predictiveAfSettingsControllerProvider);
    final profileId = ref.read(activeEquipmentProfileProvider)?.id;
    final future = controller.load(equipmentProfileId: profileId).then((value) {
      if (mounted && revision == _loadRevision) {
        _requestedConfig = value.config;
      }
      return value;
    });
    if (mounted) {
      setState(() {
        _snapshotFuture = future;
      });
    }
  }

  Future<void> _updateConfig(
    PredictiveAfConfig current,
    PredictiveAfConfig Function(PredictiveAfConfig) change,
  ) async {
    final next = change(_requestedConfig ?? current);
    _requestedConfig = next;
    final authority = _authorityRevision;
    final controller = ref.read(predictiveAfSettingsControllerProvider);
    final operation = _configWriteTail.then((_) async {
      if (!mounted || authority != _authorityRevision) return;
      await controller.updateConfig(next);
    });
    _configWriteTail = operation.then<void>((_) {}, onError: (_, __) {});
    try {
      await operation;
      if (mounted && authority == _authorityRevision) _reload();
    } catch (_) {
      if (authority != _authorityRevision) return;
      if (identical(_requestedConfig, next)) _requestedConfig = null;
      if (mounted) _reload();
      rethrow;
    }
  }

  @override
  void dispose() {
    _driftRevision++;
    _driftSub?.cancel();
    _backendSub?.close();
    _profileSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeProfile = ref.watch(activeEquipmentProfileProvider);
    final controller = ref.watch(predictiveAfSettingsControllerProvider);

    return SettingsPage(
      title: 'Predictive autofocus',
      description:
          'Learn per-filter focus/temperature slope across sessions and skip '
          'manual autofocus when the model is confident.',
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile || widget.embedded,
      scrollable: !widget.embedded,
      children: [
        if (_latestDriftWarning != null)
          _DriftWarningBanner(
            message: _latestDriftWarning!,
            onDismiss: () => setState(() => _latestDriftWarning = null),
          ),
        FutureBuilder<PredictiveAfSettingsSnapshot>(
          future: _snapshotFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child:
                        SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
              );
            }
            if (snapshot.hasError || snapshot.data == null) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('Could not load focus models: ${snapshot.error}'),
                    TextButton(
                      onPressed: _reload,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            return Column(
              children: _buildSettings(
                snapshot.data!,
                controller,
                activeProfile?.id,
              ),
            );
          },
        ),
      ],
    );
  }

  List<Widget> _buildSettings(
    PredictiveAfSettingsSnapshot snapshot,
    PredictiveAfSettingsController controller,
    int? activeProfileId,
  ) {
    final config = _requestedConfig ?? snapshot.config;
    return [
      SettingsSection(
        title: 'Gates',
        isMobile: widget.isMobile,
        children: [
          _settingRow(
            icon: LucideIcons.brainCircuit,
            title: 'Auto-learn focus models',
            subtitle: 'When enabled, each successful AF run appends a sample '
                'to the matching (camera, filter) model and re-fits the '
                'regression on every insert.',
            trailing: SettingsSwitch(
              value: config.enabled,
              onChanged: (value) => _updateConfig(
                config,
                (current) => current.copyWith(enabled: value),
              ),
            ),
          ),
          _settingRow(
            icon: LucideIcons.barChart3,
            title: 'Minimum samples for trust',
            subtitle: 'Below this count, even a high-R² model still forces a '
                'real AF sweep so the predictor cannot lock onto a tiny '
                'sample window by coincidence.',
            trailing: _NumberField(
              initialValue: config.minSamplesForTrust.toDouble(),
              min: 3,
              max: 50,
              decimals: 0,
              onChanged: (v) => _updateConfig(
                config,
                (current) => current.copyWith(
                  minSamplesForTrust: v.toInt(),
                ),
              ),
            ),
          ),
          _settingRow(
            icon: LucideIcons.checkCircle,
            title: 'High-confidence threshold (R²)',
            subtitle: 'R² ≥ this → apply prediction directly.',
            trailing: _NumberField(
              initialValue: config.highConfidenceThreshold,
              min: 0.5,
              max: 1.0,
              decimals: 2,
              onChanged: (v) => _updateConfig(
                config,
                (current) => current.copyWith(
                  highConfidenceThreshold: v,
                ),
              ),
            ),
          ),
          _settingRow(
            icon: LucideIcons.alertCircle,
            title: 'Low-confidence threshold (R²)',
            subtitle: 'R² < this → force a real AF sweep.',
            trailing: _NumberField(
              initialValue: config.lowConfidenceThreshold,
              min: 0.0,
              max: 0.9,
              decimals: 2,
              onChanged: (v) => _updateConfig(
                config,
                (current) => current.copyWith(
                  lowConfidenceThreshold: v,
                ),
              ),
            ),
          ),
          _settingRow(
            icon: LucideIcons.activity,
            title: 'Drift threshold (steps)',
            subtitle: 'How many focuser steps a prediction can be off before '
                'counting as a "bad" run for drift tracking.',
            trailing: _NumberField(
              initialValue: config.driftThresholdSteps.toDouble(),
              min: 20,
              max: 2000,
              decimals: 0,
              onChanged: (v) => _updateConfig(
                config,
                (current) => current.copyWith(
                  driftThresholdSteps: v.toInt(),
                ),
              ),
            ),
          ),
          _settingRow(
            icon: LucideIcons.alertTriangle,
            title: 'Bad runs before warning',
            subtitle: 'Consecutive bad predictions required before the app '
                'surfaces a re-train notification.',
            trailing: _NumberField(
              initialValue: config.driftRunsBeforeWarn.toDouble(),
              min: 1,
              max: 20,
              decimals: 0,
              onChanged: (v) => _updateConfig(
                config,
                (current) => current.copyWith(
                  driftRunsBeforeWarn: v.toInt(),
                ),
              ),
            ),
            isLast: true,
          ),
        ],
      ),
      SettingsSection(
        title: 'Learned models',
        isMobile: widget.isMobile,
        children: [
          _ModelViewer(
            controller: controller,
            models: snapshot.models,
            equipmentProfileId: activeProfileId,
            onReload: _reload,
          ),
        ],
      ),
    ];
  }

  Widget _settingRow({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget trailing,
    bool isLast = false,
  }) {
    if (widget.isMobile) {
      return SettingRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        isMobile: true,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: SettingRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
      ),
    );
  }
}

class _DriftWarningBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _DriftWarningBanner({
    required this.message,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, color: colors.warning, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          SkotiqIconButton(
            icon: LucideIcons.x,
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            size: IconButtonSize.sm,
            color: colors.textMuted,
          ),
        ],
      ),
    );
  }
}

class _ModelViewer extends StatelessWidget {
  final PredictiveAfSettingsController controller;
  final List<FilterFocusModel> models;
  final int? equipmentProfileId;
  final VoidCallback onReload;

  const _ModelViewer({
    required this.controller,
    required this.models,
    required this.equipmentProfileId,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    if (models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(
              LucideIcons.info,
              color: SkotiqColors.of(context).textMuted,
              size: 14,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                equipmentProfileId == null
                    ? 'Activate an equipment profile to see its learned focus models.'
                    : 'No focus models have been learned for this profile yet. '
                        'Run autofocus across a few temperatures and they will '
                        'appear here.',
                style: SkotiqTypography.caption.copyWith(
                  color: SkotiqColors.of(context).textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: models
            .map(
              (model) => _ModelRow(
                key: ValueKey(model.uuid),
                model: model,
                onClear: () async {
                  try {
                    await controller.clearSamples(
                      equipmentProfileId: model.equipmentProfileId,
                      filterName: model.filterName,
                    );
                    onReload();
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Re-train failed: $error')),
                      );
                    }
                  }
                },
                onExport: () async {
                  try {
                    final json = await controller.exportModel(
                      equipmentProfileId: model.equipmentProfileId,
                      filterName: model.filterName,
                    );
                    if (!context.mounted || json == null) return;
                    await Clipboard.setData(ClipboardData(text: json));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Copied ${model.filterName} model JSON to clipboard',
                        ),
                      ),
                    );
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Export failed: $error')),
                      );
                    }
                  }
                },
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ModelRow extends StatefulWidget {
  final FilterFocusModel model;
  final Future<void> Function() onClear;
  final Future<void> Function() onExport;

  const _ModelRow({
    super.key,
    required this.model,
    required this.onClear,
    required this.onExport,
  });

  @override
  State<_ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<_ModelRow> {
  bool _expanded = false;
  bool _busy = false;

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onExport();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmClear() async {
    if (_busy) return;
    final model = widget.model;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Re-train ${model.filterName} focus model?'),
        content: Text(
          'This clears all ${model.samples.length} learned samples '
          'for ${model.filterName}. The next autofocus run will '
          'start a fresh regression window.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Re-train'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onClear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final c = SkotiqColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _confidenceDot(m.confidenceScore, c),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  m.filterName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: c.textPrimary,
                  ),
                ),
              ),
              SkotiqIconButton(
                icon:
                    _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                tooltip: _expanded ? 'Hide samples' : 'View samples',
                onPressed: () => setState(() => _expanded = !_expanded),
                size: IconButtonSize.sm,
                color: c.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _stat('Slope', '${m.slopeStepsPerC.toStringAsFixed(1)} steps/°C',
                  c),
              _stat('Samples', '${m.samples.length}', c),
              _stat('Runs', '${m.trainingRunCount}', c),
              _stat('R²', m.confidenceScore.toStringAsFixed(3), c),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The spinner keeps the button's footprint while the export
                // runs, so the row does not reflow under the pointer.
                if (_busy)
                  SizedBox.square(
                    dimension: SkotiqTokens.iconButtonSizeSm,
                    child: Tooltip(
                      message: 'Exporting…',
                      child: Padding(
                        padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                        child: SkotiqSpinner(size: 12, color: c.textMuted),
                      ),
                    ),
                  )
                else
                  SkotiqIconButton(
                    icon: LucideIcons.download,
                    tooltip: 'Export the samples as JSON',
                    onPressed: _export,
                    size: IconButtonSize.sm,
                    color: c.textMuted,
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : _confirmClear,
                  icon: Icon(LucideIcons.refreshCw, size: 13, color: c.warning),
                  label: Text(
                    'Re-train',
                    style: SkotiqTypography.captionSm.copyWith(
                      color: c.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (m.consecutiveBadPredictions > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(LucideIcons.alertTriangle, size: 12, color: c.warning),
                const SizedBox(width: 6),
                Text(
                  'Drift: ${m.consecutiveBadPredictions} consecutive bad '
                  'predictions; ${m.accumulatedDriftSteps} accumulated steps',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: c.warning,
                  ),
                ),
              ],
            ),
          ],
          if (m.lastUsedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Last used: ${_formatTimeAgo(m.lastUsedAt!)} · '
              'Last trained: ${_formatTimeAgo(m.lastTrainedAt)}',
              style: SkotiqTypography.captionSm.copyWith(
                color: c.textMuted,
              ),
            ),
          ],
          if (_expanded) ...[
            const SizedBox(height: 10),
            _SampleScatter(samples: m.samples, model: m),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value, SkotiqColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: SkotiqTypography.captionSm.copyWith(
              color: c.textMuted,
            )),
        Text(
          value,
          style: SkotiqTypography.eyebrow.copyWith(
            color: c.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _confidenceDot(double confidence, SkotiqColors c) {
    final Color color;
    if (confidence >= 0.8) {
      color = c.success;
    } else if (confidence >= 0.5) {
      color = c.warning;
    } else {
      color = c.error;
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  String _formatTimeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Inline scatter plot for the per-filter sample window. Light-weight
/// custom painter — no chart library dependency.
class _SampleScatter extends StatelessWidget {
  final List<FocusTrainingSample> samples;
  final FilterFocusModel model;

  const _SampleScatter({
    required this.samples,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SizedBox(
      height: 140,
      child: SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
        child: samples.isEmpty
            ? Center(
                child: Text(
                  'No samples',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              )
            : CustomPaint(
                size: Size.infinite,
                painter: _ScatterPainter(
                  samples: samples,
                  model: model,
                  pointColor: colors.accent,
                  lineColor: colors.primary,
                  gridColor: colors.border,
                ),
              ),
      ),
    );
  }
}

class _ScatterPainter extends CustomPainter {
  final List<FocusTrainingSample> samples;
  final FilterFocusModel model;
  final Color pointColor;
  final Color lineColor;
  final Color gridColor;

  _ScatterPainter({
    required this.samples,
    required this.model,
    required this.pointColor,
    required this.lineColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    double minTemp = samples.first.temperatureCelsius;
    double maxTemp = samples.first.temperatureCelsius;
    double minPos = samples.first.focusPosition.toDouble();
    double maxPos = samples.first.focusPosition.toDouble();
    for (final s in samples) {
      if (s.temperatureCelsius < minTemp) minTemp = s.temperatureCelsius;
      if (s.temperatureCelsius > maxTemp) maxTemp = s.temperatureCelsius;
      if (s.focusPosition < minPos) minPos = s.focusPosition.toDouble();
      if (s.focusPosition > maxPos) maxPos = s.focusPosition.toDouble();
    }
    final tempRange = (maxTemp - minTemp).abs();
    if (tempRange < 1) {
      minTemp -= 1;
      maxTemp += 1;
    }
    final posRange = (maxPos - minPos).abs();
    if (posRange < 50) {
      minPos -= 50;
      maxPos += 50;
    }

    double mapX(double t) => (t - minTemp) / (maxTemp - minTemp) * size.width;
    double mapY(double p) =>
        size.height - (p - minPos) / (maxPos - minPos) * size.height;

    // Border / grid
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.5)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, gridPaint);

    // Regression line
    if (model.slopeStepsPerC.abs() > 1e-6) {
      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final y1 = model.predictPosition(minTemp);
      final y2 = model.predictPosition(maxTemp);
      canvas.drawLine(
        Offset(mapX(minTemp), mapY(y1.toDouble())),
        Offset(mapX(maxTemp), mapY(y2.toDouble())),
        linePaint,
      );
    }

    // Points
    final pointPaint = Paint()..color = pointColor;
    for (final s in samples) {
      canvas.drawCircle(
        Offset(mapX(s.temperatureCelsius), mapY(s.focusPosition.toDouble())),
        2.5,
        pointPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScatterPainter old) =>
      old.samples != samples || old.model.uuid != model.uuid;
}

/// Single number field used by the settings page. Avoids requiring callers
/// to manage a TextEditingController for each row.
class _NumberField extends StatefulWidget {
  final double initialValue;
  final double min;
  final double max;
  final int decimals;
  final FutureOr<void> Function(double) onChanged;

  const _NumberField({
    required this.initialValue,
    required this.min,
    required this.max,
    required this.decimals,
    required this.onChanged,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialValue.toStringAsFixed(widget.decimals),
    );
  }

  @override
  void didUpdateWidget(covariant _NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue == widget.initialValue &&
        oldWidget.decimals == widget.decimals) {
      return;
    }

    final nextText = widget.initialValue.toStringAsFixed(widget.decimals);
    if (_controller.text == nextText) return;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsNumberInput(
      controller: _controller,
      suffix: '',
      min: widget.min,
      max: widget.max,
      decimals: widget.decimals,
      onChanged: widget.onChanged,
    );
  }
}
