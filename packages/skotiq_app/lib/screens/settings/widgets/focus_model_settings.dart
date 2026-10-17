import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';

/// View the connected appliance's temperature-compensation focus model.
///
/// The model is built on the rig (where autofocus runs). This pulls the rig's
/// model (slope/R²/reliability) over REST so a remote operator can confirm
/// temp-comp is healthy from Settings. Remote-only — the live, backend-aware
/// view lives on Imaging → Focus (`FocusModelCurveCard`).
class FocusModelSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  /// When true, render without an own scroll view / header (embedded in a
  /// merged section). Same contract as [PredictiveAfSettingsPage].
  final bool embedded;

  const FocusModelSettings({
    super.key,
    this.isMobile = false,
    this.embedded = false,
  });

  @override
  ConsumerState<FocusModelSettings> createState() => _FocusModelSettingsState();
}

class _FocusModelSettingsState extends ConsumerState<FocusModelSettings> {
  Map<String, dynamic>? _model;
  bool _loading = false;
  String? _error;
  Object? _clearToken;
  bool _clearConfirmationOpen = false;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _loadGeneration = 0;

  NetworkBackend? get _backend {
    final b = ref.read(backendProvider);
    return b is NetworkBackend ? b : null;
  }

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _loadGeneration++;
        setState(() {
          _model = null;
          _error = null;
          _loading = next is NetworkBackend;
          _clearToken = null;
          _clearConfirmationOpen = false;
        });
        if (next is NetworkBackend) unawaited(_refresh());
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    final backend = _backend;
    final generation = ++_loadGeneration;
    if (backend == null) {
      if (!mounted) return;
      setState(() {
        _model = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final model = await backend.getFocusModel();
      if (!_isCurrentLoad(backend, generation)) return;
      setState(() {
        _model = model;
        _loading = false;
      });
    } catch (e) {
      if (!_isCurrentLoad(backend, generation)) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool _isCurrentLoad(NetworkBackend backend, int generation) =>
      mounted &&
      generation == _loadGeneration &&
      identical(ref.read(backendProvider), backend);

  bool _isCurrentClear(NetworkBackend backend, Object token) =>
      mounted &&
      identical(_clearToken, token) &&
      identical(ref.read(backendProvider), backend);

  Future<void> _clear() async {
    if (_loading || _clearToken != null || _clearConfirmationOpen) return;
    final backend = _backend;
    if (backend == null) return;
    setState(() => _clearConfirmationOpen = true);
    final bool confirmed;
    try {
      confirmed = await ConfirmDialog.show(
        context: context,
        title: 'Clear focus model data?',
        message: 'This deletes every autofocus/temperature data point on the '
            'rig. The temperature-compensation model must be rebuilt from new '
            'autofocus runs across a range of temperatures.',
        confirmLabel: 'Clear',
        isDestructive: true,
      );
    } finally {
      if (mounted) setState(() => _clearConfirmationOpen = false);
    }
    if (!mounted) return;
    if (!confirmed) return;
    if (!identical(ref.read(backendProvider), backend)) {
      context.showErrorSnackBar(
        'Connected rig changed; focus model data was not cleared',
      );
      return;
    }
    final token = Object();
    setState(() => _clearToken = token);
    try {
      await backend.clearFocusModelData();
      if (mounted && _isCurrentClear(backend, token)) {
        context.showSuccessSnackBar('Focus model data cleared');
      }
    } catch (e) {
      if (mounted && _isCurrentClear(backend, token)) {
        context.showErrorSnackBar('Clear failed: $e');
      }
    } finally {
      if (_isCurrentClear(backend, token)) {
        setState(() => _clearToken = null);
        await _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backend = _backend;
    final model = _model;
    final hasModel = model?['hasModel'] == true;
    final m = model?['model'] as Map<String, dynamic>?;

    return SettingsPage(
      title: 'Focus model',
      description: 'Temperature-compensation focus model on the connected rig',
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile || widget.embedded,
      scrollable: !widget.embedded,
      children: [
        if (backend == null)
          _info(colors, LucideIcons.info,
              'Connect to a remote appliance to view its focus model.')
        else ...[
          Row(
            children: [
              Text('Active equipment profile',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  )),
              const Spacer(),
              SkotiqButton(
                onPressed: (_loading || _clearToken != null) ? null : _refresh,
                label: 'Refresh',
                icon: LucideIcons.rotateCw,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading && model == null)
            _info(colors, LucideIcons.loader, 'Loading…')
          else if (hasModel && m != null)
            SkotiqPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                          m['isReliable'] == true
                              ? LucideIcons.checkCircle
                              : LucideIcons.alertTriangle,
                          size: 16,
                          color: m['isReliable'] == true
                              ? colors.success
                              : colors.warning),
                      const SizedBox(width: 8),
                      Text(
                          m['isReliable'] == true
                              ? 'Model healthy'
                              : 'Model low-confidence',
                          style: SkotiqTypography.sectionTitle.copyWith(
                            color: colors.textPrimary,
                          )),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _row(colors, 'Slope', '${_num(m['slope'])} steps/°C'),
                  _row(colors, 'R²', _num(m['rSquared'])),
                  _row(colors, 'Data points', '${m['dataPointCount'] ?? '—'}'),
                  if (model?['description'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('${model!['description']}',
                          style: SkotiqTypography.caption.copyWith(
                            color: colors.textMuted,
                          )),
                    ),
                ],
              ),
            )
          else
            _info(
                colors,
                LucideIcons.thermometer,
                model?['message']?.toString() ??
                    'No focus model yet (autofocus runs across temperatures '
                        'build it automatically). '
                        'Data points: ${model?['dataPointCount'] ?? 0}.'),
          const SizedBox(height: 12),
          SkotiqButton(
            onPressed:
                (_loading || _clearToken != null || _clearConfirmationOpen)
                    ? null
                    : _clear,
            label: 'Clear Model Data',
            icon: LucideIcons.trash2,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            isLoading: _clearToken != null,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _info(colors, LucideIcons.alertTriangle, 'Error: $_error'),
          ],
        ],
      ],
    );
  }

  static String _num(dynamic v) {
    if (v is num) return v.toStringAsFixed(3);
    return '$v';
  }

  Widget _row(SkotiqColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              )),
          const Spacer(),
          Text(value,
              style: SkotiqTypography.buttonSm.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }

  Widget _info(SkotiqColors colors, IconData icon, String text) {
    return SkotiqPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                )),
          ),
        ],
      ),
    );
  }
}
