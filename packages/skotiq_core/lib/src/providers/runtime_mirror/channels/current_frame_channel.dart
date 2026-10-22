import '../../../models/imaging/imaging_models.dart'
    show CapturedImageData, ExposureSettings, FrameType;
import '../../../services/imaging_service.dart' show currentImageProvider;
import '../../remote_sync_handler.dart'
    show HostFrameHint, requestHostCurrentFrame;
import '../runtime_mirror_channel.dart';

/// The frame on the host's screen, as metadata only.
///
/// Snapshots, loop frames and solve frames the host GUI takes, and the frames
/// of a run, all land in the host's current image. A client that learns of a
/// new one fetches it through the existing last-frame endpoint, so pixels never
/// ride on the event stream. Frames a client captured itself reach the host
/// through the host's save endpoint, not through this channel.
class CurrentFrameChannel extends RuntimeMirrorChannel<CapturedImageData?> {
  const CurrentFrameChannel();

  @override
  String get key => 'currentFrame';

  @override
  get source => currentImageProvider;

  @override
  Map<String, dynamic>? encode(CapturedImageData? value) {
    if (value == null) return null;
    final settings = value.settings;
    return {
      'capturedAt': value.capturedAt.toUtc().millisecondsSinceEpoch,
      'width': value.width,
      'height': value.height,
      if (value.filePath != null) 'filePath': value.filePath,
      if (value.targetName != null) 'targetName': value.targetName,
      'exposure': finiteOrNull(settings.exposureTime),
      'gain': settings.gain,
      'offset': settings.offset,
      'binX': settings.binningX,
      'binY': settings.binningY,
      if (settings.filter != null) 'filter': settings.filter,
      'frameType': settings.frameType.name,
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final backend = context.networkBackend;
    if (backend == null || value == null) return;
    final shown = context.read(currentImageProvider);
    if (shown != null) {
      final path = jsonString(value['filePath']);
      final at = jsonInstant(value['capturedAt']);
      final samePath =
          path != null && path.isNotEmpty && shown.filePath == path;
      if (samePath) return;
      final sameInstant =
          at != null &&
          shown.capturedAt.toUtc().millisecondsSinceEpoch ==
              at.millisecondsSinceEpoch;
      if (sameInstant) {
        // The frame already shown was saved on the host after it was
        // announced: record where, without fetching its pixels again.
        if (path != null && path.isNotEmpty) {
          context.read(currentImageProvider.notifier).state = shown.copyWith(
            filePath: path,
          );
        }
        return;
      }
    }
    final width = jsonInt(value['width']);
    final height = jsonInt(value['height']);
    final exposure = jsonDouble(value['exposure']);
    final gain = jsonInt(value['gain']);
    final offset = jsonInt(value['offset']);
    requestHostCurrentFrame(
      context.reader,
      backend,
      hint: width == null || height == null
          ? null
          : HostFrameHint(
              width: width,
              height: height,
              filePath: jsonString(value['filePath']),
              targetName: jsonString(value['targetName']),
              settings: exposure == null || gain == null || offset == null
                  ? null
                  : ExposureSettings(
                      exposureTime: exposure,
                      gain: gain,
                      offset: offset,
                      binningX: jsonInt(value['binX']) ?? 1,
                      binningY: jsonInt(value['binY']) ?? 1,
                      filter: jsonString(value['filter']),
                      frameType: FrameType.values.firstWhere(
                        (t) => t.name == value['frameType'],
                        orElse: () => FrameType.light,
                      ),
                    ),
            ),
    );
  }
}
