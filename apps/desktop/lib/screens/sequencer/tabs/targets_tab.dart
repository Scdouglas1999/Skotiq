import 'package:drift/drift.dart' hide Column; // For Value
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

part 'targets_tab/targets_header.dart';
part 'targets_tab/action_button.dart';
part 'targets_tab/target_card.dart';
part 'targets_tab/target_card_controls.dart';
part 'targets_tab/add_target_dialog.dart';
part 'targets_tab/edit_target_dialog.dart';

/// Provider for target search query
final sequenceTargetSearchProvider = StateProvider<String>((ref) => '');

/// Provider for target type filter
final targetTypeFilterProvider = StateProvider<String?>((ref) => null);

/// Provider to watch all targets from database (using the database-generated Target type)
final targetsProvider = StreamProvider((ref) {
  return ref.watch(targetsDaoProvider).watchAllTargets();
});

class TargetsTab extends ConsumerWidget {
  const TargetsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final targetsAsync = ref.watch(targetsProvider);
    final searchQuery = ref.watch(sequenceTargetSearchProvider);
    final typeFilter = ref.watch(targetTypeFilterProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Header with search and actions
          _TargetsHeader(colors: colors),

          const SizedBox(height: 20),

          // Target list
          Expanded(
            child: targetsAsync.when(
              data: (targets) {
                // Filter targets
                var filtered = targets;
                if (searchQuery.isNotEmpty) {
                  filtered = filtered.where((t) {
                    final nameMatch = t.name.toLowerCase().contains(
                      searchQuery.toLowerCase(),
                    );
                    final catalogMatch =
                        t.catalogId?.toLowerCase().contains(
                          searchQuery.toLowerCase(),
                        ) ??
                        false;
                    final constMatch =
                        t.constellation?.toLowerCase().contains(
                          searchQuery.toLowerCase(),
                        ) ??
                        false;
                    return nameMatch || catalogMatch || constMatch;
                  }).toList();
                }
                if (typeFilter != null && typeFilter != 'All') {
                  filtered = filtered
                      .where((t) => t.objectType == typeFilter)
                      .toList();
                }

                if (filtered.isEmpty) {
                  return const EmptyState(
                    icon: LucideIcons.target,
                    title: 'No targets found',
                    body: 'Add your first target or import from a catalog',
                  );
                }

                return ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    return _TargetCard(colors: colors, target: filtered[index]);
                  },
                );
              },
              loading: () => Center(
                child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
              ),
              error: (error, stack) => Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.alertTriangle,
                        size: 48,
                        color: colors.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Failed to load targets',
                        style: TextStyle(color: colors.textPrimary),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        error.toString(),
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
