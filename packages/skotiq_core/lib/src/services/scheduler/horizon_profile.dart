import 'dart:convert';

import 'package:equatable/equatable.dart';

/// One azimuth/altitude pair defining a tree, building, or roof outline.
class HorizonSample extends Equatable {
  final double azimuthDegrees;
  final double altitudeDegrees;

  const HorizonSample(this.azimuthDegrees, this.altitudeDegrees);

  Map<String, dynamic> toJson() => {
    'az': azimuthDegrees,
    'alt': altitudeDegrees,
  };

  static HorizonSample fromJson(Map<String, dynamic> json) {
    return HorizonSample(
      (json['az'] as num).toDouble(),
      (json['alt'] as num).toDouble(),
    );
  }

  @override
  List<Object?> get props => [azimuthDegrees, altitudeDegrees];
}

/// A named site-horizon profile.
///
/// Encodes the operator's local obstructions as a series of (azimuth,
/// altitude) samples. Samples are interpolated linearly around the compass
/// so the user can describe a complex skyline with a small set of points.
class HorizonProfile extends Equatable {
  /// Database row id; null for transient instances not yet persisted.
  final int? id;

  /// Display name (e.g. "Backyard south fence + neighbour oak").
  final String name;

  /// Samples sorted by azimuth ascending. Must contain at least one entry;
  /// a single entry creates a flat horizon at that altitude.
  final List<HorizonSample> samples;

  const HorizonProfile({this.id, required this.name, required this.samples});

  /// Build the canonical flat horizon at a given altitude.
  factory HorizonProfile.flat({
    int? id,
    required String name,
    required double altitudeDegrees,
  }) {
    return HorizonProfile(
      id: id,
      name: name,
      samples: [HorizonSample(0.0, altitudeDegrees)],
    );
  }

  /// Minimum altitude (degrees) at the given azimuth, computed by linear
  /// interpolation between bracketing samples (with wrap-around at 360°).
  double minAltitudeAt(double azimuthDegrees) {
    if (samples.isEmpty) {
      throw StateError('HorizonProfile has no samples');
    }
    final az = _wrap360(azimuthDegrees);

    if (samples.length == 1) return samples.first.altitudeDegrees;

    final sorted = [...samples]
      ..sort((a, b) => a.azimuthDegrees.compareTo(b.azimuthDegrees));

    HorizonSample lower = sorted.last;
    HorizonSample upper = sorted.first;
    double lowerAz = _wrap360(lower.azimuthDegrees) - 360.0;
    double upperAz = _wrap360(upper.azimuthDegrees);

    for (var i = 0; i < sorted.length; i++) {
      final next = sorted[i];
      final nextAz = _wrap360(next.azimuthDegrees);
      if (nextAz >= az) {
        upper = next;
        upperAz = nextAz;
        if (i == 0) {
          lower = sorted.last;
          lowerAz = _wrap360(lower.azimuthDegrees) - 360.0;
        } else {
          lower = sorted[i - 1];
          lowerAz = _wrap360(lower.azimuthDegrees);
        }
        break;
      }
      lower = next;
      lowerAz = nextAz;
      if (i == sorted.length - 1) {
        upper = sorted.first;
        upperAz = _wrap360(upper.azimuthDegrees) + 360.0;
      }
    }

    final span = upperAz - lowerAz;
    if (span <= 0) return lower.altitudeDegrees;
    final t = (az - lowerAz) / span;
    return lower.altitudeDegrees +
        t * (upper.altitudeDegrees - lower.altitudeDegrees);
  }

  /// Serialize the samples list to the JSON column.
  String encodeSamples() {
    return jsonEncode(samples.map((s) => s.toJson()).toList());
  }

  /// Reconstruct from a database row.
  static HorizonProfile fromRow({
    required int id,
    required String name,
    required String samplesJson,
  }) {
    final list = jsonDecode(samplesJson) as List<dynamic>;
    if (list.isEmpty) {
      throw FormatException(
        'HorizonProfile $id ($name) has an empty samples list',
      );
    }
    return HorizonProfile(
      id: id,
      name: name,
      samples: list
          .map((e) => HorizonSample.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Wire serialization (host -> slave mirror): emits the same raw column
  /// shape the `horizon_profiles` table stores, so the slave can rebuild the
  /// profile with [fromRow]. Used by `/api/horizon-profiles`.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'samplesJson': encodeSamples(),
  };

  /// Tolerant decoder for the wire payload above.
  static HorizonProfile fromJson(Map<String, dynamic> json) {
    return HorizonProfile.fromRow(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      samplesJson: json['samplesJson'] as String? ?? '[]',
    );
  }

  /// Parse a multi-line "az alt" text dump (one pair per line) into a
  /// profile. Useful for importing horizon files from other planetariums.
  /// Whitespace and comma separators are accepted; lines starting with #
  /// or // are ignored.
  static HorizonProfile parseText({
    required String name,
    required String text,
    int? id,
  }) {
    final samples = <HorizonSample>[];
    var lineNum = 0;
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      lineNum++;
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#') || trimmed.startsWith('//')) continue;

      final parts = trimmed.split(RegExp(r'[\s,]+'));
      if (parts.length < 2) {
        throw FormatException(
          'Horizon profile "$name" line $lineNum: expected "az alt"',
        );
      }
      final az = double.tryParse(parts[0]);
      final alt = double.tryParse(parts[1]);
      if (az == null || alt == null) {
        throw FormatException(
          'Horizon profile "$name" line $lineNum: non-numeric value',
        );
      }
      samples.add(HorizonSample(az, alt));
    }
    if (samples.isEmpty) {
      throw FormatException(
        'Horizon profile "$name" contained no usable samples',
      );
    }
    return HorizonProfile(id: id, name: name, samples: samples);
  }

  static double _wrap360(double az) {
    var v = az % 360.0;
    if (v < 0) v += 360.0;
    return v;
  }

  @override
  List<Object?> get props => [id, name, samples];
}
