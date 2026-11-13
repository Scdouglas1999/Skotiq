import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'database_provider.dart';
import '../services/live_stack_master_library.dart';
import 'live_stacking_service_provider.dart';

final liveStackMasterLibraryProvider = Provider<LiveStackMasterLibrary>((ref) {
  final stacking = ref.watch(liveStackingServiceProvider);
  return LiveStackMasterLibrary(
    currentResult: stacking.getCurrentResult,
    saveMaster: (path) => stacking.saveMaster(filePath: path),
    writePreview: (path, result) => bridge.apiSaveRgbaPngFile(
      filePath: path,
      width: result.width,
      height: result.height,
      rgba: stacking.autoStretchPreview(
        width: result.width,
        height: result.height,
        data: result.data,
        channels: result.channels,
      ),
    ),
    masters: ref.watch(integratedMastersDaoProvider),
  );
});
