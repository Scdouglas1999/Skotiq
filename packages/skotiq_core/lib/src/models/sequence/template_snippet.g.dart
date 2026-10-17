// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'template_snippet.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_TemplateSnippet _$TemplateSnippetFromJson(Map<String, dynamic> json) =>
    _TemplateSnippet(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      category: $enumDecode(_$SnippetCategoryEnumMap, json['category']),
      iconName: json['iconName'] as String,
      nodeData: (json['nodeData'] as List<dynamic>)
          .map((e) => e as Map<String, dynamic>)
          .toList(),
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$TemplateSnippetToJson(_TemplateSnippet instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'description': instance.description,
      'category': _$SnippetCategoryEnumMap[instance.category]!,
      'iconName': instance.iconName,
      'nodeData': instance.nodeData,
      'isBuiltIn': instance.isBuiltIn,
      'createdAt': instance.createdAt.toIso8601String(),
    };

const _$SnippetCategoryEnumMap = {
  SnippetCategory.autofocus: 'autofocus',
  SnippetCategory.dithering: 'dithering',
  SnippetCategory.filterSequence: 'filterSequence',
  SnippetCategory.calibration: 'calibration',
  SnippetCategory.safety: 'safety',
  SnippetCategory.custom: 'custom',
};
