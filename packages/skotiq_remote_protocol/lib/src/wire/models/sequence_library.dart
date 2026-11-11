/// Rows of the saved-sequence library as the host sends them
/// (`SequenceManagementApi`).
library;

import '../json_fields.dart';

/// One saved sequence in `GET /api/sequence-management/summaries`.
class SequenceSummaryDto {
  const SequenceSummaryDto({
    required this.id,
    required this.name,
    required this.nodeCount,
    required this.targetCount,
    required this.exposureCount,
    required this.totalIntegrationSecs,
    required this.runCount,
    required this.tags,
    required this.isFavorite,
    required this.createdAt,
    required this.modifiedAt,
    this.primaryTargetName,
    this.lastRunAt,
  });

  factory SequenceSummaryDto.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-summary row';
    final runCount = requiredInt(json, 'runCount', context, min: 0);
    final lastRunAt = optionalDate(json, 'lastRunAt', context);
    if ((runCount == 0) != (lastRunAt == null)) {
      throw const FormatException(
        'sequence-summary row runCount and lastRunAt disagree',
      );
    }
    final createdAt = requiredDate(json, 'createdAt', context);
    final modifiedAt = requiredDate(json, 'modifiedAt', context);
    if (modifiedAt.isBefore(createdAt)) {
      throw const FormatException(
        'sequence-summary row modifiedAt precedes createdAt',
      );
    }
    return SequenceSummaryDto(
      id: requiredInt(json, 'id', context, min: 1),
      name: requiredString(json, 'name', context),
      nodeCount: requiredInt(json, 'nodeCount', context, min: 0),
      targetCount: requiredInt(json, 'targetCount', context, min: 0),
      exposureCount: requiredInt(json, 'exposureCount', context, min: 0),
      totalIntegrationSecs: requiredInt(
        json,
        'totalIntegrationSecs',
        context,
        min: 0,
      ),
      primaryTargetName: optionalString(json, 'primaryTargetName', context),
      lastRunAt: lastRunAt,
      runCount: runCount,
      tags: requiredStringList(json, 'tags', context),
      isFavorite: requiredBool(json, 'isFavorite', context),
      createdAt: createdAt,
      modifiedAt: modifiedAt,
    );
  }

  final int id;
  final String name;
  final int nodeCount;
  final int targetCount;
  final int exposureCount;
  final int totalIntegrationSecs;
  final String? primaryTargetName;
  final DateTime? lastRunAt;
  final int runCount;
  final List<String> tags;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime modifiedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'nodeCount': nodeCount,
    'targetCount': targetCount,
    'exposureCount': exposureCount,
    'totalIntegrationSecs': totalIntegrationSecs,
    'primaryTargetName': primaryTargetName,
    'lastRunAt': lastRunAt?.toIso8601String(),
    'runCount': runCount,
    'tags': tags,
    'isFavorite': isFavorite,
    'createdAt': createdAt.toIso8601String(),
    'modifiedAt': modifiedAt.toIso8601String(),
  };
}

/// A saved version of a sequence, without its snapshot.
class SequenceVersionSummaryDto {
  const SequenceVersionSummaryDto({
    required this.id,
    required this.sequenceId,
    required this.createdAt,
    this.label,
  });

  factory SequenceVersionSummaryDto.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-version summary row';
    return SequenceVersionSummaryDto(
      id: requiredInt(json, 'id', context, min: 1),
      sequenceId: requiredInt(json, 'sequenceId', context, min: 1),
      label: optionalString(json, 'label', context, allowEmpty: true),
      createdAt: requiredDate(json, 'createdAt', context),
    );
  }

  final int id;
  final int sequenceId;
  final String? label;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sequenceId': sequenceId,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
  };
}

/// A saved version of a sequence with the serialized sequence it holds.
class SequenceVersionDto extends SequenceVersionSummaryDto {
  const SequenceVersionDto({
    required super.id,
    required super.sequenceId,
    required this.snapshotJson,
    required super.createdAt,
    super.label,
  });

  factory SequenceVersionDto.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-version row';
    return SequenceVersionDto(
      id: requiredInt(json, 'id', context, min: 1),
      sequenceId: requiredInt(json, 'sequenceId', context, min: 1),
      snapshotJson: requiredString(json, 'snapshotJson', context),
      label: optionalString(json, 'label', context, allowEmpty: true),
      createdAt: requiredDate(json, 'createdAt', context),
    );
  }

  final String snapshotJson;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'sequenceId': sequenceId,
    'snapshotJson': snapshotJson,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
  };
}
