import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sequence/sequence_models.dart';
import '../services/built_in_template_service.dart';
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

/// The templates Skotiq ships, dated when they are read.
final builtInTemplatesProvider = FutureProvider.autoDispose<List<Sequence>>(
  (ref) => const BuiltInTemplateService().load(),
);
