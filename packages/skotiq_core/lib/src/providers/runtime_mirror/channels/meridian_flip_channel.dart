import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/meridian_flip_progress.dart';
import '../../meridian_flip_provider.dart';
import '../../meridian_flip_telemetry.dart';
import '../runtime_mirror_channel.dart';

final _meridianFlipProgressProvider = Provider<FlipMonitorProgress>((ref) {
  ref.watch(meridianFlipTelemetryProvider);
  return ref.watch(flipMonitorProgressProvider);
});

/// A meridian flip the host's flip monitor is performing outside a sequence.
///
/// The monitor runs only on the process that owns the mount, so a linked
/// client's mount card kept its controls enabled and showed no flip while the
/// mount was mid-flip.
class MeridianFlipChannel extends RuntimeMirrorChannel<FlipMonitorProgress> {
  const MeridianFlipChannel();

  @override
  String get key => 'meridianFlip';

  @override
  get source => _meridianFlipProgressProvider;

  @override
  Duration get minInterval => const Duration(milliseconds: 500);

  @override
  Map<String, dynamic>? encode(FlipMonitorProgress value) => value.toJson();

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || context.networkBackend == null) return;
    context
        .read(flipMonitorProgressProvider.notifier)
        .set(FlipMonitorProgress.fromJson(value));
  }
}
