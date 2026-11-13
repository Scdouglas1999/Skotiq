import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/imaging/imaging_models.dart';
import '../../imaging_provider.dart';
import '../runtime_mirror_channel.dart';
import '../../captured_image_rows.dart';

/// The frames in the imaging host's session list (its Imaging screen's
/// Session block and Session frames tab), as `captured_images` ids, oldest
/// first; null on the host and before the host has reported them.
final hostSessionFrameIdsProvider = StateProvider<List<int>?>((ref) => null);

/// The host's session frame list: every frame the host captured since it
/// started or since its operator cleared the list, sequencer and quick
/// captures alike.
///
/// That list lives in the host's memory only, so a client counted just the
/// frames of a session it could find on the host and read "0 captured, 0s"
/// beside the host's "10 captured, 10m 0s". The ids travel; the client reads
/// the rows themselves from the host's images, as it already does.
class SessionFramesChannel extends RuntimeMirrorChannel<List<CapturedImage>> {
  const SessionFramesChannel();

  @override
  String get key => 'sessionFrames';

  @override
  get source => sessionImagesProvider;

  @override
  Duration get minInterval => const Duration(seconds: 1);

  @override
  Map<String, dynamic>? encode(List<CapturedImage> value) => {
    // A frame with no database row has a clock-time id; no client can read
    // it, so it is left out.
    'ids': [
      for (final image in value)
        if (int.tryParse(image.id) case final int id) id,
    ],
  };

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || context.networkBackend == null) return;
    final raw = value['ids'];
    if (raw is! List) {
      throw const FormatException('Session frames carry no id list');
    }
    final ids = [
      for (final id in raw)
        if (id is num) id.toInt(),
    ];
    context.read(hostSessionFrameIdsProvider.notifier).state = ids;
    // The rows behind new ids are fetched now rather than at the next poll of
    // the host's whole image table, up to 30 s away.
    unawaited(context.read(capturedImageRowsProvider).addRows(ids));
  }
}
