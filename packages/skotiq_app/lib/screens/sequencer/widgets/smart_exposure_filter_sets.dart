import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/filter_set_picker.dart';

/// The Filters picker of a Smart Exposure step under a target: picking a
/// combination fills the step's rows at once
/// ([SmartNightService.smartExposureRows]): each filter's sub length from
/// the exposure calculator, the step's planned time split into frame counts,
/// the camera's gain and offset for each filter. The step's dither cadence
/// and binning stay as they were, and the rows can still be edited after.
/// The set is remembered for the target, as every other Filters picker does.
class SmartExposureFilterSets extends ConsumerWidget {
  const SmartExposureFilterSets({
    super.key,
    required this.colors,
    required this.node,
    required this.target,
  });

  final SkotiqColors colors;
  final SmartExposureNode node;

  /// The target step this one sits under.
  final TargetHeaderNode target;

  /// The planned time the rows are filled to, when the step has neither a
  /// budget nor rows.
  static const double _defaultPlannedSecs = 4 * 3600;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestion = ref
        .watch(
          sequenceTargetSuggestionProvider((
            name: target.targetName,
            raHours: target.raHours,
            decDegrees: target.decDegrees,
            libraryId: target.catalogTargetId,
          )),
        )
        .valueOrNull;
    if (suggestion == null) return const SizedBox.shrink();
    final choice =
        ref.watch(targetFilterChoiceProvider(suggestion)).valueOrNull;
    if (choice == null) return const SizedBox.shrink();
    final saved =
        ref.watch(filterSetPreferencesProvider).valueOrNull?.custom ?? const [];
    final rows = [for (final plan in node.plans) plan.filterName];
    final current = choice
        .sets(saved: saved)
        .where((set) => _sameFilters(set.filters, rows))
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: FormRow.rowGap),
      child: FilterSetPicker(
        key: ValueKey('smart-exposure-filters-${node.id}'),
        label: 'Filters',
        choice: choice,
        value: current,
        dense: true,
        onChanged: (set) => _fill(context, ref, suggestion, choice, set),
      ),
    );
  }

  Future<void> _fill(
    BuildContext context,
    WidgetRef ref,
    TargetSuggestion suggestion,
    SmartNightFilterChoice choice,
    FilterSet set,
  ) async {
    final profile = ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      context.showWarningSnackBar('Select an equipment profile first.');
      return;
    }
    final kept = node.plans.firstOrNull;
    final plannedSecs = node.integrationBudgetSecs > 0
        ? node.integrationBudgetSecs
        : node.totalIntegrationSecs > 0
            ? node.totalIntegrationSecs
            : _defaultPlannedSecs;
    final rotate = smartNightRotatesFilters(profile);
    try {
      final exposureContext = await ref.read(
        smartNightExposureContextProvider.future,
      );
      final filled = ref.read(smartNightServiceProvider).smartExposureRows(
            profile: profile,
            filterSet: set,
            plannedSecs: plannedSecs,
            exposureContext: exposureContext,
          );
      ref.read(currentSequenceProvider.notifier).updateNode(
            node.copyWith(
              name: _autoNamed(node)
                  ? 'Smart Exposure: ${filled.map((p) => p.filterName).join('+')}'
                  : node.name,
              plans: [
                for (final row in filled)
                  row.copyWith(
                    ditherEvery: kept?.ditherEvery,
                    binning: kept?.binning ?? row.binning,
                  ),
              ],
              rotateFilters: rotate,
              loopUntilStopped: rotate && node.loopUntilStopped,
            ),
          );
      await ref
          .read(filterSetPreferencesProvider.notifier)
          .choose(suggestion, set, recommended: choice.recommended);
    } on SmartNightBuildException catch (e) {
      if (context.mounted) context.showWarningSnackBar(e.message);
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar(
          'Could not fill the filters: ${userFacingError(e)}',
        );
      }
    }
  }

  /// Whether [node] still has the name a builder gives it ("Smart
  /// Exposure: Ha+OIII+SII"), so its new filters rename it; a name the user
  /// typed stays.
  static bool _autoNamed(SmartExposureNode node) =>
      node.name == 'Smart Exposure' ||
      node.name ==
          'Smart Exposure: ${node.plans.map((p) => p.filterName).join('+')}';

  static bool _sameFilters(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
