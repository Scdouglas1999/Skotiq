import 'package:equatable/equatable.dart';

/// Camera preset for gain/offset settings
class CameraPreset extends Equatable {
  final String id;
  final String name;
  final int gain;
  final int offset;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const CameraPreset({
    required this.id,
    required this.name,
    required this.gain,
    required this.offset,
    required this.createdAt,
    this.updatedAt,
  });

  CameraPreset copyWith({
    String? id,
    String? name,
    int? gain,
    int? offset,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CameraPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'gain': gain,
      'offset': offset,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  factory CameraPreset.fromJson(Map<String, dynamic> json) {
    return CameraPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      gain: json['gain'] as int,
      offset: json['offset'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  @override
  List<Object?> get props => [id, name, gain, offset, createdAt, updatedAt];
}
