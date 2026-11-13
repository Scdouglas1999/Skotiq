// Replay Debug retention + clear-all settings page.
//
// Surfaces the two replay-debug keys persisted in `app_settings`:
//   * replay_debug.enabled              — runtime toggle. When false the
//                                          Rust executor stops emitting
//                                          DecisionLogged events, with ONE
//                                          exception: the operator's own
//                                          stop decision is always recorded
//                                          (it is the only evidence that a
//                                          stop was human, not a safety
//                                          abort, and must not be
//                                          silenceable).
//   * replay_debug.retention_days       — daily-prune cutoff used by
//                                          ReplayDebugService.pruneOlderThan
//                                          (called from AutoSaveService on
//                                          app start, once per day).
//
// Also surfaces a destructive "Clear all replay history" button so the
// user can wipe the table without waiting for the retention window to
// catch up. The button is wrapped in a confirm dialog because the
// underlying delete is irreversible.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/confirm_dialog.dart';
import 'settings_widgets.dart';
import '../../../utils/snackbar_helper.dart';

class ReplayDebugSettings extends ConsumerStatefulWidget {
  const ReplayDebugSettings({
    super.key,
  });

  @override
  ConsumerState<ReplayDebugSettings> createState() =>
      _ReplayDebugSettingsState();
}

class _ReplayDebugSettingsState extends ConsumerState<ReplayDebugSettings> {
  final TextEditingController _retentionCtrl = TextEditingController();
  bool _isClearing = false;
  int _clearGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next)) return;
        _clearGeneration++;
        if (mounted && _isClearing) {
          setState(() => _isClearing = false);
        }
      },
    );
  }

  @override
  void dispose() {
    _clearGeneration++;
    _backendSubscription?.close();
    _retentionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isRemote = ref.watch(isRemoteModeProvider);
    final enabledAsync = ref.watch(replayDebugEnabledProvider);
    final retentionAsync = ref.watch(replayDebugRetentionDaysProvider);

    if (enabledAsync.isLoading || retentionAsync.isLoading) {
      return const SettingsLoadingState();
    }
    if (enabledAsync.hasError) {
      return SettingsErrorState(
        error: enabledAsync.error!,
        onRetry: () => ref
            .read(replayDebugSettingsControllerProvider)
            .invalidateSettings(),
      );
    }
    if (retentionAsync.hasError) {
      return SettingsErrorState(
        error: retentionAsync.error!,
        onRetry: () => ref
            .read(replayDebugSettingsControllerProvider)
            .invalidateSettings(),
      );
    }

    final enabled = enabledAsync.value ?? true;
    final retentionDays =
        retentionAsync.value ?? replayDebugDefaultRetentionDays;

    final controller = ref.read(replayDebugSettingsControllerProvider);
    final Object authorityKey =
        isRemote ? ref.watch(backendProvider) : ref.watch(databaseProvider);

    return SettingsPage(
      title: 'Replay & debug',
      description: isRemote
          ? 'How long the imaging host keeps the record of every decision a '
              'run made, so you can replay a night afterwards. Older entries '
              'are removed automatically, once a day.'
          : 'How long Skotiq keeps the record of every decision a run '
              'made, so you can replay a night afterwards. Older entries are '
              'removed automatically, once a day.',
      children: [
        SettingsSection(
          title: 'Logging',
          children: [
            _row(
              icon: LucideIcons.history,
              title: 'Replay decision logging',
              subtitle: 'When enabled, every adaptive-exposure swap, trigger '
                  'firing, frame accept or reject, and recovery step is '
                  'recorded so the Replay screen can rebuild the night '
                  'afterwards. Turning this off leaves past runs with almost '
                  'no timeline — only a stop you command yourself is always '
                  'recorded.',
              trailing: SettingsSwitch(
                value: enabled,
                onChanged: (value) async {
                  try {
                    await controller.setEnabled(value);
                  } catch (error) {
                    if (!context.mounted) return;
                    context.showErrorSnackBar(
                      'Could not change replay logging: ${userFacingError(error)}',
                    );
                  }
                },
              ),
              isLast: false,
            ),
            _row(
              icon: LucideIcons.calendar,
              title: 'Retention (days)',
              subtitle: 'Decisions older than this are pruned daily. Range '
                  '1..3650. Default $replayDebugDefaultRetentionDays.',
              trailing: SizedBox(
                width: 96,
                child: SettingsNumberInput(
                  controller: _retentionCtrl,
                  authoritativeValue: retentionDays.toDouble(),
                  authorityKey: authorityKey,
                  suffix: 'd',
                  min: 1,
                  max: 3650,
                  decimals: 0,
                  onChanged: (v) async {
                    try {
                      await controller.setRetentionDays(v.toInt());
                    } catch (error) {
                      if (!context.mounted) return;
                      context.showErrorSnackBar(
                        'Could not change replay retention: ${userFacingError(error)}',
                      );
                    }
                  },
                ),
              ),
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: 'Maintenance',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Clear all replay history',
                    style: SkotiqTypography.labelStrong
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Removes every recorded decision, from every past run. '
                    'Your captured images, sessions and session notes are '
                    'untouched — only the replay record is cleared.',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SkotiqButton(
                      onPressed: _isClearing
                          ? null
                          : () => _confirmAndClear(controller),
                      icon: LucideIcons.trash2,
                      label: _isClearing
                          ? 'Clearing…'
                          : 'Clear all replay history',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      isLoading: _isClearing,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmAndClear(ReplayDebugSettingsController c) async {
    if (_isClearing) return;
    final authority = ref.read(backendProvider);
    final generation = ++_clearGeneration;
    setState(() => _isClearing = true);

    // Ask how much is there BEFORE asking whether to destroy it. Agreeing to
    // an unknown quantity is not consent; null means the authority could not
    // tell us, and the wording below says so instead of implying a number.
    final total = await c.countAllHistory();
    if (!_isCurrentClear(generation, authority) || !mounted) return;

    final ok = await ConfirmDialog.show(
      context: context,
      title: 'Clear all replay history?',
      message: total == null
          ? 'This deletes every decision Skotiq has recorded, for every '
              'past run. The Replay screen will show "No decisions recorded" '
              'until a new run starts. This cannot be undone.'
          : total == 1
              ? 'This deletes the 1 recorded decision, for every past run. '
                  'The Replay screen will show "No decisions recorded" until '
                  'a new run starts. This cannot be undone.'
              : 'This deletes all $total recorded decisions, for every past '
                  'run. The Replay screen will show "No decisions recorded" '
                  'until a new run starts. This cannot be undone.',
      confirmLabel: 'Clear history',
      isDestructive: true,
    );
    if (!_isCurrentClear(generation, authority)) return;
    if (ok != true) {
      setState(() => _isClearing = false);
      return;
    }
    try {
      final removed = await c.clearAllHistory();
      if (mounted && _isCurrentClear(generation, authority)) {
        context.showInfoSnackBar(
          removed == 1
              ? 'Cleared 1 recorded decision.'
              : 'Cleared $removed recorded decisions.',
        );
      }
    } catch (error) {
      if (mounted && _isCurrentClear(generation, authority)) {
        context.showErrorSnackBar(
          'Could not clear replay history: ${userFacingError(error)}',
        );
      }
    } finally {
      if (_isCurrentClear(generation, authority)) {
        setState(() => _isClearing = false);
      }
    }
  }

  bool _isCurrentClear(int generation, SkotiqBackend authority) =>
      mounted &&
      generation == _clearGeneration &&
      _isClearing &&
      ref.backendScopeOver(authority).isCurrent;

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget trailing,
    bool isLast = false,
  }) {
    if (SettingsFormScope.narrowOf(context)) {
      return SettingRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
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
