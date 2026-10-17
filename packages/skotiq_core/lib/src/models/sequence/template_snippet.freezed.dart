// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'template_snippet.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$TemplateSnippet {

/// Unique identifier for this snippet
 String get id;/// Display name for the snippet
 String get name;/// Description of what this snippet does
 String get description;/// Category for organization
 SnippetCategory get category;/// Lucide icon name (e.g., 'focus', 'filter', 'shield')
 String get iconName;/// Serialized node data for recreation when inserting
 List<Map<String, dynamic>> get nodeData;/// Whether this is a built-in snippet (cannot be deleted)
 bool get isBuiltIn;/// When this snippet was created
 DateTime get createdAt;
/// Create a copy of TemplateSnippet
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TemplateSnippetCopyWith<TemplateSnippet> get copyWith => _$TemplateSnippetCopyWithImpl<TemplateSnippet>(this as TemplateSnippet, _$identity);

  /// Serializes this TemplateSnippet to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TemplateSnippet&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.category, category) || other.category == category)&&(identical(other.iconName, iconName) || other.iconName == iconName)&&const DeepCollectionEquality().equals(other.nodeData, nodeData)&&(identical(other.isBuiltIn, isBuiltIn) || other.isBuiltIn == isBuiltIn)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,description,category,iconName,const DeepCollectionEquality().hash(nodeData),isBuiltIn,createdAt);

@override
String toString() {
  return 'TemplateSnippet(id: $id, name: $name, description: $description, category: $category, iconName: $iconName, nodeData: $nodeData, isBuiltIn: $isBuiltIn, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $TemplateSnippetCopyWith<$Res>  {
  factory $TemplateSnippetCopyWith(TemplateSnippet value, $Res Function(TemplateSnippet) _then) = _$TemplateSnippetCopyWithImpl;
@useResult
$Res call({
 String id, String name, String description, SnippetCategory category, String iconName, List<Map<String, dynamic>> nodeData, bool isBuiltIn, DateTime createdAt
});




}
/// @nodoc
class _$TemplateSnippetCopyWithImpl<$Res>
    implements $TemplateSnippetCopyWith<$Res> {
  _$TemplateSnippetCopyWithImpl(this._self, this._then);

  final TemplateSnippet _self;
  final $Res Function(TemplateSnippet) _then;

/// Create a copy of TemplateSnippet
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? description = null,Object? category = null,Object? iconName = null,Object? nodeData = null,Object? isBuiltIn = null,Object? createdAt = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as SnippetCategory,iconName: null == iconName ? _self.iconName : iconName // ignore: cast_nullable_to_non_nullable
as String,nodeData: null == nodeData ? _self.nodeData : nodeData // ignore: cast_nullable_to_non_nullable
as List<Map<String, dynamic>>,isBuiltIn: null == isBuiltIn ? _self.isBuiltIn : isBuiltIn // ignore: cast_nullable_to_non_nullable
as bool,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [TemplateSnippet].
extension TemplateSnippetPatterns on TemplateSnippet {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TemplateSnippet value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TemplateSnippet() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TemplateSnippet value)  $default,){
final _that = this;
switch (_that) {
case _TemplateSnippet():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TemplateSnippet value)?  $default,){
final _that = this;
switch (_that) {
case _TemplateSnippet() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String description,  SnippetCategory category,  String iconName,  List<Map<String, dynamic>> nodeData,  bool isBuiltIn,  DateTime createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TemplateSnippet() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.category,_that.iconName,_that.nodeData,_that.isBuiltIn,_that.createdAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String description,  SnippetCategory category,  String iconName,  List<Map<String, dynamic>> nodeData,  bool isBuiltIn,  DateTime createdAt)  $default,) {final _that = this;
switch (_that) {
case _TemplateSnippet():
return $default(_that.id,_that.name,_that.description,_that.category,_that.iconName,_that.nodeData,_that.isBuiltIn,_that.createdAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String description,  SnippetCategory category,  String iconName,  List<Map<String, dynamic>> nodeData,  bool isBuiltIn,  DateTime createdAt)?  $default,) {final _that = this;
switch (_that) {
case _TemplateSnippet() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.category,_that.iconName,_that.nodeData,_that.isBuiltIn,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TemplateSnippet extends TemplateSnippet {
  const _TemplateSnippet({required this.id, required this.name, required this.description, required this.category, required this.iconName, required final  List<Map<String, dynamic>> nodeData, this.isBuiltIn = false, required this.createdAt}): _nodeData = nodeData,super._();
  factory _TemplateSnippet.fromJson(Map<String, dynamic> json) => _$TemplateSnippetFromJson(json);

/// Unique identifier for this snippet
@override final  String id;
/// Display name for the snippet
@override final  String name;
/// Description of what this snippet does
@override final  String description;
/// Category for organization
@override final  SnippetCategory category;
/// Lucide icon name (e.g., 'focus', 'filter', 'shield')
@override final  String iconName;
/// Serialized node data for recreation when inserting
 final  List<Map<String, dynamic>> _nodeData;
/// Serialized node data for recreation when inserting
@override List<Map<String, dynamic>> get nodeData {
  if (_nodeData is EqualUnmodifiableListView) return _nodeData;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_nodeData);
}

/// Whether this is a built-in snippet (cannot be deleted)
@override@JsonKey() final  bool isBuiltIn;
/// When this snippet was created
@override final  DateTime createdAt;

/// Create a copy of TemplateSnippet
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TemplateSnippetCopyWith<_TemplateSnippet> get copyWith => __$TemplateSnippetCopyWithImpl<_TemplateSnippet>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TemplateSnippetToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TemplateSnippet&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.category, category) || other.category == category)&&(identical(other.iconName, iconName) || other.iconName == iconName)&&const DeepCollectionEquality().equals(other._nodeData, _nodeData)&&(identical(other.isBuiltIn, isBuiltIn) || other.isBuiltIn == isBuiltIn)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,description,category,iconName,const DeepCollectionEquality().hash(_nodeData),isBuiltIn,createdAt);

@override
String toString() {
  return 'TemplateSnippet(id: $id, name: $name, description: $description, category: $category, iconName: $iconName, nodeData: $nodeData, isBuiltIn: $isBuiltIn, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$TemplateSnippetCopyWith<$Res> implements $TemplateSnippetCopyWith<$Res> {
  factory _$TemplateSnippetCopyWith(_TemplateSnippet value, $Res Function(_TemplateSnippet) _then) = __$TemplateSnippetCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String description, SnippetCategory category, String iconName, List<Map<String, dynamic>> nodeData, bool isBuiltIn, DateTime createdAt
});




}
/// @nodoc
class __$TemplateSnippetCopyWithImpl<$Res>
    implements _$TemplateSnippetCopyWith<$Res> {
  __$TemplateSnippetCopyWithImpl(this._self, this._then);

  final _TemplateSnippet _self;
  final $Res Function(_TemplateSnippet) _then;

/// Create a copy of TemplateSnippet
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? description = null,Object? category = null,Object? iconName = null,Object? nodeData = null,Object? isBuiltIn = null,Object? createdAt = null,}) {
  return _then(_TemplateSnippet(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as SnippetCategory,iconName: null == iconName ? _self.iconName : iconName // ignore: cast_nullable_to_non_nullable
as String,nodeData: null == nodeData ? _self._nodeData : nodeData // ignore: cast_nullable_to_non_nullable
as List<Map<String, dynamic>>,isBuiltIn: null == isBuiltIn ? _self.isBuiltIn : isBuiltIn // ignore: cast_nullable_to_non_nullable
as bool,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}

// dart format on
