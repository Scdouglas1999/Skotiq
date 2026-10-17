import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../widgets/help/field_help_copy.dart';
import 'settings_widgets.dart';

/// Shared "Solve parameters" editor — timeout, search radius, blind-solve, and
/// the centering mount sync.
///
/// Single source of truth for these runtime knobs so the in-shell
/// Settings → Plate Solving section and the dedicated `/settings/plate-solving`
/// screen never diverge. All persist through [AppSettingsNotifier]
/// (`plate_solve_timeout` / `plate_solve_search_radius` / `blind_solve` /
/// `centering_sync_mount`); the desktop solve path honours them via
/// `PlateSolveService.solveWithFallback` and the headless handlers read them
/// directly.
class PlateSolveParametersSection extends ConsumerStatefulWidget {
  const PlateSolveParametersSection({super.key});

  @override
  ConsumerState<PlateSolveParametersSection> createState() =>
      _PlateSolveParametersSectionState();
}

class _PlateSolveParametersSectionState
    extends ConsumerState<PlateSolveParametersSection> {
  final _timeoutController = TextEditingController();
  final _radiusController = TextEditingController();

  @override
  void dispose() {
    _timeoutController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => const SettingsSection(
        title: 'Solve parameters',
        children: [
          SettingRow(
            icon: LucideIcons.loader,
            title: 'Loading…',
            subtitle: 'Reading saved solve parameters',
            trailing: SizedBox.shrink(),
            isLast: true,
          ),
        ],
      ),
      error: (error, _) => SettingsSection(
        title: 'Solve parameters',
        children: [
          SettingRow(
            icon: LucideIcons.alertCircle,
            title: 'Failed to load solve parameters',
            subtitle: '$error',
            trailing: const SizedBox.shrink(),
            isLast: true,
          ),
        ],
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        return SettingsSection(
          title: 'Solve parameters',
          children: [
            SettingRow(
              icon: LucideIcons.timer,
              title: 'Timeout',
              subtitle: 'Maximum time to attempt a solve before giving up',
              trailing: SettingsNumberInput(
                controller: _timeoutController,
                authoritativeValue: settings.plateSolveTimeout.toDouble(),
                authorityKey: authority,
                suffix: 'sec',
                min: 10,
                max: 300,
                decimals: 0,
                onChanged: (value) {
                  return ref
                      .read(appSettingsProvider.notifier)
                      .setPlateSolveTimeout(value.toInt());
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.search,
              title: 'Search radius',
              helpId: FieldHelpId.plateSolverSearchRadius,
              subtitle: 'How far around the expected position to search',
              trailing: SettingsNumberInput(
                controller: _radiusController,
                authoritativeValue: settings.plateSolveSearchRadius,
                authorityKey: authority,
                suffix: '°',
                min: 1,
                max: 180,
                decimals: 1,
                onChanged: (value) {
                  return ref
                      .read(appSettingsProvider.notifier)
                      .setPlateSolveSearchRadius(value);
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.compass,
              title: 'Blind solve',
              subtitle: 'Always ignore position hints (slower, but useful '
                  'when the mount reports the wrong position)',
              trailing: SettingsSwitch(
                value: settings.blindSolve,
                onChanged: (value) {
                  return ref
                      .read(appSettingsProvider.notifier)
                      .setBlindSolve(value);
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.crosshair,
              title: 'Sync mount when centering',
              subtitle: 'Sync the mount to each solved position so Slew & '
                  'Center converges. Turn off only for mounts that build a '
                  'pointing model from syncs',
              trailing: SettingsSwitch(
                value: settings.centeringSyncMount,
                onChanged: (value) {
                  return ref
                      .read(appSettingsProvider.notifier)
                      .setCenteringSyncMount(value);
                },
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }
}
