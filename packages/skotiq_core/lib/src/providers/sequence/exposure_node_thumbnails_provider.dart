import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/images_dao.dart';
import '../../services/imaging_records_repository.dart';

/// Thumbnail — inline frame thumbnails in the sequence tree.
///
/// Streams the captured-image rows produced by a given `ExposureNode` so the
/// sequence-tree thumbnail strip can render them inline beneath the node row,
/// color-coded by runtime grade, via [ImagesDao.watchImagesByProducingNode].
///
/// Family key: the producing node's stable string id (the same value the
/// sequencer uses for `currentNodeId` and that ships in
/// `SequencerEvent::FrameAccepted.nodeId`). A single string, not a record, so
/// URL-style "?" arg parsing stays simple and record-comparison semantics
/// cannot silently break provider identity.
final exposureNodeThumbnailsProvider = StreamProvider.autoDispose
    .family<List<ProducingNodeThumbnail>, String>((ref, nodeId) {
      if (nodeId.isEmpty) {
        // Defensive: an empty node id should not blow up SQL — return an
        // empty stream so the tree just hides the strip.
        return const Stream<List<ProducingNodeThumbnail>>.empty();
      }
      final records = ref.watch(imagingRecordsRepositoryProvider);
      return records.watchImagesByProducingNode(producingNodeId: nodeId);
    });
