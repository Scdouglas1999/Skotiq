import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/meridian_flip_event.dart' show FlipStep;
import '../../meridian_flip_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

typedef MeridianFlipRunState = ({
  FlipExecutionState state,
  int attempt,
  FlipStep? step,
  int progress,
  String? error,
});

final _meridianFlipProgressProvider = Provider<MeridianFlipRunState>(
  (ref) => (
    state: ref.watch(flipExecutionStateProvider),
    attempt: ref.watch(flipCurrentAttemptProvider),
    step: ref.watch(flipCurrentStepProvider),
    progress: ref.watch(flipProgressProvider),
    error: ref.watch(flipLastErrorProvider),
  ),
);

/// A meridian flip the host's flip monitor is performing outside a sequence.
///
/// The monitor runs only on the process that owns the mount, so a linked
/// client's mount card kept its controls enabled and showed no flip while the
/// mount was mid-flip.
class MeridianFlipChannel extends RuntimeMirrorChannel<MeridianFlipRunState> {
  const MeridianFlipChannel();

  @override
  String get key => 'meridianFlip';

  @override
  get source => _meridianFlipProgressProvider;

  @override
  Duration get minInterval => const Duration(milliseconds: 500);

  @override
  Map<String, dynamic>? encode(MeridianFlipRunState value) => {
    'state': value.state.name,
    'attempt': value.attempt,
    'step': value.step?.name,
    'progress': value.progress,
    'error': value.error,
  };

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || context.networkBackend == null) return;
    context.read(flipExecutionStateProvider.notifier).state = FlipExecutionState
        .values
        .firstWhere(
          (s) => s.name == value['state'],
          orElse: () => FlipExecutionState.idle,
        );
    context.read(flipCurrentAttemptProvider.notifier).state = requireInt(
      value,
      'attempt',
    );
    context.read(flipCurrentStepProvider.notifier).state = FlipStep.values
        .where((s) => s.name == value['step'])
        .firstOrNull;
    context.read(flipProgressProvider.notifier).state = requireInt(
      value,
      'progress',
    );
    context.read(flipLastErrorProvider.notifier).state = jsonString(
      value['error'],
    );
  }
}
