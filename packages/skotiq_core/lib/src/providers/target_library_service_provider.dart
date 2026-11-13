import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/target_library_service.dart';

final targetLibraryServiceProvider = Provider<TargetLibraryService>((ref) {
  ref.watch(backendProvider);
  return TargetLibraryService(ref);
});
