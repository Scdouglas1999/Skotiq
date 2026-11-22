import 'package:flutter/foundation.dart' show immutable;

import 'imaging_models.dart' show CapturedImageData;

/// A saved frame: its captured_images row and where the imaging host saved
/// its file.
@immutable
class SavedFrameRef {
  const SavedFrameRef({
    required this.imageId,
    required this.hostPath,
    required this.capturedAt,
  });

  /// The captured_images row id, which the host's download serves.
  final int imageId;

  /// The file's path on the imaging host.
  final String hostPath;

  final DateTime capturedAt;

  @override
  bool operator ==(Object other) =>
      other is SavedFrameRef &&
      other.imageId == imageId &&
      other.hostPath == hostPath &&
      other.capturedAt == capturedAt;

  @override
  int get hashCode => Object.hash(imageId, hostPath, capturedAt);
}

/// Where a full-resolution load stands.
@immutable
sealed class SavedFrameLoad {
  const SavedFrameLoad();
}

/// A linked client fetching the file from the host; [fraction] is 0 to 1,
/// null before the size is known.
final class SavedFrameDownloading extends SavedFrameLoad {
  const SavedFrameDownloading([this.fraction]);

  final double? fraction;

  @override
  bool operator ==(Object other) =>
      other is SavedFrameDownloading && other.fraction == fraction;

  @override
  int get hashCode => fraction.hashCode;
}

/// The file is being read and stretched.
final class SavedFrameDecoding extends SavedFrameLoad {
  const SavedFrameDecoding();

  @override
  bool operator ==(Object other) => other is SavedFrameDecoding;

  @override
  int get hashCode => 0;
}

/// The frame at full resolution. [localPath] is a readable copy of its file on
/// this machine (the file itself on the host), for star detection.
final class SavedFrameReady extends SavedFrameLoad {
  const SavedFrameReady({required this.image, required this.localPath});

  final CapturedImageData image;
  final String localPath;
}

/// The frame could not be loaded; [message] says why in plain words.
final class SavedFrameFailed extends SavedFrameLoad {
  const SavedFrameFailed(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is SavedFrameFailed && other.message == message;

  @override
  int get hashCode => message.hashCode;
}
