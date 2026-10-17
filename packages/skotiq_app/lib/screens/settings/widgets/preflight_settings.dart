// Pre-flight strictness settings UI.
//
// The Rust executor (and the Dart-side PreflightCheckService) runs a
// battery of checks before a sequence starts: time drift, mount park
// state, dark-frame coverage, polar-alignment age, focuser travel, etc.
// Each check raises an issue at one of three severities. The strictness
// mode chosen here decides the floor severity at which the sequence is
// allowed to start:
//
//   * Lax    — everything is informational; only critical equipment
//              failures block the sequence (mount not parked, camera
//              offline). Missing darks render as info.
//   * Normal — issues raise to *warning*. The sequence still starts but
//              the user has to confirm the warnings list.
//   * Strict — issues raise to *error*. The sequence refuses to start
//              until every flagged item is acknowledged or fixed.
//
// Polar-alignment max age is its own knob because it has a clear unit
// (days) and changes with seeing / mount mechanical drift expectations.
//
// Reactive bridge: changing strictness republishes the
// `appSettingsProvider`, which the pre-flight dialog watches via
// `.select((s) => s.preflightStrictness)` so a live dialog re-grades
// the existing issue list immediately.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';

class PreflightSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const PreflightSettings({
    super.key,
    this.isMobile = false,
  });

  @override
  ConsumerState<PreflightSettings> createState() => _PreflightSettingsState();
}

class _PreflightSettingsState extends ConsumerState<PreflightSettings> {
  final _polarAgeController = TextEditingController();

  @override
  void dispose() {
    _polarAgeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, _) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final notifier = ref.read(appSettingsProvider.notifier);
        return SettingsPage(
          title: 'Pre-flight checks',
          description:
              'How strict should Skotiq be about issues raised before a sequence starts?',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile,
          children: [
            RadioGroup<PreflightStrictness>(
              groupValue: settings.preflightStrictness,
              onChanged: (value) async {
                if (value != null) {
                  await notifier.setPreflightStrictness(value);
                }
              },
              child: SettingsSection(
                title: 'Strictness',
                children: [
                  _StrictnessOption(
                    isMobile: widget.isMobile,
                    value: PreflightStrictness.lax,
                    current: settings.preflightStrictness,
                    title: 'Lax',
                    description:
                        'Missing darks render as info. Only critical equipment failures block the run.',
                    icon: LucideIcons.feather,
                    onSelected: () async {
                      await notifier
                          .setPreflightStrictness(PreflightStrictness.lax);
                    },
                  ),
                  _StrictnessOption(
                    isMobile: widget.isMobile,
                    value: PreflightStrictness.normal,
                    current: settings.preflightStrictness,
                    title: 'Normal',
                    description:
                        'Missing darks render as warnings. Sequence starts after the user confirms the warnings list.',
                    icon: LucideIcons.scale,
                    onSelected: () async {
                      await notifier
                          .setPreflightStrictness(PreflightStrictness.normal);
                    },
                  ),
                  _StrictnessOption(
                    isMobile: widget.isMobile,
                    value: PreflightStrictness.strict,
                    current: settings.preflightStrictness,
                    title: 'Strict',
                    description:
                        'Missing darks render as errors. Sequence refuses to start until every flagged issue is resolved or acknowledged.',
                    icon: LucideIcons.shieldAlert,
                    isLast: true,
                    onSelected: () async {
                      await notifier
                          .setPreflightStrictness(PreflightStrictness.strict);
                    },
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: 'Polar alignment',
              children: [
                SettingRow(
                  icon: LucideIcons.compass,
                  title: 'Polar alignment max age',
                  subtitle:
                      'Sequence pre-flight flags the polar alignment if the last recorded run is older than this. Set to 0 to disable the check.',
                  trailing: SettingsNumberInput(
                    controller: _polarAgeController,
                    authoritativeValue:
                        settings.polarAlignmentMaxAgeDays.toDouble(),
                    authorityKey: authority,
                    suffix: 'days',
                    min: 0,
                    max: 90,
                    decimals: 0,
                    onChanged: (value) async {
                      await notifier.setPolarAlignmentMaxAgeDays(value.toInt());
                    },
                    isMobile: widget.isMobile,
                  ),
                  isLast: true,
                ),
              ],
            ),
            _LivePreviewCard(
              strictness: settings.preflightStrictness,
              polarAgeDays: settings.polarAlignmentMaxAgeDays,
            ),
          ],
        );
      },
    );
  }
}

/// One radio-style row inside the strictness selector.
class _StrictnessOption extends StatelessWidget {
  final bool isMobile;
  final PreflightStrictness value;
  final PreflightStrictness current;
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onSelected;
  final bool isLast;

  const _StrictnessOption({
    required this.isMobile,
    required this.value,
    required this.current,
    required this.title,
    required this.description,
    required this.icon,
    required this.onSelected,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final selected = value == current;
    return InkWell(
      key: ValueKey('preflightStrictness_${value.persistedName}'),
      onTap: onSelected,
      child: SettingRow(
        icon: icon,
        iconColor: selected ? colors.primary : null,
        title: title,
        subtitle: description,
        trailing: Radio<PreflightStrictness>(
          value: value,
        ),
        isLast: isLast,
        isMobile: isMobile,
      ),
    );
  }
}

/// Bottom info panel that explains in plain English what the current
/// strictness mode will do at run time.
class _LivePreviewCard extends StatelessWidget {
  final PreflightStrictness strictness;
  final int polarAgeDays;

  const _LivePreviewCard({
    required this.strictness,
    required this.polarAgeDays,
  });

  /// The checks whose severity actually tracks the strictness knob, named in
  /// the same words the pre-flight dialog uses.
  ///
  /// Composed from the live configuration rather than hard-coded, because a
  /// disabled check must not be listed as one that will stop the run:
  /// `PolarAlignmentFreshnessRule` returns nothing at all when
  /// `polarAlignmentMaxAgeDays <= 0`, so naming stale polar alignment at 0
  /// would contradict the "check is disabled" line printed directly beneath
  /// it.
  List<String> get _gradedChecks => [
        'missing darks for the planned exposures',
        // TimeSyncRule grades drift from its *warning* threshold up; the 30 s
        // error threshold is unconditional (see the always-blocks line below),
        // so quoting 30 s here understated what Normal/Strict actually flag.
        'clock drift over ${TimeSyncRule.warningThresholdSecs.toStringAsFixed(0)}s',
        if (polarAgeDays > 0) 'stale polar alignment',
        'focuser at travel limit',
      ];

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final checks = _gradedChecks.join(', ');
    final lines = <String>[];
    switch (strictness) {
      case PreflightStrictness.lax:
        lines.addAll([
          'Sequence start will proceed with $checks — those become info notes.',
          'Only critical equipment failures (camera not connected, mount in error state, weather unsafe) block the run.',
          // TimeSyncRule refuses to degrade this one under Lax: a >30 s skew
          // falsifies DATE-OBS, so promising it becomes an info note would be
          // a promise the executor breaks.
          'Clock drift over ${TimeSyncRule.errorThresholdSecs.toStringAsFixed(0)}s still blocks the run in every mode — it would falsify FITS timestamps.',
        ]);
        break;
      case PreflightStrictness.normal:
        lines.addAll([
          'Sequence start surfaces a warnings list for: $checks.',
          'You confirm the list to proceed.',
        ]);
        break;
      case PreflightStrictness.strict:
        lines.addAll([
          'Sequence start is blocked on: $checks.',
          'Every flagged issue must be resolved or explicitly acknowledged before the run begins.',
        ]);
        break;
    }
    if (polarAgeDays > 0) {
      lines.add(
        'Polar alignment will be flagged when the last successful run is older than $polarAgeDays day${polarAgeDays == 1 ? '' : 's'}.',
      );
    } else {
      lines.add(
        'Polar alignment age check is disabled (set max age above 0 to enable).',
      );
    }

    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      decoration: SkotiqDecorations.chip(colors, tone: colors.info),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 16, color: colors.info),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What this will do at sequence start',
                  style: SkotiqTypography.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $line',
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
