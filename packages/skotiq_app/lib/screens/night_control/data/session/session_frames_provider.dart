// The frame strip of Tonight: the night's light frames as strip cells.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../../../services/night_session/night_session_frames.dart';
import '../../night_control_contracts.dart';

/// The frame strip: every light frame of the session, oldest first, the
/// newest flagged for the ring.
///
/// [StripFrameVm.frameNumber] is the frame's place in the session (the 43rd
/// light is "#43"). [StripFrameVm.thumbnailPath] stays null: the sidecar
/// path lives in a raw-DDL column the Drift row does not expose, and the
/// strip loads thumbnails through the existing thumbnail service by file.
final nightSessionFramesProvider = Provider<List<StripFrameVm>>((ref) {
  final rows = ref.watch(nightSessionLightRowsProvider);
  final paths = ref.watch(hostPathsProvider);
  return <StripFrameVm>[
    for (var i = 0; i < rows.length; i++)
      StripFrameVm(
        id: rows[i].id,
        frameNumber: i + 1,
        capturedAt: rows[i].capturedAt,
        filter: rows[i].filter,
        exposureSecs: rows[i].exposureDuration,
        hfr: rows[i].hfr,
        starCount: rows[i].starCount,
        accepted: nightFrameVerdict(rows[i]),
        exclusion: frameExclusionKindOf(rows[i].rejectionReason),
        filePath:
            rows[i].filePath.isEmpty ? null : paths.local(rows[i].filePath),
        hostPath: rows[i].filePath.isEmpty ? null : rows[i].filePath,
        isNewest: i == rows.length - 1,
      ),
  ];
});
