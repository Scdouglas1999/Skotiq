import 'package:equatable/equatable.dart';

/// A named multi-night imaging campaign that groups several targets together.
///
/// Projects are the top-level organizing unit for the multi-night planner: an
/// operator creates a project ("Winter Nebulae", "Galaxy Season"), attaches a
/// set of targets to it via [ProjectTarget], and the planner rolls each
/// target's per-filter integration goals up into a single project-level
/// accrued-vs-remaining view (see `CampaignProgress`).
///
/// This is a plain immutable, hand-written model backed by a raw-SQL table
/// (mirrors the convention used by `IntegrationGoal` and the rest of the
/// scheduler stack — these scheduler tables are created via raw DDL and are not
/// part of Drift's reactive graph).
class Project extends Equatable {
  /// Database row id; null for a transient instance not yet persisted.
  final int? id;

  /// Human-readable project name. Required and shown in the planner UI.
  final String name;

  /// Optional free-text description / notes for the project.
  final String? description;

  /// Optional accent color (32-bit ARGB) used to tint the project in the UI.
  /// Null means "use the default surface accent" — the UI must not invent a
  /// color when this is absent. Stored as an integer column.
  final int? colorArgb;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Project({
    this.id,
    required this.name,
    this.description,
    this.colorArgb,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Builds a [Project] from a raw-SQL row.
  ///
  /// `createdAtUnix` / `updatedAtUnix` are **Unix seconds** (matching the
  /// `integration_goals` / scheduler table convention), converted here to
  /// local-zone [DateTime]s.
  factory Project.fromRow({
    required int id,
    required String name,
    String? description,
    int? colorArgb,
    required int createdAtUnix,
    required int updatedAtUnix,
  }) {
    return Project(
      id: id,
      name: name,
      description: description,
      colorArgb: colorArgb,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtUnix * 1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtUnix * 1000),
    );
  }

  Project copyWith({
    int? id,
    String? name,
    String? description,
    int? colorArgb,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearDescription = false,
    bool clearColor = false,
  }) {
    return Project(
      id: id ?? this.id,
      name: name ?? this.name,
      description: clearDescription ? null : (description ?? this.description),
      colorArgb: clearColor ? null : (colorArgb ?? this.colorArgb),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'colorArgb': colorArgb,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Tolerant decoder for [toJson] (host -> slave mirror over `/api/projects`).
  static Project fromJson(Map<String, dynamic> json) {
    DateTime parseTs(Object? v) => v is String
        ? (DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0))
        : DateTime.fromMillisecondsSinceEpoch(0);
    return Project(
      id: json['id'] as int?,
      name: json['name'] as String? ?? 'Untitled project',
      description: json['description'] as String?,
      colorArgb: json['colorArgb'] as int?,
      createdAt: parseTs(json['createdAt']),
      updatedAt: parseTs(json['updatedAt']),
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    colorArgb,
    createdAt,
    updatedAt,
  ];
}

/// Membership link between a [Project] and a target (FK to `targets.id`).
///
/// One row per (project, target) pairing. [priorityOverride] lets the operator
/// re-rank a target *within a project* without mutating the target's own global
/// priority — `null` means "use the target's own priority" (the scheduler reads
/// the override when present and falls back to the target row otherwise).
class ProjectTarget extends Equatable {
  /// Database row id; null for a transient instance not yet persisted.
  final int? id;

  /// FK to `projects.id`.
  final int projectId;

  /// FK to `targets.id`.
  final int targetId;

  /// Per-project priority override. `null` = inherit the target's own
  /// priority. Higher = preferred (matches the scheduler convention).
  final int? priorityOverride;

  final DateTime addedAt;

  const ProjectTarget({
    this.id,
    required this.projectId,
    required this.targetId,
    this.priorityOverride,
    required this.addedAt,
  });

  /// Builds a [ProjectTarget] from a raw-SQL row. `addedAtUnix` is **Unix
  /// seconds**.
  factory ProjectTarget.fromRow({
    required int id,
    required int projectId,
    required int targetId,
    int? priorityOverride,
    required int addedAtUnix,
  }) {
    return ProjectTarget(
      id: id,
      projectId: projectId,
      targetId: targetId,
      priorityOverride: priorityOverride,
      addedAt: DateTime.fromMillisecondsSinceEpoch(addedAtUnix * 1000),
    );
  }

  ProjectTarget copyWith({
    int? id,
    int? projectId,
    int? targetId,
    int? priorityOverride,
    DateTime? addedAt,
    bool clearPriorityOverride = false,
  }) {
    return ProjectTarget(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      targetId: targetId ?? this.targetId,
      priorityOverride: clearPriorityOverride
          ? null
          : (priorityOverride ?? this.priorityOverride),
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'targetId': targetId,
    'priorityOverride': priorityOverride,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };

  /// Tolerant decoder for [toJson] (host -> slave membership mirror).
  static ProjectTarget fromJson(Map<String, dynamic> json) {
    final added = json['addedAt'];
    return ProjectTarget(
      id: json['id'] as int?,
      projectId: json['projectId'] as int? ?? 0,
      targetId: json['targetId'] as int? ?? 0,
      priorityOverride: json['priorityOverride'] as int?,
      addedAt: added is String
          ? (DateTime.tryParse(added) ?? DateTime.fromMillisecondsSinceEpoch(0))
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  List<Object?> get props => [
    id,
    projectId,
    targetId,
    priorityOverride,
    addedAt,
  ];
}
