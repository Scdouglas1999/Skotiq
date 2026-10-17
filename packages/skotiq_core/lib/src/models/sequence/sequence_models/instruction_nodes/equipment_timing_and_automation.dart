// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Change filter instruction
class FilterChangeNode extends SequenceNode {
  final String filterName;
  final int? filterPosition;

  FilterChangeNode({
    super.id,
    super.name = 'Change Filter',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    required this.filterName,
    this.filterPosition,
  });

  @override
  String get nodeType => 'ChangeFilter';

  @override
  String get iconName => 'circle';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.filterWheel};

  @override
  FilterChangeNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    String? filterName,
    int? filterPosition,
  }) {
    return FilterChangeNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      filterName: filterName ?? this.filterName,
      filterPosition: filterPosition ?? this.filterPosition,
    );
  }

  @override
  List<Object?> get props => [...super.props, filterName, filterPosition];
}

/// Cool camera instruction
class CoolCameraNode extends SequenceNode {
  final double targetTemp;
  final double? durationMins;

  CoolCameraNode({
    super.id,
    super.name = 'Cool Camera',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.targetTemp = -10.0,
    this.durationMins = 10.0,
  });

  @override
  String get nodeType => 'CoolCamera';

  @override
  String get iconName => 'snowflake';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.camera};

  @override
  CoolCameraNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? targetTemp,
    double? durationMins,
  }) {
    return CoolCameraNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      targetTemp: targetTemp ?? this.targetTemp,
      durationMins: durationMins ?? this.durationMins,
    );
  }

  @override
  List<Object?> get props => [...super.props, targetTemp, durationMins];
}

/// Warm camera instruction
class WarmCameraNode extends SequenceNode {
  final double ratePerMin;
  final double targetTemp;

  WarmCameraNode({
    super.id,
    super.name = 'Warm Camera',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.ratePerMin = 2.0,
    this.targetTemp = 20.0,
  });

  @override
  String get nodeType => 'WarmCamera';

  @override
  String get iconName => 'flame';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.camera};

  @override
  WarmCameraNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? ratePerMin,
    double? targetTemp,
  }) {
    return WarmCameraNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      ratePerMin: ratePerMin ?? this.ratePerMin,
      targetTemp: targetTemp ?? this.targetTemp,
    );
  }

  @override
  List<Object?> get props => [...super.props, ratePerMin, targetTemp];
}

/// Move rotator instruction
class RotatorNode extends SequenceNode {
  final double targetAngle;
  final bool relative;

  RotatorNode({
    super.id,
    super.name = 'Move Rotator',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.targetAngle = 0.0,
    this.relative = false,
  });

  @override
  String get nodeType => 'MoveRotator';

  @override
  String get iconName => 'rotate-cw';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.rotator};

  @override
  RotatorNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? targetAngle,
    bool? relative,
  }) {
    return RotatorNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      targetAngle: targetAngle ?? this.targetAngle,
      relative: relative ?? this.relative,
    );
  }

  @override
  List<Object?> get props => [...super.props, targetAngle, relative];
}

/// Park mount instruction
class ParkNode extends SequenceNode {
  ParkNode({
    super.id,
    super.name = 'Park Mount',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
  });

  @override
  String get nodeType => 'Park';

  @override
  String get iconName => 'parking-circle';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount};

  @override
  ParkNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
  }) {
    return ParkNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
    );
  }
}

/// Unpark mount instruction
class UnparkNode extends SequenceNode {
  UnparkNode({
    super.id,
    super.name = 'Unpark Mount',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
  });

  @override
  String get nodeType => 'Unpark';

  @override
  String get iconName => 'unlock';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount};

  @override
  UnparkNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
  }) {
    return UnparkNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
    );
  }
}

/// Wait for time instruction
class WaitTimeNode extends SequenceNode {
  final DateTime? waitUntil;
  final TwilightType? waitForTwilight;

  WaitTimeNode({
    super.id,
    super.name = 'Wait for Time',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.waitUntil,
    this.waitForTwilight,
  });

  @override
  String get nodeType => 'WaitForTime';

  @override
  String get iconName => 'clock';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  WaitTimeNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    DateTime? waitUntil,
    TwilightType? waitForTwilight,
    bool clearWaitForTwilight = false,
    bool clearWaitUntil = false,
  }) {
    return WaitTimeNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      waitUntil: clearWaitUntil ? null : (waitUntil ?? this.waitUntil),
      waitForTwilight: clearWaitForTwilight
          ? null
          : (waitForTwilight ?? this.waitForTwilight),
    );
  }

  @override
  List<Object?> get props => [...super.props, waitUntil, waitForTwilight];
}

/// Delay instruction
class DelayNode extends SequenceNode {
  final double seconds;

  DelayNode({
    super.id,
    super.name = 'Delay',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.seconds = 5.0,
  });

  @override
  String get nodeType => 'Delay';

  @override
  String get iconName => 'timer';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  DelayNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? seconds,
  }) {
    return DelayNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      seconds: seconds ?? this.seconds,
    );
  }

  @override
  List<Object?> get props => [...super.props, seconds];
}

/// Notification instruction
class NotificationNode extends SequenceNode {
  final String title;
  final String message;
  final NotificationLevel level;

  /// Explicit transport override for this node only.
  ///
  /// When non-null, the executor's NotificationNode dispatcher hands this
  /// list to `NotificationRouter.routeNotificationNode(explicitTransports:)`
  /// which bypasses the matrix's `custom` rule. When null (legacy), the
  /// node inherits the matrix's `custom` transports.
  final List<NotificationTransportKind>? explicitTransports;

  NotificationNode({
    super.id,
    super.name = 'Send Notification',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.title = '',
    this.message = '',
    this.level = NotificationLevel.info,
    this.explicitTransports,
  });

  @override
  String get nodeType => 'Notification';

  @override
  String get iconName => 'bell';

  @override
  NodeCategory get category => NodeCategory.instruction;

  /// `copyWith` for `explicitTransports` uses plain keep-or-replace
  /// semantics:
  ///   * leave alone     → pass nothing (or `null`)
  ///   * set to a value  → pass the new list
  ///   * clear to default → pass `clearExplicitTransports: true`
  ///
  /// `clearExplicitTransports` wins over `explicitTransports` and nulls the
  /// field back to the matrix-default, so the editor's "use defaults" reset
  /// is a single `copyWith` call rather than a hand-rebuilt node.
  @override
  NotificationNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    String? title,
    String? message,
    NotificationLevel? level,
    List<NotificationTransportKind>? explicitTransports,
    bool clearExplicitTransports = false,
  }) {
    return NotificationNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      title: title ?? this.title,
      message: message ?? this.message,
      level: level ?? this.level,
      explicitTransports: clearExplicitTransports
          ? null
          : (explicitTransports ?? this.explicitTransports),
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    title,
    message,
    level,
    explicitTransports,
  ];
}

/// Script instruction
class ScriptNode extends SequenceNode {
  final String scriptPath;
  final List<String> arguments;
  final int? timeoutSecs;

  ScriptNode({
    super.id,
    super.name = 'Run Script',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.scriptPath = '',
    this.arguments = const [],
    this.timeoutSecs,
  });

  @override
  String get nodeType => 'RunScript';

  @override
  String get iconName => 'code';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  ScriptNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    String? scriptPath,
    List<String>? arguments,
    int? timeoutSecs,
  }) {
    return ScriptNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      scriptPath: scriptPath ?? this.scriptPath,
      arguments: arguments ?? this.arguments,
      timeoutSecs: timeoutSecs ?? this.timeoutSecs,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    scriptPath,
    arguments,
    timeoutSecs,
  ];
}
