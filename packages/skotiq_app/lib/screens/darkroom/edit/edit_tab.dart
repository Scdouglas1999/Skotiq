import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';

final _editMastersProvider = FutureProvider.autoDispose<List<IntegratedMaster>>(
  (ref) => ref.watch(integratedMastersDaoProvider).getAll(),
);

/// The Darkroom's recipe editor, opened on any registered image.
class DarkroomEditTab extends ConsumerWidget {
  const DarkroomEditTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final masters = ref.watch(_editMastersProvider);
    return masters.when(
      loading: () => const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      ),
      error: (error, _) => Center(
        child: EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'The masters could not be read',
          body: '$error',
        ),
      ),
      data: (list) => list.isEmpty
          ? const Center(
              child: EmptyState(
                icon: SkotiqIcons.layers,
                title: 'No registered images yet',
                body: 'Build masters for a target, then open them here.',
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(SkotiqTokens.space2xl),
              children: [
                for (final master in list)
                  ListTile(
                    title: Text(master.name),
                    trailing: SkotiqButton(
                      label: 'Open',
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: () =>
                          context.go(darkroomEditLocation(masterId: master.id)),
                    ),
                  ),
              ],
            ),
    );
  }
}
