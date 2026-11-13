import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/imaging/imaging_models.dart' show ExposureProgress;
import '../../../services/imaging_service.dart' show exposureProgressProvider;
import '../../equipment/camera_state_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// Whether the camera is exposing and the countdown of that exposure, as the
/// camera card and the countdown show them.
typedef ExposureShown = ({bool exposing, ExposureProgress countdown});

final exposureShownProvider = Provider<ExposureShown>(
  (ref) => (
    exposing: ref.watch(cameraStateProvider.select((c) => c.isExposing)),
    countdown: ref.watch(exposureProgressProvider),
  ),
);

/// The host camera's "Exposing" and its countdown.
///
/// The host follows every exposure of its camera (its own captures, its run's
/// frames, a capture a client or the API started), so a client shows the same
/// one from the moment it links, and it ends when the host's does.
class ExposureChannel extends RuntimeMirrorChannel<ExposureShown> {
  const ExposureChannel();

  static const channelKey = 'exposure';

  @override
  String get key => channelKey;

  @override
  get source => exposureShownProvider;

  /// The countdown changes many times a second on a host that runs the
  /// capture itself.
  @override
  Duration get minInterval => const Duration(milliseconds: 500);

  @override
  Map<String, dynamic>? encode(ExposureShown value) {
    if (!value.exposing) return null;
    final countdown = value.countdown;
    return {
      'elapsed': finiteOrNull(countdown.elapsed) ?? 0.0,
      'remaining': finiteOrNull(countdown.remaining) ?? 0.0,
      'percent': finiteOrNull(countdown.percent) ?? 0.0,
      'frame': countdown.frameNumber,
      'total': countdown.totalFrames,
      'downloading': countdown.isDownloading,
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final camera = context.read(cameraStateProvider.notifier);
    final countdown = context.read(exposureProgressProvider.notifier);
    if (value == null) {
      // A countdown left standing reads as an exposure still in flight.
      if (context.read(cameraStateProvider).isExposing) {
        camera.setExposing(false);
      }
      if (context.read(exposureProgressProvider) != ExposureProgress.idle()) {
        countdown.reset();
      }
      return;
    }
    final percent = jsonDouble(value['percent']) ?? 0.0;
    camera.setExposing(true, progress: percent / 100);
    countdown.show(
      ExposureProgress(
        elapsed: jsonDouble(value['elapsed']) ?? 0.0,
        remaining: jsonDouble(value['remaining']) ?? 0.0,
        percent: percent,
        frameNumber: jsonInt(value['frame']) ?? 1,
        totalFrames: jsonInt(value['total']),
        isDownloading: value['downloading'] == true,
      ),
    );
  }
}
