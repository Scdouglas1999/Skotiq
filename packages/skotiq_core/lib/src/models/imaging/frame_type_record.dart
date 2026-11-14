import 'package:drift/drift.dart';

import '../../database/database.dart' show $CapturedImagesTable, DbCapturedImage;
import 'imaging_models.dart' show FrameType;

/// A recorded frame's type ([FrameType.record]).
extension RecordedFrameType on DbCapturedImage {
  /// Null when the row names no frame type Skotiq knows.
  FrameType? get recordedFrameType => FrameType.fromRecord(frameType);

  /// Whether this is a light frame: the frames that are stacked, graded,
  /// solved and counted as integration.
  bool get isLight => recordedFrameType == FrameType.light;
}

/// The same test of `captured_images.frame_type` in a query.
extension FrameTypeColumn on $CapturedImagesTable {
  Expression<bool> frameTypeIs(FrameType type) => frameType.equals(type.record);
}

/// The light-frame test for a query written as SQL over `captured_images`.
const lightFrameSql = "frame_type = 'light'";
