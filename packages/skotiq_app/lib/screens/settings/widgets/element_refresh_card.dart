import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import '../../accessible_dropdown.dart';

/// Settings card for **live MPC orbital-element refresh** — fetching fresh
/// minor-planet (MPCORB) and comet (CometEls) elements on a schedule.
///
/// Refreshed bodies feed the planetarium's minor-planet overlay and the
/// omnibox search. Offline-safe: a failed refresh keeps the cached set and the
/// "last updated" line reflects the cache age.
///
/// The auto-refresh schedule selector is gated on the config authority
/// ([elementRefreshConfigProvider]): while the persisted config is loading it
/// shows a spinner, and if it is unreadable/corrupt it shows an error with a
/// Retry action instead of a writable control seeded from manufactured
/// defaults — otherwise a save would overwrite the corrupt file with defaults
/// the user never chose.
class ElementRefreshCard extends ConsumerStatefulWidget {
  const ElementRefreshCard({super.key});

  @override
  ConsumerState<ElementRefreshCard> createState() => _ElementRefreshCardState();
}

class _ElementRefreshCardState extends ConsumerState<ElementRefreshCard> {
  /// Synchronous double-submit guard for the async schedule save. Set the
  /// instant a save starts so a second dropdown selection cannot race a write
  /// in flight, and it also drives the inline "saving…" indicator.
  bool _savingSchedule = false;

  /// Detail of the last failed schedule save, shown inline. Cleared when a new
  /// save starts or one succeeds.
  String? _saveError;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final status = ref.watch(elementRefreshControllerProvider);
    final controller = ref.read(elementRefreshControllerProvider.notifier);
    final configAsync = ref.watch(elementRefreshConfigProvider);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: status.hasData
              ? colors.success.withValues(alpha: 0.3)
              : colors.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.refresh, color: colors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Minor Planets & Comets (MPC)',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            // Names the file actually fetched. The default source is the Minor
            // Planet Center's Bright Minor Planets ephemeris — a few hundred
            // bodies — not the 1.4-million-object MPCORB master, so an observer
            // who cannot find their asteroid is out of range, not broken.
            'Downloads the Minor Planet Center\'s current bright-asteroid '
            'elements (Soft00Bright — the few hundred asteroids bright enough '
            'to observe, not the full MPCORB) and its comet elements '
            '(CometEls). Refreshed bodies appear in the planetarium overlay '
            'and search. Satellite TLEs (CelesTrak) refresh on their own '
            '24-hour cache when the satellite layer is on.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          // Last-updated indicator.
          Row(
            children: [
              Icon(
                status.hasData
                    ? SkotiqIcons.success
                    : SkotiqIcons.circle,
                size: 14,
                color: status.hasData ? colors.success : colors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.lastUpdated != null
                      ? 'Oldest source updated ${_fmt(status.lastUpdated!)} • '
                          '${status.asteroidCount} bright asteroids, '
                          '${status.cometCount} comets'
                      : 'Using bundled elements — never refreshed',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (status.error != null) ...[
            const SizedBox(height: 8),
            Text(
              'Last refresh failed: ${status.error}',
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Schedule selector, gated on the config authority.
          _buildScheduleSection(colors, configAsync, status),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: SkotiqButton(
              label: status.isRefreshing ? 'Refreshing…' : 'Refresh now',
              icon: SkotiqIcons.download,
              variant: ButtonVariant.secondary,
              onPressed: status.isRefreshing
                  ? null
                  : () async {
                      await controller.refresh();
                      if (!context.mounted) return;
                      // Always acknowledge the press: a refresh that ends in a
                      // partial or total failure otherwise leaves only a small
                      // status line to notice.
                      final result = ref.read(elementRefreshControllerProvider);
                      if (result.error case final failure?) {
                        context.showErrorSnackBar(
                          'Element refresh failed: $failure',
                        );
                      } else {
                        context.showSuccessSnackBar(
                          'Elements refreshed — ${result.asteroidCount} bright '
                          'asteroids, ${result.cometCount} comets',
                        );
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleSection(
    SkotiqColors colors,
    AsyncValue<ElementRefreshConfig> configAsync,
    ElementRefreshStatus status,
  ) {
    // Error takes priority over a stale value: never render a writable control
    // from a defaulted/corrupt authority.
    if (configAsync.hasError) {
      return _configAuthorityUnavailable(colors, configAsync.error);
    }
    if (!configAsync.hasValue) {
      return _configAuthorityLoading(colors);
    }

    final config = configAsync.requireValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Auto-refresh:',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: 12),
            AccessibleDropdown<ElementRefreshSchedule>(
              value: config.schedule,
              dropdownColor: colors.surface,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
              items: ElementRefreshSchedule.values
                  .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s.displayName),
                      ))
                  .toList(),
              // Disabled while a save is in flight (double-submit guard) or a
              // refresh is running.
              onChanged: (status.isRefreshing || _savingSchedule)
                  ? null
                  : (s) => _saveSchedule(s, config),
            ),
            if (_savingSchedule) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
            ],
          ],
        ),
        if (_saveError != null) ...[
          const SizedBox(height: 6),
          Text(
            'Could not save schedule: $_saveError',
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _configAuthorityLoading(SkotiqColors colors) {
    return Row(
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.primary,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'Loading refresh configuration…',
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _configAuthorityUnavailable(SkotiqColors colors, Object? error) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(SkotiqIcons.warning, size: 16, color: colors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Auto-refresh configuration unavailable',
                style: SkotiqTypography.buttonSm.copyWith(
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${error ?? 'Unknown error'}',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        SkotiqButton(
          label: 'Retry',
          icon: SkotiqIcons.refresh,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _retryConfig,
        ),
      ],
    );
  }

  /// Re-read the config authority and let the controller re-init so a
  /// recovered config clears both the settings UI error and any stale
  /// init-time controller error.
  void _retryConfig() {
    setState(() => _saveError = null);
    // Bumping the reload token recomputes the config + cached providers; the
    // controller rebuild re-runs its (config-aware) init.
    ref.read(elementRefreshReloadProvider.notifier).state++;
    ref.invalidate(elementRefreshControllerProvider);
  }

  Future<void> _saveSchedule(
    ElementRefreshSchedule? schedule,
    ElementRefreshConfig current,
  ) async {
    if (schedule == null || schedule == current.schedule) return;
    // Synchronous guard: a second selection cannot enter while a write is in
    // flight (belt-and-suspenders with the disabled onChanged).
    if (_savingSchedule) return;

    setState(() {
      _savingSchedule = true;
      _saveError = null;
    });

    // Capture the exact service instance we persist through. If the authority
    // is swapped out from under us mid-await, we must not report the write as a
    // success on a service that no longer backs the app.
    final service = ref.read(elementRefreshServiceProvider);
    try {
      await service.saveConfig(current.copyWith(schedule: schedule));
      if (!mounted) return;

      if (!identical(service, ref.read(elementRefreshServiceProvider))) {
        // Authority changed during the save: don't claim success. Reload from
        // the current authority and drop the in-flight state.
        setState(() {
          _savingSchedule = false;
          _saveError = 'Configuration authority changed during the save.';
        });
        ref.read(elementRefreshReloadProvider.notifier).state++;
        return;
      }

      // Only touch providers after the write actually committed, so the
      // dropdown never visually commits a value that was not persisted.
      ref.read(elementRefreshReloadProvider.notifier).state++;
      setState(() => _savingSchedule = false);
      if (context.mounted) {
        context.showSuccessSnackBar(
          'Auto-refresh set to ${schedule.displayName}',
        );
      }
    } catch (e) {
      if (!mounted) return;
      // Leave the prior confirmed selection visible (we did not invalidate the
      // config provider) and surface the failure so the user can retry.
      setState(() {
        _savingSchedule = false;
        _saveError = '$e';
      });
    }
  }

  String _fmt(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
