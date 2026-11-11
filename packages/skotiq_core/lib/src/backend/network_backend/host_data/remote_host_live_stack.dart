import 'dart:typed_data';

import 'package:skotiq_core/skotiq_core.dart';

/// [HostLiveStack] on a linked host.
final class RemoteHostLiveStack implements HostLiveStack {
  RemoteHostLiveStack(this._host);

  final NetworkBackend _host;

  @override
  Future<LiveStackingStats> stackingStart({
    String? referencePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) => _host.stackingStart(referencePath: referencePath, config: config);

  @override
  Future<void> stackingStop() => _host.stackingStop();

  @override
  Future<void> stackingReset() => _host.stackingReset();

  @override
  Future<LiveStackingResult> stackingAddFrame(String imagePath) =>
      _host.stackingAddFrame(imagePath);

  @override
  Future<LiveStackingStats> stackingGetStats() => _host.stackingGetStats();

  @override
  Future<LiveStackingResult> stackingGetResult() => _host.stackingGetResult();

  @override
  Future<List<RemoteStackedResult>> stackingGetSavedResults({int limit = 20}) =>
      _host.stackingGetSavedResults(limit: limit);

  @override
  Future<RemoteStackedResult> stackingGetSavedResult(int resultId) =>
      _host.stackingGetSavedResult(resultId);

  @override
  Future<Uint8List> stackingGetSavedResultPreview(int resultId) =>
      _host.stackingGetSavedResultPreview(resultId);
}
