// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Instruction Set node - executes children sequentially once
class InstructionSetNode extends SequenceNode {
  InstructionSetNode({
    super.id,
    super.name = 'Instructions',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
  });

  @override
  String get nodeType => 'InstructionSet';

  @override
  String get iconName => 'list';

  @override
  NodeCategory get category => NodeCategory.logic;

  @override
  InstructionSetNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
  }) {
    return InstructionSetNode(
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
