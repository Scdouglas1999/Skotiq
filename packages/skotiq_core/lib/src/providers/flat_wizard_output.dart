import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The flats one filter of the latest flat-wizard run saved.
class FlatRunFilterOutput {
  const FlatRunFilterOutput({
    required this.filter,
    required this.exposureSeconds,
    required this.paths,
    this.gain,
    this.offset,
    this.binX = 1,
    this.binY = 1,
  });

  final String filter;
  final double exposureSeconds;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;
  final List<String> paths;

  FlatRunFilterOutput withPath(String path) => FlatRunFilterOutput(
    filter: filter,
    exposureSeconds: exposureSeconds,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    paths: [...paths, path],
  );
}

/// What the latest flat-wizard run saved, by filter, in capture order.
class FlatRunOutput {
  const FlatRunOutput({this.filters = const {}, this.remote = false});

  final Map<String, FlatRunFilterOutput> filters;

  /// The frames were saved on a remote imaging computer.
  final bool remote;

  int get frameCount =>
      filters.values.fold(0, (sum, f) => sum + f.paths.length);

  bool get isEmpty => filters.isEmpty;
}

final flatRunOutputProvider = StateProvider<FlatRunOutput>(
  (ref) => const FlatRunOutput(),
);
