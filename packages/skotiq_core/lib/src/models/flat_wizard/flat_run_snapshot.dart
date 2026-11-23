import 'dart:convert';

import 'flat_wizard_state.dart';

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

  Map<String, dynamic> toJson() => {
    'filter': filter,
    'exposureSeconds': exposureSeconds,
    'paths': paths,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
  };

  /// Throws [FormatException] for an entry missing a field a flat needs.
  factory FlatRunFilterOutput.fromJson(String key, Map<String, dynamic> map) {
    final filter = map['filter'];
    final exposure = map['exposureSeconds'];
    final paths = map['paths'];
    final binX = map['binX'];
    final binY = map['binY'];
    if (filter is! String ||
        exposure is! num ||
        !exposure.isFinite ||
        paths is! List ||
        paths.any((path) => path is! String) ||
        binX is! int ||
        binX < 1 ||
        binY is! int ||
        binY < 1) {
      throw FormatException('Flat run output for $key is incomplete');
    }
    return FlatRunFilterOutput(
      filter: filter,
      exposureSeconds: exposure.toDouble(),
      paths: List<String>.from(paths),
      gain: map['gain'] as int?,
      offset: map['offset'] as int?,
      binX: binX,
      binY: binY,
    );
  }
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

/// The imaging host's flat run as a linked client mirrors it: the wizard
/// state, whether a run holds the rig, the preview to fetch, and what the run
/// saved. Preview pixels travel separately, by [previewKey].
class FlatRunSnapshot {
  const FlatRunSnapshot({
    required this.state,
    required this.busy,
    this.previewKey,
    this.output = const {},
  });

  final FlatWizardState state;
  final bool busy;
  final String? previewKey;
  final Map<String, FlatRunFilterOutput> output;

  Map<String, dynamic> toJson() => {
    'state': flatWizardStateWire(state),
    'busy': busy,
    'previewKey': previewKey,
    'output': {
      for (final entry in output.entries) entry.key: entry.value.toJson(),
    },
  };

  /// Throws [FormatException] for a snapshot the two ends disagree about.
  factory FlatRunSnapshot.fromJson(Map<String, dynamic> json) {
    final raw = json['state'];
    if (raw is! Map) {
      throw const FormatException('Flat wizard snapshot has no state');
    }
    final FlatWizardState state;
    try {
      state = FlatWizardState.fromJson(Map<String, dynamic>.from(raw));
    } on Object catch (error) {
      throw FormatException('Flat wizard snapshot state is not usable: $error');
    }
    final key = json['previewKey'];
    return FlatRunSnapshot(
      state: state,
      busy: json['busy'] == true,
      previewKey: key is String ? key : null,
      output: _outputFromJson(json['output']),
    );
  }
}

/// Encode the nested Freezed settings and filters into plain wire maps.
Map<String, dynamic> flatWizardStateWire(FlatWizardState state) =>
    jsonDecode(jsonEncode(state)) as Map<String, dynamic>;

Map<String, FlatRunFilterOutput> _outputFromJson(Object? raw) {
  if (raw == null) return const {};
  if (raw is! Map) {
    throw const FormatException('Flat run output is not an object');
  }
  final filters = <String, FlatRunFilterOutput>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    if (key is! String || value is! Map) {
      throw const FormatException('Flat run output entry is not an object');
    }
    filters[key] = FlatRunFilterOutput.fromJson(
      key,
      Map<String, dynamic>.from(value),
    );
  }
  return filters;
}
