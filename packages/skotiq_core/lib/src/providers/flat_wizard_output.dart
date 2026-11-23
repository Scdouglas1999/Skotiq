import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/flat_wizard/flat_run_snapshot.dart';

final flatRunOutputProvider = StateProvider<FlatRunOutput>(
  (ref) => const FlatRunOutput(),
);
