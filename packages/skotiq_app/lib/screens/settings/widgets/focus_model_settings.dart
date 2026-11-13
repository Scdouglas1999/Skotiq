import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
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
  const FocusModelSettings({
    super.key,
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
  ProviderSubscription<HostFocusModels?>? _hostSubscription;

  /// Model loads (the newest wins) and clears on the host; a host change
  /// drops what the old host answers.
  late final _hostScopes = ref.backendScopes(alive: () => mounted);

  HostFocusModels? get _focusModels => ref.read(linkedHostFocusModelsProvider);

  @override
  void initState() {
    super.initState();
    _hostSubscription = ref.listenManual<HostFocusModels?>(
      linkedHostFocusModelsProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _hostScopes.cancelAll();
        setState(() {
          _model = null;
          _error = null;
          _loading = next != null;
          _clearToken = null;
          _clearConfirmationOpen = false;
        });
        if (next != null) unawaited(_refresh());
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _hostSubscription?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    final load = _hostScopes.beginLatest();
    final focusModels = _focusModels;
    if (focusModels == null) {
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
      final model = await focusModels.getFocusModel();
      if (load.isStale) return;
      setState(() {
        _model = model;
        _loading = false;
      });
    } catch (e) {
      if (load.isStale) return;
      setState(() {
        _loading = false;
        _error = userFacingError(e);
      });
    }
  }

  bool _isCurrentClear(AsyncScope<SkotiqBackend> clear, Object token) =>
      clear.isCurrent && identical(_clearToken, token);

  Future<void> _clear() async {
    if (_loading || _clearToken != null || _clearConfirmationOpen) return;
    final clear = _hostScopes.begin();
    final focusModels = _focusModels;
    if (focusModels == null) return;
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
    if (clear.isStale) {
      context.showErrorSnackBar(
        'Connected rig changed; focus model data was not cleared',
      );
      return;
    }
    final token = Object();
    setState(() => _clearToken = token);
    try {
      await focusModels.clearFocusModelData();
      if (mounted && _isCurrentClear(clear, token)) {
        context.showSuccessSnackBar('Focus model data cleared');
      }
    } catch (e) {
      if (mounted && _isCurrentClear(clear, token)) {
        context.showErrorSnackBar('Clear failed: ${userFacingError(e)}');
      }
    } finally {
      if (_isCurrentClear(clear, token)) {
        setState(() => _clearToken = null);
        await _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final focusModels = ref.watch(linkedHostFocusModelsProvider);
    final model = _model;
    final hasModel = model?['hasModel'] == true;
    final m = model?['model'] as Map<String, dynamic>?;

    return SettingsPage(
      title: 'Focus model',
      description: 'Temperature-compensation focus model on the connected rig',
      children: [
        if (focusModels == null)
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
