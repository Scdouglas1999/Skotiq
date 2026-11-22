import '../../../models/imaging/live_stacking_state.dart';
import '../../live_stacking_provider.dart';
import '../runtime_mirror_channel.dart';

/// The host's live stack: whether it is armed or running and what each
/// filter slot holds, whoever armed it (the host's screen, a run's Live
/// stacking node, or a linked client).
///
/// Metadata only. A client fetches a slot's pixels over the stacking routes
/// when the slot's revision changes. Host to client: a client arms, resets
/// and stops the host's stack over those routes.
class LiveStackChannel extends RuntimeMirrorChannel<LiveStackingState> {
  const LiveStackChannel();

  @override
  String get key => 'liveStack';

  @override
  get source => liveStackingProvider;

  /// A stack changes with every frame; the preview follows within a second.
  @override
  Duration get minInterval => const Duration(seconds: 1);

  @override
  Map<String, dynamic>? encode(LiveStackingState value) =>
      LiveStackSummary.of(value)?.toJson();

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final backend = context.networkBackend;
    if (backend == null) return;
    context
        .read(liveStackingProvider.notifier)
        .applyHostStack(
          value == null ? null : LiveStackSummary.fromJson(value),
          backend,
        );
  }
}
