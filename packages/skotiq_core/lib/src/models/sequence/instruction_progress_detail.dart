import 'package:equatable/equatable.dart';

/// Typed per-instruction progress detail.
///
/// This runs alongside the legacy string detail while the native bridge and UI
/// migrate one instruction type at a time. Unknown variants are preserved so
/// newer native emitters do not become silent no-ops on older Dart clients.
sealed class InstructionProgressDetail extends Equatable {
  const InstructionProgressDetail();

  factory InstructionProgressDetail.fromStructuredData({
    required String detailKind,
    required Object? detailJson,
  }) {
    final json = _jsonMap(detailJson);
    switch (detailKind) {
      case 'Exposure':
        return ExposureInstructionProgressDetail(
          frame:
              _intValue(json['frame']) ?? _intValue(json['current_frame']) ?? 0,
          total:
              _intValue(json['total']) ?? _intValue(json['total_frames']) ?? 0,
          durationSecs:
              _doubleValue(json['duration_secs']) ??
              _doubleValue(json['durationSecs']) ??
              0,
        );
      default:
        return UnknownInstructionProgressDetail(
          kind: detailKind,
          rawJson: json,
        );
    }
  }
}

class ExposureInstructionProgressDetail extends InstructionProgressDetail {
  final int frame;
  final int total;
  final double durationSecs;

  const ExposureInstructionProgressDetail({
    required this.frame,
    required this.total,
    required this.durationSecs,
  });

  @override
  List<Object?> get props => [frame, total, durationSecs];
}

class UnknownInstructionProgressDetail extends InstructionProgressDetail {
  final String kind;
  final Map<String, Object?> rawJson;

  const UnknownInstructionProgressDetail({
    required this.kind,
    required this.rawJson,
  });

  @override
  List<Object?> get props => [kind, rawJson];
}

Map<String, Object?> _jsonMap(Object? raw) {
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

int? _intValue(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

double? _doubleValue(Object? raw) {
  if (raw is double) return raw;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw);
  return null;
}
