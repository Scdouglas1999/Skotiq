part of '../polar_alignment_provider.dart';

final polarAlignmentControllerProvider = Provider<PolarAlignmentController>((
  ref,
) {
  return PolarAlignmentController(ref);
});

class PolarAlignmentController {
  final Ref ref;

  PolarAlignmentController(this.ref);

  /// Start polar alignment with current configuration
  Future<void> start() async {
    final config = ref.read(polarAlignmentConfigProvider);
    await ref.read(polarAlignmentStateProvider.notifier).startAlignment(config);
  }

  Future<void> stop() async {
    await ref.read(polarAlignmentStateProvider.notifier).stopAlignment();
  }

  /// Complete polar alignment (manual completion)
  Future<void> complete() async {
    await ref
        .read(polarAlignmentStateProvider.notifier)
        .completeAlignment(autoCompleted: false);
  }

  void reset() {
    ref.read(polarAlignmentStateProvider.notifier).reset();
  }
}
