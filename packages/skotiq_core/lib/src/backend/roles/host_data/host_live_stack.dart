import 'package:skotiq_core/skotiq_core.dart';

/// The live stack a linked imaging host builds from the frames it captures.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostLiveStack {
  Future<LiveStackingResult> stackingAddFrame(String imagePath);

  Future<LiveStackingResult> stackingGetResult();

  Future<LiveStackingStats> stackingGetStats();

  Future<void> stackingReset();

  Future<LiveStackingStats> stackingStart({
    String? referencePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  });

  Future<void> stackingStop();
}
