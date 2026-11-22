import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'database_provider.dart';
import '../services/live_stack_darkroom_promotion.dart';
import '../services/live_stack_master_library.dart';
import 'live_stacking_service_provider.dart';

final liveStackMasterLibraryProvider = Provider<LiveStackMasterLibrary>((ref) {
  final stacking = ref.watch(liveStackingServiceProvider);
  return LiveStackMasterLibrary(
    currentResult: stacking.getCurrentResult,
    currentResultForFilter: stacking.getCurrentResultForFilter,
    saveMaster: (path) => stacking.saveMaster(filePath: path),
    saveMasterForFilter: (filterKey, path) =>
        stacking.saveMasterForFilter(filterKey: filterKey, filePath: path),
    writePreview: (path, result) async {
      final stretched = await stacking.autoStretchPreviewAsync(
        width: result.width,
        height: result.height,
        data: result.data,
        channels: result.channels,
        maxDimension: 0,
      );
      await bridge.apiSaveRgbaPngFile(
        filePath: path,
        width: stretched.width,
        height: stretched.height,
        rgba: stretched.rgba,
      );
    },
    masters: ref.watch(integratedMastersDaoProvider),
  );
});

final liveStackDarkroomPromoterProvider = Provider<LiveStackDarkroomPromoter>((
  ref,
) {
  final stacking = ref.watch(liveStackingServiceProvider);
  return LiveStackDarkroomPromoter(
    saveMaster: (path) => stacking.saveMaster(filePath: path),
    saveMasterForFilter: (filterKey, path) =>
        stacking.saveMasterForFilter(filterKey: filterKey, filePath: path),
    masters: ref.watch(integratedMastersDaoProvider),
    recipes: ref.watch(recipesDaoProvider),
  );
});
