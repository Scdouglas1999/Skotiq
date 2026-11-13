import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/darkroom_state_store.dart';

final darkroomStateStoreProvider = Provider<DarkroomStateStore>(
  (ref) => DarkroomStateStore(ref.watch(databaseProvider)),
);
