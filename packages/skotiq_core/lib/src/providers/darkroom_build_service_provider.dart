import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'database_provider.dart';
import 'dark_library_provider.dart';
import '../services/darkroom_build_service.dart';
import 'calibration_library_service_providers.dart';
import 'calibration_master_builder_provider.dart';

final darkroomBuildServiceProvider = Provider(
  (ref) => DarkroomBuildService(
    operation: (request) async => Map<String, dynamic>.from(
      jsonDecode(
            await bridge.apiMasterAccumulate(argsJson: jsonEncode(request)),
          )
          as Map,
    ),
    processingSettings: () =>
        DarkroomProcessingOptions.load(ref.read(settingsDaoProvider)),
    library: ref.watch(calibrationLibraryProvider),
    masters: ref.watch(integratedMastersDaoProvider),
    buildMaster: ref.watch(calibrationMasterBuildProvider),
    darkLibrary: ref.watch(darkLibraryServiceProvider),
    flatLibrary: ref.watch(flatLibraryDaoProvider),
  ),
);
