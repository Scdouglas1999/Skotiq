import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/transient_type_style.dart';
import '../../../utils/user_facing_error.dart';

part 'transient_alerts_panel_parts/_alert_tiles.dart';
part 'transient_alerts_panel_parts/_settings_dialog.dart';

Future<void> _runAlertStateAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update this alert.')),
      );
    }
  }
}

/// Whether TNS credentials are on record, so the panel can say why a fetch is
/// unavailable rather than reporting an empty feed.
final transientPanelTnsCredentialsReadyProvider =
    FutureProvider<bool>((ref) async {
  if (ref.watch(isRemoteModeProvider)) return true;
  final science = await ref.watch(scienceSettingsProvider.future);
  if (science.tnsBotId <= 0 || science.tnsBotName.trim().isEmpty) return false;
  return ref.watch(secretsStoreProvider).has(SecretField.tnsApiKey);
});

/// Panel displaying astronomical transient alerts (novae, supernovae, …) with
/// the ability to queue them as observation targets.
///
/// Shows recent alerts from the fetched sources ([kFetchableTransientSources] —
/// today, TNS alone), sorted by priority. The source label still renders every
/// [TransientSource], because an alert stored, imported or entered by hand
/// carries its own origin. Each alert shows name, type, magnitude, coordinates
/// and discovery date.
class TransientAlertsPanel extends ConsumerStatefulWidget {
  final bool initiallyExpanded;

  const TransientAlertsPanel({super.key, this.initiallyExpanded = true});

  @override
  ConsumerState<TransientAlertsPanel> createState() =>
      _TransientAlertsPanelState();
}

class _TransientAlertsPanelState extends ConsumerState<TransientAlertsPanel> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final alertsAsync = ref.watch(activeTransientAlertsProvider);
    final alertStates = ref.watch(transientAlertStatesProvider);
    final settings = ref.watch(transientAlertSettingsProvider);
    final credentials = ref.watch(transientPanelTnsCredentialsReadyProvider);
    final feedCheck = ref.watch(transientFeedCheckProvider);
    final tnsNeedsSetup =
        settings.enabledSources.contains(TransientSource.tns) &&
            credentials.valueOrNull == false;
    final collapsedSummary = alertsAsync.when(
      loading: () => ('Checking for alerts…', colors.textMuted),
      error: (error, _) => tnsNeedsSetup
          ? ('Setup needed for live TNS alerts', colors.warning)
          : ('Fetch failed: ${userFacingError(error)}', colors.error),
      data: (alerts) {
        if (tnsNeedsSetup) {
          return ('Setup needed for live TNS alerts', colors.warning);
        }
        if (alerts.isEmpty) {
          final (label, unchecked) = _emptyFeedSummary(feedCheck);
          return (label, unchecked ? colors.warning : colors.textMuted);
        }
        final sorted = _sortForDisplay(alerts, alertStates);
        final top = sorted.first;
        final magnitude = top.magnitude == null
            ? ''
            : ', mag ${top.magnitude!.toStringAsFixed(1)}';
        return (
          '${alerts.length} alert${alerts.length == 1 ? '' : 's'} · '
              '${top.name}$magnitude',
          colors.textSecondary,
        );
      },
    );

    return SkotiqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
            child: Row(
              children: [
                Icon(LucideIcons.zap, size: 18, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Transient Alerts',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize15,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                // Unacknowledged badge
                _UnacknowledgedBadge(colors: colors),
                const SizedBox(width: 4),
                // Checking is otherwise on a 15-minute timer with no way to ask
                // now — and no way to tell "nothing is happening" from "nothing
                // was asked".
                IconButton(
                  key: const ValueKey('transient_check_now'),
                  icon: Icon(LucideIcons.refreshCw,
                      size: 16, color: colors.textSecondary),
                  tooltip: 'Check for alerts now',
                  onPressed: () => refreshTransientAlerts(ref),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: Icon(
                      _expanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 16,
                      color: colors.textSecondary),
                  tooltip: _expanded ? 'Collapse alerts' : 'Expand alerts',
                  onPressed: () => setState(() => _expanded = !_expanded),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: Icon(LucideIcons.settings,
                      size: 16, color: colors.textSecondary),
                  tooltip: 'Alert settings',
                  onPressed: () => _showSettingsDialog(context, ref),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          if (!_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                collapsedSummary.$1,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: collapsedSummary.$2,
                ),
              ),
            )
          else
            // Alert list
            alertsAsync.when(
              data: (alerts) {
                if (alerts.isEmpty) {
                  if (tnsNeedsSetup) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(LucideIcons.info,
                              size: 16, color: colors.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'TNS alerts are enabled but not configured. Add '
                              'your bot credentials in Science settings to fetch '
                              'live alerts; manual alerts remain available.',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize12,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final (headline, unchecked) = _emptyFeedSummary(feedCheck);
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            unchecked
                                ? LucideIcons.alertTriangle
                                : LucideIcons.bellOff,
                            size: 32,
                            color:
                                unchecked ? colors.warning : colors.textMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            headline,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize13,
                              color: unchecked
                                  ? colors.warning
                                  : colors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _emptyFeedDetail(feedCheck),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize11,
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                // Show up to 10 alerts, with actionable ones first
                final displayAlerts = _sortForDisplay(alerts, alertStates);
                final limited = displayAlerts.take(10).toList();

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < limited.length; i++) ...[
                      _TransientAlertTile(
                        key: ValueKey(limited[i].id),
                        alert: limited[i],
                        alertState: resolveTransientAlertState(
                          limited[i],
                          alertStates,
                        ),
                      ),
                      if (i < limited.length - 1)
                        Divider(
                          height: 1,
                          indent: 16,
                          endIndent: 16,
                          color: colors.border,
                        ),
                    ],
                    if (alerts.length > 10)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '${alerts.length - 10} more alerts not shown',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textMuted,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      tnsNeedsSetup
                          ? LucideIcons.settings
                          : LucideIcons.alertTriangle,
                      size: 16,
                      color: tnsNeedsSetup ? colors.warning : colors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tnsNeedsSetup
                            ? 'Setup needed for live TNS alerts'
                            : 'Failed to load alerts: ${userFacingError(error)}',
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize12,
                            color:
                                tnsNeedsSetup ? colors.warning : colors.error),
                      ),
                    ),
                    if (!tnsNeedsSetup)
                      IconButton(
                        icon: Icon(LucideIcons.refreshCw,
                            size: 14, color: colors.error),
                        tooltip: 'Retry',
                        onPressed: () => refreshTransientAlerts(ref),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The headline for an empty feed, and whether that emptiness is untrustworthy
  /// because nothing was actually polled.
  ///
  /// "No active alerts" and "we never asked anyone" look identical from the
  /// alert list, and on the app's only channel for time-critical events that is
  /// exactly the wrong ambiguity: enabling AAVSO alone (which no build fetches)
  /// produced a confident empty state.
  (String, bool) _emptyFeedSummary(TransientFeedCheck? check) {
    if (check == null) return ('Not checked yet', true);
    if (!check.contactedAnySource) {
      return ('No alert source is being checked', true);
    }
    return ('No active alerts · checked ${_ago(check.checkedAt)}', false);
  }

  String _emptyFeedDetail(TransientFeedCheck? check) {
    if (check == null) {
      return 'The first check runs when this screen opens.';
    }
    if (check.skippedSources.isNotEmpty) {
      final reasons = check.skippedSources.entries
          .map((entry) => '${_transientSourceLabel(entry.key)}: ${entry.value}')
          .join('; ');
      return check.contactedAnySource
          ? 'Not polled — $reasons.'
          : 'Nothing was polled — $reasons.';
    }
    return check.contactedAnySource
        ? 'Adjust the magnitude threshold or monitored types to widen the net.'
        : 'Enable an alert source in the settings above.';
  }

  String _ago(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return DateFormat.yMMMd().add_Hm().format(when.toLocal());
  }

  List<TransientAlert> _sortForDisplay(
    List<TransientAlert> alerts,
    Map<String, TransientAlertState> states,
  ) {
    final sorted = List<TransientAlert>.from(alerts);
    sorted.sort((a, b) {
      final aState = resolveTransientAlertState(a, states);
      final bState = resolveTransientAlertState(b, states);

      // New/unacknowledged first
      final aActionable = aState == TransientAlertState.newAlert ||
          aState == TransientAlertState.acknowledged;
      final bActionable = bState == TransientAlertState.newAlert ||
          bState == TransientAlertState.acknowledged;

      if (aActionable && !bActionable) return -1;
      if (!aActionable && bActionable) return 1;

      // Then by priority
      return a.priority.compareTo(b.priority);
    });
    return sorted;
  }

  void _showSettingsDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => _TransientSettingsDialog(),
    );
  }
}
