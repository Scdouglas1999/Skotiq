import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'channels/autofocus_result_channel.dart';
import 'channels/auxiliary_device_channels.dart';
import 'channels/autofocus_run_channel.dart';
import 'channels/centering_channels.dart';
import 'channels/cooler_reading_channel.dart';
import 'channels/end_of_night_channel.dart';
import 'channels/current_frame_channel.dart';
import 'channels/environment_channel.dart';
import 'channels/frame_solve_channel.dart';
import 'channels/live_broadcast_channel.dart';
import 'channels/framing_geometry_channel.dart';
import 'channels/framing_target_channel.dart';
import 'channels/manual_action_channel.dart';
import 'channels/manual_loop_channel.dart';
import 'channels/meridian_flip_channel.dart';
import 'channels/notice_acks_channel.dart';
import 'channels/pending_start_channel.dart';
import 'channels/plate_solve_channel.dart';
import 'channels/run_record_channel.dart';
import 'channels/scheduled_start_channel.dart';
import 'channels/sequence_run_channel.dart';
import 'channels/session_frames_channel.dart';
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
        RunRecordChannel(),
        SessionFramesChannel(),
        MeridianFlipChannel(),
        ManualActionChannel(),
        ManualLoopChannel(),
        FramingGeometryChannel(),
        FramingTargetChannel(),
        PendingStartChannel(),
        CoverCalibratorChannel(),
        SwitchChannelsChannel(),
        NoticeAcknowledgmentsChannel(),
        LiveBroadcastChannel(),
        ScheduledStartChannel(),
        EndOfNightChannel(),
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
