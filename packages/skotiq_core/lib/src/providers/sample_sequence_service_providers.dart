import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/sample_sequence_service.dart';

/// Provider for the [SampleSequenceService] singleton.
final sampleSequenceServiceProvider = Provider<SampleSequenceService>((ref) {
  return SampleSequenceService();
});

/// Provider that loads the bundled sample sequences exactly once.
final sampleSequencesProvider = FutureProvider<List<SampleSequence>>((ref) {
  final service = ref.watch(sampleSequenceServiceProvider);
  return service.load();
});
