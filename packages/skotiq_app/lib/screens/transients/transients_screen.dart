import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/transient_type_style.dart';
import 'widgets/transient_card.dart';

/// Filter options for the transient alerts list.
enum TransientFilter {
  all('All'),
  newAlerts('New'),
  queued('Queued'),
  observed('Observed');

  const TransientFilter(this.label);
  final String label;
}

/// Provider for tracking the current filter selection.
final _transientFilterProvider = StateProvider<TransientFilter>((ref) {
  return TransientFilter.all;
});

// The set of upstreams this build can actually query now lives beside
// TransientSource itself (`kFetchableTransientSources`), so this sheet and
// TransientAlertService.getAllAlerts cannot drift apart about which sources
// are real. Manual is not in it: manual alerts are entered locally, never
// fetched.

/// When the alert feed last produced a result (or an error), so the operator
/// can tell "no transients tonight" from "the fetch never ran".
///
/// The feed itself is a polling `StreamProvider` with no notion of a last
/// attempt, and clicking refresh only invalidates it: without this the screen
/// is byte-identical before and after a refresh, which makes a broken upstream
/// indistinguishable from a quiet sky.
final _lastAlertCheckProvider = StateProvider<DateTime?>((ref) => null);

/// Whether TNS is actually usable: bot identity configured in Science settings
/// AND an API key in the secrets store. The alert settings sheet has no key
/// field, so enabling the TNS chip alone changes nothing.
final _tnsCredentialsReadyProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  final science = await ref.watch(scienceSettingsProvider.future);
  if (science.tnsBotId <= 0 || science.tnsBotName.trim().isEmpty) return false;
  return ref.watch(secretsStoreProvider).has(SecretField.tnsApiKey);
});

/// Screen for managing astronomical transient alerts.
///
/// Displays a filterable list of transient alerts (novae, supernovae, comets, etc.)
/// with options to queue targets for observation, view in framing, or dismiss.
class TransientsScreen extends StatelessWidget {
  const TransientsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Scaffold(
      backgroundColor: colors.background,
      body: const SafeArea(
        bottom: false,
        child: TransientsView(),
      ),
    );
  }
}

/// Embeddable transient-alerts content: header, citizen-science strip, filter
/// bar, and the filtered alert list. Supplies no Scaffold/AppBar so it can sit
/// inside the Science screen's "Observing Alerts" tab as well as the standalone
/// [TransientsScreen].
class TransientsView extends ConsumerWidget {
  const TransientsView({super.key, this.showHeader = true});

  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final alertsAsync = ref.watch(activeTransientAlertsProvider);
    final currentFilter = ref.watch(_transientFilterProvider);

    // Stamp every completed attempt, success or failure. Done here rather than
    // in the refresh handler because the feed also polls on its own timer.
    ref.listen<AsyncValue<List<TransientAlert>>>(
      activeTransientAlertsProvider,
      (previous, next) {
        if (next.isLoading) return;
        ref.read(_lastAlertCheckProvider.notifier).state = DateTime.now();
      },
    );

    return Column(
      children: [
        if (showHeader)
          ScreenHeader(
            title: 'Observing alerts',
            icon: SkotiqIcons.sparkle,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(SkotiqIcons.refresh,
                      size: SkotiqTokens.iconMd),
                  onPressed: () => refreshTransientAlerts(ref),
                  tooltip: 'Refresh alerts',
                  color: colors.textSecondary,
                  constraints: const BoxConstraints(
                    minWidth: SkotiqTokens.minTouchTarget,
                    minHeight: SkotiqTokens.minTouchTarget,
                  ),
                ),
                IconButton(
                  icon: const Icon(SkotiqIcons.settings,
                      size: SkotiqTokens.iconMd),
                  onPressed: () => showTransientSettingsDialog(context, ref),
                  tooltip: 'Alert settings',
                  color: colors.textSecondary,
                  constraints: const BoxConstraints(
                    minWidth: SkotiqTokens.minTouchTarget,
                    minHeight: SkotiqTokens.minTouchTarget,
                  ),
                ),
              ],
            ),
          ),
        _CitizenScienceStrip(colors: colors),
        _SourceStatusStrip(colors: colors, alertsAsync: alertsAsync),
        _FilterTabBar(
          colors: colors,
          currentFilter: currentFilter,
          onFilterChanged: (filter) {
            ref.read(_transientFilterProvider.notifier).state = filter;
          },
        ),
        Expanded(
          child: alertsAsync.when(
            data: (alerts) =>
                _buildDataState(context, ref, alerts, currentFilter),
            loading: () => _buildLoadingState(),
            error: (error, stackTrace) => _buildErrorState(ref, error),
          ),
        ),
      ],
    );
  }

  Widget _buildDataState(
    BuildContext context,
    WidgetRef ref,
    List<TransientAlert> alerts,
    TransientFilter filter,
  ) {
    final states = ref.watch(transientAlertStatesProvider);

    // Filter alerts based on current filter
    final filteredAlerts = _filterAlerts(alerts, states, filter);

    if (filteredAlerts.isEmpty) {
      return _buildEmptyState(filter);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < SkotiqTokens.breakpointTablet;

        return ListView.builder(
          padding: isMobile
              ? SkotiqTokens.screenPaddingCompact
              : SkotiqTokens.screenPadding,
          itemCount: filteredAlerts.length,
          itemBuilder: (context, index) {
            final alert = filteredAlerts[index];
            final alertState = resolveTransientAlertState(alert, states);
            return Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
              child: TransientCard(
                key: ValueKey(alert.id),
                alert: alert,
                state: alertState,
                onQueue: () => _queueAlert(context, ref, alert),
                onPlan: () => _planAlert(context),
                onViewInFraming: () => _viewInFraming(context, ref, alert),
                onOpenScience: () => _openScience(context, alert),
                onDismiss: () => _dismissAlert(context, ref, alert),
              ),
            );
          },
        );
      },
    );
  }

  List<TransientAlert> _filterAlerts(
    List<TransientAlert> alerts,
    Map<String, TransientAlertState> states,
    TransientFilter filter,
  ) {
    switch (filter) {
      case TransientFilter.all:
        return alerts;
      // Every branch resolves through `resolveTransientAlertState` so a
      // detection confirmed in First Light leaves the "New" bucket here too.
      case TransientFilter.newAlerts:
        return alerts
            .where((alert) =>
                resolveTransientAlertState(alert, states) ==
                TransientAlertState.newAlert)
            .toList();
      case TransientFilter.queued:
        return alerts
            .where((alert) =>
                resolveTransientAlertState(alert, states) ==
                TransientAlertState.queued)
            .toList();
      case TransientFilter.observed:
        return alerts
            .where((alert) =>
                resolveTransientAlertState(alert, states) ==
                TransientAlertState.observed)
            .toList();
    }
  }

  Widget _buildLoadingState() {
    return ShimmerLoading(
      child: ListView.builder(
        padding: SkotiqTokens.screenPadding,
        itemCount: 5,
        itemBuilder: (context, index) {
          return const Padding(
            padding: EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
            child: _TransientCardSkeleton(),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(TransientFilter filter) {
    final String message;
    final IconData icon;

    switch (filter) {
      case TransientFilter.all:
        message = 'No transient alerts';
        icon = SkotiqIcons.sparkle;
      case TransientFilter.newAlerts:
        message = 'No new alerts';
        icon = SkotiqIcons.notificationsOff;
      case TransientFilter.queued:
        message = 'No queued alerts';
        icon = SkotiqIcons.checklist;
      case TransientFilter.observed:
        message = 'No observed alerts';
        icon = SkotiqIcons.visible;
    }

    return EmptyState(
      icon: icon,
      title: message,
      body: filter == TransientFilter.all
          // Names only the upstream this build queries. "and other sources"
          // implied AAVSO/MPEC/CBAT monitoring that never happens.
          ? 'Alerts from TNS appear here. The strip above shows what each '
              'enabled source returned on the last check.'
          : 'No alerts match the current filter.',
    );
  }

  Widget _buildErrorState(WidgetRef ref, Object error) {
    return EmptyState(
      icon: LucideIcons.alertCircle,
      title: 'Failed to load transient alerts',
      body: error.toString(),
      action: SkotiqButton(
        label: 'Retry',
        icon: SkotiqIcons.refresh,
        onPressed: () => refreshTransientAlerts(ref),
      ),
    );
  }

  Future<void> _queueAlert(
      BuildContext context, WidgetRef ref, TransientAlert alert) async {
    await queueTransientForTonight(ref, alert);
  }

  void _planAlert(BuildContext context) {
    context.go('/planner?tab=scheduler');
  }

  void _viewInFraming(
      BuildContext context, WidgetRef ref, TransientAlert alert) {
    // Seed the target before navigating: the /framing route redirects to
    // /planner?tab=sky&view=framing, which drops any query params.
    ref.read(framingProvider.notifier).setTargetCoordinates(
          alert.raHours,
          alert.decDegrees,
          name: alert.name,
        );
    context.goNamed('framing');
  }

  void _openScience(BuildContext context, TransientAlert alert) {
    context.go('/science');
  }

  Future<void> _dismissAlert(
    BuildContext context,
    WidgetRef ref,
    TransientAlert alert,
  ) async {
    try {
      await ref.read(transientAlertStatesProvider.notifier).dismiss(alert.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not dismiss this alert.')),
        );
      }
    }
  }
}

/// Opens the transient alert settings dialog. Shared by [TransientsView] and the
/// Science screen header when the view is embedded without its own header.
void showTransientSettingsDialog(BuildContext context, WidgetRef ref) {
  showDialog(
    context: context,
    builder: (context) => const _TransientSettingsDialog(),
  );
}

/// Framing strip presenting transient alerts as a citizen-science feed.
class _CitizenScienceStrip extends StatelessWidget {
  final SkotiqColors colors;

  const _CitizenScienceStrip({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            decoration: SkotiqDecorations.tintedBadge(colors.info),
            child: Icon(
              LucideIcons.microscope,
              size: SkotiqTokens.iconSm,
              color: colors.info,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              'Real targets for citizen science. Queue an alert, capture it, '
              'and turn the result into a photometric or astrometric report.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-source result of the last fetch, plus when that fetch happened.
///
/// Without this the surface could not distinguish "no transients tonight" from
/// "this feature is broken": refresh produced no spinner, no timestamp, no
/// count and no error, and a source that is enabled but unusable (TNS with no
/// API key) looked exactly like one that ran and found nothing.
class _SourceStatusStrip extends ConsumerWidget {
  final SkotiqColors colors;
  final AsyncValue<List<TransientAlert>> alertsAsync;

  const _SourceStatusStrip({required this.colors, required this.alertsAsync});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(transientAlertSettingsProvider);
    final lastCheck = ref.watch(_lastAlertCheckProvider);
    final tnsReady = ref.watch(_tnsCredentialsReadyProvider).valueOrNull;
    final alerts = alertsAsync.valueOrNull;

    final enabledFetchable = kFetchableTransientSources
        .where(settings.enabledSources.contains)
        .toList();

    final parts = <String>[];
    if (alertsAsync.isLoading) {
      parts.add('Checking sources…');
    } else if (enabledFetchable.isEmpty) {
      parts.add('No alert source is enabled');
    } else {
      for (final source in enabledFetchable) {
        final label = _sourceLabel(source);
        if (source == TransientSource.tns && tnsReady == false) {
          // Enabling TNS here does nothing on its own: the key lives in
          // Settings > Science, and this sheet has no field for it.
          parts.add('$label: skipped — no API key');
          continue;
        }
        if (alertsAsync.hasError) {
          parts.add('$label: failed');
          continue;
        }
        if (alerts == null) {
          parts.add('$label: not checked yet');
          continue;
        }
        final count = alerts.where((a) => a.source == source).length;
        parts.add('$label: $count ${count == 1 ? 'alert' : 'alerts'}');
      }
    }
    parts.add(
      lastCheck == null
          ? 'never checked'
          : 'checked ${_formatClock(lastCheck)}',
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (alertsAsync.isLoading)
            Padding(
              padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
              child: SizedBox(
                width: 12,
                height: 12,
                child: SkotiqSpinner(size: 12, color: colors.primary),
              ),
            ),
          Expanded(
            child: Text(
              parts.join(' · '),
              style: SkotiqTypography.captionSm.copyWith(
                color: alertsAsync.hasError ? colors.error : colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatClock(DateTime time) {
  final local = time.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

String _sourceLabel(TransientSource source) {
  switch (source) {
    case TransientSource.aavso:
      return 'AAVSO';
    case TransientSource.tns:
      return 'TNS';
    case TransientSource.mpec:
      return 'MPEC';
    case TransientSource.cbat:
      return 'CBAT';
    case TransientSource.manual:
      return 'Manual';
  }
}

/// Filter tab bar for switching between alert categories.
class _FilterTabBar extends StatelessWidget {
  final SkotiqColors colors;
  final TransientFilter currentFilter;
  final ValueChanged<TransientFilter> onFilterChanged;

  const _FilterTabBar({
    required this.colors,
    required this.currentFilter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: TransientFilter.values.map((filter) {
            return Padding(
              padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
              child: SkotiqChip(
                label: filter.label,
                selected: filter == currentFilter,
                onTap: () => onFilterChanged(filter),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// Skeleton loading cards for transient items.
class _TransientCardSkeleton extends StatelessWidget {
  const _TransientCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkotiqCard(
      variant: CardVariant.subtle,
      borderRadius: SkotiqTokens.radiusLg,
      padding: SkotiqTokens.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SkeletonBox(
                  width: 32, height: 32, borderRadius: SkotiqTokens.radiusMd),
              SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 150, height: 16),
                    SizedBox(height: SkotiqTokens.spaceXs),
                    SkeletonBox(width: 80, height: 12),
                  ],
                ),
              ),
              SkeletonBox(
                  width: 60, height: 24, borderRadius: SkotiqTokens.radiusFull),
            ],
          ),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(width: double.infinity, height: 14),
          SizedBox(height: SkotiqTokens.spaceSm),
          SkeletonBox(width: 200, height: 14),
          SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            children: [
              SkeletonBox(
                  width: 80, height: 32, borderRadius: SkotiqTokens.radiusSm),
              SizedBox(width: SkotiqTokens.spaceSm),
              SkeletonBox(
                  width: 100, height: 32, borderRadius: SkotiqTokens.radiusSm),
              SizedBox(width: SkotiqTokens.spaceSm),
              SkeletonBox(
                  width: 70, height: 32, borderRadius: SkotiqTokens.radiusSm),
            ],
          ),
        ],
      ),
    );
  }
}

/// Settings dialog for configuring transient alert preferences.
class _TransientSettingsDialog extends ConsumerStatefulWidget {
  const _TransientSettingsDialog();

  @override
  ConsumerState<_TransientSettingsDialog> createState() =>
      _TransientSettingsDialogState();
}

class _TransientSettingsDialogState
    extends ConsumerState<_TransientSettingsDialog> {
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the alert settings.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final settings = ref.watch(transientAlertSettingsProvider);
    final notifier = ref.read(transientAlertSettingsProvider.notifier);

    return SkotiqDialog(
      title: 'Alert settings',
      icon: SkotiqIcons.settings,
      width: 400,
      actions: [
        SkotiqButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Alert Sources',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: TransientSource.values.map((source) {
              // Manual alerts are entered locally rather than fetched, so they
              // stay a real toggle; MPEC and CBAT have no fetch path at all.
              final available = kFetchableTransientSources.contains(source) ||
                  source == TransientSource.manual;
              return SkotiqChip(
                label: available
                    ? _sourceLabel(source)
                    : '${_sourceLabel(source)} — not available',
                // Never rendered as monitored: the service would ignore the
                // stored flag anyway, and showing it selected was the lie.
                selected: available && settings.enabledSources.contains(source),
                // Carries the unavailability in the chip's appearance, not only
                // in a suffix bolted onto its label.
                enabled: available,
                onTap: available
                    ? () => _run(() => notifier.toggleSource(source))
                    : null,
              );
            }).toList(),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'TNS is the only feed this build queries, and it needs a bot ID, '
            'bot name and API key from Settings > Science. AAVSO, MPEC and '
            'CBAT have no working feed: VSX answers positional catalog '
            'queries, not alert notices.',
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            'Transient Types',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: TransientType.values.map((type) {
              return SkotiqChip(
                label: TransientTypeStyle.shortLabel(type),
                selected: settings.typesToMonitor.contains(type),
                onTap: () => _run(() => notifier.toggleType(type)),
              );
            }).toList(),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            'Magnitude Threshold',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: SkotiqSlider(
                  value: settings.magnitudeThreshold,
                  min: 5.0,
                  max: 20.0,
                  divisions: 30,
                  onChanged: (value) =>
                      _run(() => notifier.setMagnitudeThreshold(value)),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              SizedBox(
                width: 50,
                child: Text(
                  'mag ${settings.magnitudeThreshold.toStringAsFixed(1)}',
                  style: SkotiqTypography.monoSm
                      .copyWith(color: colors.textSecondary),
                ),
              ),
            ],
          ),
          Text(
            'Only show alerts brighter than this magnitude',
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqSwitchRow(
            label: 'Notifications',
            subtitle: 'Show notifications for new alerts',
            value: settings.notifyOnNew,
            onChanged: (value) => _run(() => notifier.setNotifyOnNew(value)),
          ),
        ],
      ),
    );
  }
}
