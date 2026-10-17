// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Open cover instruction - opens a motorized dust cover / flat panel cover
class OpenCoverNode extends SequenceNode {
  final int timeoutSecs;

  OpenCoverNode({
    super.id,
    super.name = 'Open Cover',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.timeoutSecs = 60,
  });

  @override
  String get nodeType => 'OpenCover';

  @override
  String get iconName => 'door-open';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.coverCalibrator};

  @override
  OpenCoverNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    int? timeoutSecs,
  }) {
    return OpenCoverNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      timeoutSecs: timeoutSecs ?? this.timeoutSecs,
    );
  }

  @override
  List<Object?> get props => [...super.props, timeoutSecs];
}

/// Close cover instruction - closes a motorized dust cover / flat panel cover
class CloseCoverNode extends SequenceNode {
  final int timeoutSecs;

  CloseCoverNode({
    super.id,
    super.name = 'Close Cover',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.timeoutSecs = 60,
  });

  @override
  String get nodeType => 'CloseCover';

  @override
  String get iconName => 'door-closed';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.coverCalibrator};

  @override
  CloseCoverNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    int? timeoutSecs,
  }) {
    return CloseCoverNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      timeoutSecs: timeoutSecs ?? this.timeoutSecs,
    );
  }

  @override
  List<Object?> get props => [...super.props, timeoutSecs];
}

/// Calibrator on instruction - turns on flat panel at specified brightness
class CalibratorOnNode extends SequenceNode {
  final int brightness;
  final int timeoutSecs;

  CalibratorOnNode({
    super.id,
    super.name = 'Calibrator On',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.brightness = 128,
    this.timeoutSecs = 30,
  });

  @override
  String get nodeType => 'CalibratorOn';

  @override
  String get iconName => 'lightbulb';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.coverCalibrator};

  @override
  CalibratorOnNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    int? brightness,
    int? timeoutSecs,
  }) {
    return CalibratorOnNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      brightness: brightness ?? this.brightness,
      timeoutSecs: timeoutSecs ?? this.timeoutSecs,
    );
  }

  @override
  List<Object?> get props => [...super.props, brightness, timeoutSecs];
}

/// Calibrator off instruction - turns off flat panel light
class CalibratorOffNode extends SequenceNode {
  final int timeoutSecs;

  CalibratorOffNode({
    super.id,
    super.name = 'Calibrator Off',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.timeoutSecs = 30,
  });

  @override
  String get nodeType => 'CalibratorOff';

  @override
  String get iconName => 'lightbulb-off';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.coverCalibrator};

  @override
  CalibratorOffNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    int? timeoutSecs,
  }) {
    return CalibratorOffNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      timeoutSecs: timeoutSecs ?? this.timeoutSecs,
    );
  }

  @override
  List<Object?> get props => [...super.props, timeoutSecs];
}

// TargetScheduler — dynamic target picker

/// Brightness tier hint mirrored from
/// `crate::scheduling::adaptive_swap::BrightnessTier`. Used by
/// [TargetSchedulerNode]'s adaptive-swap logic to decide whether the
/// currently-running target's tier still accepts the live sky-conditions
/// score.
