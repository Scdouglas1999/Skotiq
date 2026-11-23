import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import 'sequence_editor.dart';
import 'sequence_selection.dart';
import 'sequencer_defaults.dart';

/// How an editor commits an operator's edit of an exposure step.
extension ExposureEdit on WidgetRef {
  /// Write [node] into the open sequence. Each value given here also becomes
  /// the default the next new exposure step starts with, so a dropped step
  /// inherits the operator's latest choice; a field left null is not written.
  /// Only exposure fields carry over: loop counts, dither and the like do not.
  void commitExposureEdit(
    ExposureNode node, {
    double? duration,
    int? count,
    String? filter,
    int? gain,
    int? offset,
    BinningMode? binning,
    int? ditherEvery,
  }) {
    read(currentSequenceProvider.notifier).updateNode(node);
    read(sequencerDefaultsProvider.notifier).updateExposureDefaults(
      duration: duration,
      count: count,
      filter: filter,
      gain: gain,
      offset: offset,
      binning: binning,
      ditherEvery: ditherEvery,
    );
  }
}
