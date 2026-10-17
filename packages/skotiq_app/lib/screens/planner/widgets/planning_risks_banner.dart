import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/camera_sensor_specs_dialog.dart';

/// The planner's risk caveats, as ONE statement of ONE problem.
///
/// The scorer emits a caveat per sensor value it could not resolve, and the
/// banner printed them verbatim, one after another:
///
///   "Camera read noise is not configured; using a conservative 3.5e- planning
///    estimate. Camera full well is not configured; using an 18,000e- planning
///    estimate. Camera QE is not configured; using a 65% planning estimate."
///
/// Three sentences, one problem, and — worse — that problem was usually not
/// real: the values were sitting in the app's own sensor-spec chain, which the
/// planner did not consult. Now they are resolved before the scorer runs, so a
/// sensor caveat only appears for a figure that genuinely misses at every
/// tier. When one does, 02 rule 4 (one banner per problem) and rule 5 (say it
/// once) still apply: the caveats collapse into a single sentence that NAMES
/// the camera, lists the fields, and offers the one action that fixes it.
/// Anything the scorer raises that is not about sensor specs is still said.
class PlanningRisksBanner extends ConsumerWidget {
  const PlanningRisksBanner({super.key, required this.riskFactors});

  final List<String> riskFactors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (riskFactors.isEmpty) return const SizedBox.shrink();
    final others =
        riskFactors.where((caveat) => !isSensorSpecCaveat(caveat)).toList();

    if (others.length == riskFactors.length) {
      // No sensor caveat to collapse: say what the scorer said.
      return SkotiqBanner(
        title: others.first,
        message: others.length > 1 ? others.skip(1).join(' · ') : null,
        tone: BannerTone.warning,
      );
    }

    final specs = ref.watch(activeCameraSensorSpecsProvider).valueOrNull;
    if (specs == null) {
      // The chain is still resolving. Say the scorer's own words rather than
      // an empty field list; one more frame and this is replaced.
      return SkotiqBanner(
        title: riskFactors.first,
        message:
            riskFactors.length > 1 ? riskFactors.skip(1).join(' · ') : null,
        tone: BannerTone.warning,
      );
    }

    final missing = specs.unresolvedFields;
    final camera = specs.databaseEntry?.model ?? specs.reportedModel;

    final String title;
    if (camera == null) {
      title = 'This profile has no camera, so exposures are estimated';
    } else if (missing.length == SensorSpecField.values.length) {
      title = 'No published sensor specs for $camera';
    } else {
      title = '${_capitalize(_fieldList(missing))} '
          '${missing.length == 1 ? 'is' : 'are'} not published for $camera';
    }

    final message = [
      'Scores use conservative estimates for '
          '${missing.isEmpty ? 'them' : _fieldList(missing)}.',
      ...others,
    ].join(' · ');

    return SkotiqBanner(
      key: const ValueKey('planner_sensor_specs_banner'),
      tone: BannerTone.warning,
      title: title,
      message: message,
      action: CameraSensorSpecsAction(
        specs: specs,
        label: camera == null ? 'Open equipment' : 'Enter camera specs',
      ),
    );
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  /// "read noise, full well and QE" — an Oxford-comma-free list, because the
  /// banner is one line and the fields are a set, not a sentence.
  static String _fieldList(List<SensorSpecField> fields) {
    final labels = fields.map((field) => field.label).toList();
    if (labels.isEmpty) return '';
    if (labels.length == 1) return labels.first;
    final last = labels.removeLast();
    return '${labels.join(', ')} and $last';
  }
}

/// The one line on the Plan screen that says what sensor the exposure numbers
/// above it were computed from, and where each figure came from.
///
/// The owner's report was that Plan called his camera's specs unknown while
/// the app already had them. The fix is not only to resolve them — it is to
/// say so on the screen that uses them, with the tier named: "3.8 µm" read off
/// the camera and "3.8 µm" out of ZWO's manual are different claims, and only
/// one of them describes the crop the driver is actually delivering. Tapping
/// the row opens the correction dialog.
class CameraSensorSpecsRow extends ConsumerWidget {
  const CameraSensorSpecsRow({super.key});

  /// Room for the five figures to wrap inside the 380px detail column. A
  /// single-line row truncated the read noise to "1.2 e- r…", which states a
  /// number and then hides which number it is.
  static const int _maxSummaryLines = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final specs = ref.watch(activeCameraSensorSpecsProvider).valueOrNull;
    if (specs == null || specs.isEmpty) return const SizedBox.shrink();
    final colors = context.skotiqColors;
    final origin = specs.originLabel;
    final camera = specs.databaseEntry?.model ?? specs.reportedModel;

    return SkotiqTooltip(
      message: specs.provenanceSentence,
      child: Semantics(
        button: true,
        label: 'Camera sensor specs for ${camera ?? 'this camera'}: '
            '${specs.valueSummary}. ${specs.provenanceSentence} '
            'Activate to correct them.',
        excludeSemantics: true,
        child: InkWell(
          onTap: () => CameraSensorSpecsDialog.show(context, specs),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: SkotiqTokens.spaceSm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.camera,
                  size: SkotiqTokens.iconSm,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Camera sensor',
                              style: SkotiqTypography.eyebrow.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ),
                          if (origin != null)
                            Text(
                              origin,
                              style: SkotiqTypography.caption.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      Text(
                        specs.valueSummary,
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textSecondary,
                        ),
                        maxLines: _maxSummaryLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
