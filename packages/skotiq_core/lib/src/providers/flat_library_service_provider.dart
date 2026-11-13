import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/flat_library_service.dart';
import 'post_session_seam_provider.dart';

final flatLibraryServiceProvider = Provider<FlatLibraryService>((ref) {
  return FlatLibraryService(
    dao: ref.watch(flatLibraryDaoProvider),
    seam: ref.watch(postSessionSeamProvider),
  );
});
