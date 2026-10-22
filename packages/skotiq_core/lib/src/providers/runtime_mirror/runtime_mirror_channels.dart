import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'channels/autofocus_result_channel.dart';
import 'channels/autofocus_run_channel.dart';
import 'channels/centering_channels.dart';
import 'channels/cooler_reading_channel.dart';
import 'channels/current_frame_channel.dart';
import 'channels/environment_channel.dart';
import 'channels/frame_solve_channel.dart';
import 'channels/meridian_flip_channel.dart';
import 'channels/plate_solve_channel.dart';
import 'channels/sequence_run_channel.dart';
import 'runtime_mirror_channel.dart';

/// Every runtime channel the host shares with linked clients. Host and client
/// read the same list, so a channel key means the same provider on both sides.
final runtimeMirrorChannelsProvider =
    Provider<List<RuntimeMirrorChannel<Object?>>>(
      (ref) => const <RuntimeMirrorChannel<Object?>>[
        PlateSolveChannel(),
        CenteringStatusChannel(),
        CenteringResultChannel(),
        AutofocusResultChannel(),
        AutofocusRunChannel(),
        CurrentFrameChannel(),
        FrameSolveChannel(),
        EnvironmentChannel(),
        CoolerReadingChannel(),
        SequenceRunChannel(),
        MeridianFlipChannel(),
      ],
    );

RuntimeMirrorChannel<Object?>? runtimeChannelFor(
  List<RuntimeMirrorChannel<Object?>> channels,
  String key,
) {
  for (final channel in channels) {
    if (channel.key == key) return channel;
  }
  return null;
}
