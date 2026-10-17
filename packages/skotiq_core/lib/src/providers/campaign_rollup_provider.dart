import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/campaign_rollup.dart';
import '../services/campaign_rollup_service.dart';
import '../services/imaging_records_repository.dart';
import '../services/scheduler/integration_goal_service.dart';
import 'database_provider.dart';
import 'settings_provider.dart';

/// Service provider for [CampaignRollupService].
final campaignRollupServiceProvider = Provider<CampaignRollupService>((ref) {
  return CampaignRollupService(
    records: ref.watch(imagingRecordsRepositoryProvider),
    targetsDao: ref.watch(targetsDaoProvider),
    goalService: ref.watch(integrationGoalServiceProvider),
  );
});

/// Multi-night campaign rollup for one target.
///
/// Family-keyed by `targetId`. Auto-invalidates when the underlying database
/// providers change.
final campaignRollupProvider = FutureProvider.autoDispose
    .family<CampaignRollup, int>((ref, targetId) async {
      final targets = await ref.watch(allDbTargetsProvider.future);
      return ref
          .watch(campaignRollupServiceProvider)
          .buildForTarget(targetId, targetCatalog: targets);
    });

/// Bulk campaign rollups for the entire target catalog.
///
/// Returns rollups keyed by target id. Targets with no captures still
/// appear in the map (with empty filter / session lists) so the UI
/// can render "no captures yet" tiles.
final campaignRollupAllTargetsProvider =
    FutureProvider.autoDispose<Map<int, CampaignRollup>>((ref) async {
      final targets = await ref.watch(allDbTargetsProvider.future);
      return ref
          .watch(campaignRollupServiceProvider)
          .buildForAllTargets(targetCatalog: targets);
    });

/// Resolve a campaign rollup by **target name** (case-insensitive).
///
/// The History tab keys its rows by sequence-run, not by Drift target id —
/// the per-run stats blob stores the target name as a free-string. We
/// look up the corresponding [CampaignRollup] via this provider so the
/// campaign badge can join across the two surfaces without re-querying
/// the database for every row.
///
/// Honors the [AppSettingsState.campaignRollupGroupingMode] setting.
/// `by_user_tag` resolves the same as `by_target_name`: the targets table
/// carries no tags column, so there is nothing further to match on.
final campaignRollupByNameProvider = FutureProvider.autoDispose
    .family<CampaignRollup?, String>((ref, targetName) async {
      final lookup = targetName.trim().toLowerCase();
      if (lookup.isEmpty) return null;
      final mode =
          ref
              .watch(appSettingsProvider)
              .valueOrNull
              ?.campaignRollupGroupingMode ??
          'by_target_name';
      final all = await ref.watch(campaignRollupAllTargetsProvider.future);
      for (final rollup in all.values) {
        switch (mode) {
          case 'by_target_id':
            if (rollup.targetId.toString() == lookup) return rollup;
            break;
          case 'by_user_tag':
          case 'by_target_name':
          default:
            if (rollup.targetName.toLowerCase() == lookup) return rollup;
        }
      }
      return null;
    });
