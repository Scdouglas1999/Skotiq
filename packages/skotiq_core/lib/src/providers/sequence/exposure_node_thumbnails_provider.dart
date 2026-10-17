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

/// Fire-and-forget version of [exposureNodeThumbnailsProvider] that fetches
/// a one-shot snapshot. Used by the count badge ("3 more") and by tests
/// that don't want to assert on Stream behavior.
final exposureNodeThumbnailsSnapshotProvider = FutureProvider.autoDispose
    .family<List<ProducingNodeThumbnail>, String>((ref, nodeId) {
      if (nodeId.isEmpty) {
        return Future.value(const <ProducingNodeThumbnail>[]);
      }
      final records = ref.watch(imagingRecordsRepositoryProvider);
      return records.getImagesByProducingNode(producingNodeId: nodeId);
    });

/// Count of thumbnails attached to an ExposureNode. Cheap async lookup,
/// used to decide whether to render the strip at all (an empty strip is
/// collapsed silently per the spec).
final exposureNodeThumbnailCountProvider = FutureProvider.autoDispose
    .family<int, String>((ref, nodeId) {
      if (nodeId.isEmpty) return Future.value(0);
      final records = ref.watch(imagingRecordsRepositoryProvider);
      return records.countImagesByProducingNode(producingNodeId: nodeId);
    });
