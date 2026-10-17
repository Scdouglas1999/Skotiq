part of '../polar_alignment_provider.dart';

/// Controller provider for polar alignment actions
final polarAlignmentControllerProvider = Provider<PolarAlignmentController>((
  ref,
) {
  return PolarAlignmentController(ref);
});

/// Controller for polar alignment actions
class PolarAlignmentController {
  final Ref ref;

  PolarAlignmentController(this.ref);

  /// Start polar alignment with current configuration
  Future<void> start() async {
    final config = ref.read(polarAlignmentConfigProvider);
    await ref.read(polarAlignmentStateProvider.notifier).startAlignment(config);
  }

  /// Stop polar alignment
  Future<void> stop() async {
    await ref.read(polarAlignmentStateProvider.notifier).stopAlignment();
  }

  /// Complete polar alignment (manual completion)
  Future<void> complete() async {
    await ref
        .read(polarAlignmentStateProvider.notifier)
        .completeAlignment(autoCompleted: false);
  }

  /// Reset state
  void reset() {
    ref.read(polarAlignmentStateProvider.notifier).reset();
  }
}
