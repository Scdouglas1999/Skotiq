import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/science_backend.dart';
import '../../services/science/default_science_backend.dart';

final scienceBackendProvider = Provider<ScienceBackend>((ref) {
  return DefaultScienceBackend(ref);
});
