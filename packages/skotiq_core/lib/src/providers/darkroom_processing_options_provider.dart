import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/darkroom_processing_options.dart';

final darkroomProcessingOptionsProvider =
    FutureProvider<DarkroomProcessingOptions>(
      (ref) => DarkroomProcessingOptions.load(ref.watch(settingsDaoProvider)),
    );
