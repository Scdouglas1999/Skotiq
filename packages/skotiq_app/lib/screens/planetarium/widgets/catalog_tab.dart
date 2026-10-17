import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../planetarium_screen.dart';
import 'sidebar_shared_widgets.dart';

class CatalogTab extends ConsumerWidget {
  final SkotiqColors colors;

  const CatalogTab({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dsos = ref.watch(loadedDsosProvider);

    return dsos.when(
      data: (objects) => ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: objects.length,
        itemBuilder: (context, index) {
          final dso = objects[index];
          final (displayName, catalogTag) = getDsoDisplayInfo(dso);
          return TargetCard(
            name: displayName,
            catalog: catalogTag,
            type: dsoTypeName(dso.type),
            magnitude: dso.magnitude?.toStringAsFixed(1) ?? '-',
            caption: 'mag',
            colors: colors,
            onTap: () {
              ref.read(selectedObjectProvider.notifier).selectObject(dso);
              ref.read(skyViewStateProvider.notifier).lookAt(dso.coordinates);
            },
          );
        },
      ),
      // Skeleton rows match TargetCard height so the catalog doesn't
      // collapse to a centred spinner while the DSO list streams in.
      loading: () => ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 8,
        itemBuilder: (context, _) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ShimmerLoading(
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
            ),
          ),
        ),
      ),
      error: (e, _) => Center(
        child: Text('Error: $e', style: TextStyle(color: colors.error)),
      ),
    );
  }
}
