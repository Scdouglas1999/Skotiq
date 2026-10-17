import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Dialog for recovering interrupted imaging sessions
class SessionRecoveryDialog extends ConsumerStatefulWidget {
  final List<SessionRecoveryInfo> incompleteSessions;

  const SessionRecoveryDialog({
    super.key,
    required this.incompleteSessions,
  });

  @override
  ConsumerState<SessionRecoveryDialog> createState() =>
      _SessionRecoveryDialogState();
}

class _SessionRecoveryDialogState extends ConsumerState<SessionRecoveryDialog> {
  // Mutable copy so per-row discards remove their card immediately instead of
  // leaving a stale row that still offers Resume/Discard on an aborted session.
  late final List<SessionRecoveryInfo> _sessions;
  final Set<int> _recoveringSessionIds = <int>{};
  final Set<int> _discardingSessionIds = <int>{};
  bool _discardingAll = false;

  bool get _isBusy =>
      _discardingAll ||
      _recoveringSessionIds.isNotEmpty ||
      _discardingSessionIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _sessions = List<SessionRecoveryInfo>.from(widget.incompleteSessions);
  }

  @override
  Widget build(BuildContext context) {
    final sessionCount = _sessions.length;
    final dialog = AlertDialog(
      title: Row(
        children: [
          Icon(LucideIcons.alertCircle,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          const Text('Incomplete Sessions Found'),
        ],
      ),
      content: ConstrainedBox(
        constraints: Responsive.dialogConstraints(
          context,
          preferredWidth: 600,
          preferredHeight: 500,
          minWidth: 400,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The following imaging '
              'session${sessionCount == 1 ? '' : 's'} '
              '${sessionCount == 1 ? 'was' : 'were'} not properly closed. '
              'Would you like to resume or discard '
              '${sessionCount == 1 ? 'it' : 'them'}?',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < _sessions.length; i++) ...[
                      _buildSessionCard(_sessions[i]),
                      if (i < _sessions.length - 1) const Divider(),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Non-destructive escape hatch: "Decide Later" closes the dialog
        // without touching the sessions, so they remain available from whatever
        // entry point surfaced it (dashboard "Recover sessions" + startup
        // auto-open).
        SkotiqButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(),
          label: 'Decide later',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed:
              _isBusy || _sessions.isEmpty ? null : _confirmAndDiscardAll,
          isLoading: _discardingAll,
          label: 'Discard all',
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
        ),
      ],
    );
    return PopScope(canPop: !_isBusy, child: dialog);
  }

  Widget _buildSessionCard(SessionRecoveryInfo session) {
    final isRecovering = _recoveringSessionIds.contains(session.sessionId);
    final isDiscarding = _discardingSessionIds.contains(session.sessionId);
    final busy = _isBusy;
    return _SessionCard(
      session: session,
      isRecovering: isRecovering,
      isDiscarding: isDiscarding,
      onRecover: busy
          ? null
          : () async {
              setState(
                () => _recoveringSessionIds.add(session.sessionId),
              );
              final ok = await _recoverSession(session);
              if (!mounted) return;
              if (ok) {
                Navigator.of(context).pop();
              } else {
                setState(
                  () => _recoveringSessionIds.remove(session.sessionId),
                );
              }
            },
      onDiscard: busy
          ? null
          : () async {
              setState(
                () => _discardingSessionIds.add(session.sessionId),
              );
              final ok = await _discardSession(session);
              if (!mounted) return;
              setState(() {
                _discardingSessionIds.remove(session.sessionId);
                if (ok) _sessions.remove(session);
              });
              if (!ok) return;
              if (_sessions.isEmpty) {
                Navigator.of(context).pop();
              }
            },
    );
  }

  Future<void> _confirmAndDiscardAll() async {
    final count = _sessions.length;
    final sessionWord = count == 1 ? 'session' : 'sessions';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard all sessions?'),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 440,
          ),
          child: Text(
            'Discard $count $sessionWord? Their data will be marked '
            "aborted and you won't be able to resume them.",
          ),
        ),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          SkotiqButton(
            label: 'Discard',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted || _discardingAll) return;
    setState(() => _discardingAll = true);

    // Track per-session failures and surface them: a single failed
    // mark-aborted call otherwise leaves the user believing everything was
    // discarded.
    final failures = <SessionRecoveryInfo>[];
    final sessions = List<SessionRecoveryInfo>.of(_sessions);
    for (final session in sessions) {
      try {
        final sessionService = ref.read(sessionServiceProvider);
        await sessionService.markSessionAborted(session.sessionId);
      } catch (_) {
        failures.add(session);
      }
    }

    if (!mounted) return;
    if (failures.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _sessions
        ..clear()
        ..addAll(failures);
      _discardingAll = false;
    });
    final colors = SkotiqColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Failed to discard ${failures.length} of $count '
          '$sessionWord. The remaining sessions are still available to retry.',
        ),
        backgroundColor: colors.error,
      ),
    );
  }

  Future<bool> _recoverSession(SessionRecoveryInfo session) async {
    try {
      final sessionNotifier = ref.read(sessionStateProvider.notifier);
      await sessionNotifier.recoverSession(session);

      // Show success message
      if (mounted) {
        final colors = SkotiqColors.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Session recovered: ${session.sessionName ?? "Session ${session.sessionId}"}',
            ),
            backgroundColor: colors.success,
          ),
        );
      }
      return true;
    } catch (e) {
      if (mounted) {
        final colors = SkotiqColors.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                const Text('Could not recover the session. Please try again.'),
            backgroundColor: colors.error,
          ),
        );
      }
      return false;
    }
  }

  Future<bool> _discardSession(SessionRecoveryInfo session) async {
    try {
      final sessionService = ref.read(sessionServiceProvider);
      await sessionService.markSessionAborted(session.sessionId);
      return true;
    } catch (e) {
      if (mounted) {
        final colors = SkotiqColors.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                const Text('Could not discard the session. Please try again.'),
            backgroundColor: colors.error,
          ),
        );
      }
      return false;
    }
  }
}

class _SessionCard extends StatelessWidget {
  final SessionRecoveryInfo session;
  final VoidCallback? onRecover;
  final VoidCallback? onDiscard;
  final bool isRecovering;
  final bool isDiscarding;

  const _SessionCard({
    required this.session,
    required this.onRecover,
    required this.onDiscard,
    required this.isRecovering,
    required this.isDiscarding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);
    final stats = session.stats;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Session name and timestamp
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    session.sessionName ?? 'Session ${session.sessionId}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  _formatDateTime(session.startTime),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            if (session.targetName != null) ...[
              const SizedBox(height: 4),
              Text(
                'Target: ${session.targetName}',
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 8),

            // Statistics
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _StatChip(
                  icon: LucideIcons.camera,
                  label: _pluralize(stats.completedExposures, 'exposure'),
                ),
                _StatChip(
                  icon: LucideIcons.clock,
                  label: DurationFormat.of(session.duration,
                      style: DurationStyle.compact),
                ),
                _StatChip(
                  icon: LucideIcons.timer,
                  label: _formatIntegration(stats.totalIntegrationSecs),
                ),
                if (stats.avgHfr != null)
                  _StatChip(
                    icon: LucideIcons.target,
                    label: 'HFR: ${stats.avgHfr!.toStringAsFixed(2)}',
                  ),
                if (stats.failedExposures > 0)
                  _StatChip(
                    icon: LucideIcons.alertTriangle,
                    label: '${stats.failedExposures} failed',
                    color: colors.warning,
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SkotiqButton(
                  onPressed: onDiscard,
                  isLoading: isDiscarding,
                  icon: LucideIcons.trash2,
                  label: 'Discard',
                  variant: ButtonVariant.destructive,
                  size: ButtonSize.small,
                ),
                const SizedBox(width: 8),
                SkotiqButton(
                  onPressed: onRecover,
                  isLoading: isRecovering,
                  icon: LucideIcons.rotateCcw,
                  label: 'Resume',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatIntegration(double seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m total';
    }
    if (minutes > 0) {
      return '${minutes}m total';
    }
    // Sub-minute integration is meaningful (e.g. a couple of 10-second
    // calibration frames). Avoid the misleading "0m total" by reporting
    // the actual seconds when we have any, and "no integration" when we
    // genuinely have none.
    if (seconds > 0) {
      final secs = seconds.round();
      return _pluralize(secs, 'second', suffix: ' total');
    }
    return 'no integration';
  }

  String _pluralize(int count, String singular,
      {String? plural, String suffix = ''}) {
    final word = count == 1 ? singular : (plural ?? '${singular}s');
    return '$count $word$suffix';
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _StatChip({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chipColor = color ?? theme.colorScheme.primary;

    return Chip(
      avatar: Icon(icon, size: 14, color: chipColor),
      label: Text(label),
      labelStyle: theme.textTheme.bodySmall,
      visualDensity: VisualDensity.compact,
    );
  }
}
