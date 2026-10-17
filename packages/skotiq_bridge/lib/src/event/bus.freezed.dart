// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'bus.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EventPayload {

 Object get field0;



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));

@override
String toString() {
  return 'EventPayload(field0: $field0)';
}


}

/// @nodoc
class $EventPayloadCopyWith<$Res>  {
$EventPayloadCopyWith(EventPayload _, $Res Function(EventPayload) __);
}


/// Adds pattern-matching-related methods to [EventPayload].
extension EventPayloadPatterns on EventPayload {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( EventPayload_Equipment value)?  equipment,TResult Function( EventPayload_Imaging value)?  imaging,TResult Function( EventPayload_Guiding value)?  guiding,TResult Function( EventPayload_Sequencer value)?  sequencer,TResult Function( EventPayload_Safety value)?  safety,TResult Function( EventPayload_System value)?  system,TResult Function( EventPayload_PolarAlignment value)?  polarAlignment,TResult Function( EventPayload_PolarAlignmentStatus value)?  polarAlignmentStatus,TResult Function( EventPayload_PolarAlignmentImage value)?  polarAlignmentImage,TResult Function( EventPayload_DepthLock value)?  depthLock,required TResult orElse(),}){
final _that = this;
switch (_that) {
case EventPayload_Equipment() when equipment != null:
return equipment(_that);case EventPayload_Imaging() when imaging != null:
return imaging(_that);case EventPayload_Guiding() when guiding != null:
return guiding(_that);case EventPayload_Sequencer() when sequencer != null:
return sequencer(_that);case EventPayload_Safety() when safety != null:
return safety(_that);case EventPayload_System() when system != null:
return system(_that);case EventPayload_PolarAlignment() when polarAlignment != null:
return polarAlignment(_that);case EventPayload_PolarAlignmentStatus() when polarAlignmentStatus != null:
return polarAlignmentStatus(_that);case EventPayload_PolarAlignmentImage() when polarAlignmentImage != null:
return polarAlignmentImage(_that);case EventPayload_DepthLock() when depthLock != null:
return depthLock(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( EventPayload_Equipment value)  equipment,required TResult Function( EventPayload_Imaging value)  imaging,required TResult Function( EventPayload_Guiding value)  guiding,required TResult Function( EventPayload_Sequencer value)  sequencer,required TResult Function( EventPayload_Safety value)  safety,required TResult Function( EventPayload_System value)  system,required TResult Function( EventPayload_PolarAlignment value)  polarAlignment,required TResult Function( EventPayload_PolarAlignmentStatus value)  polarAlignmentStatus,required TResult Function( EventPayload_PolarAlignmentImage value)  polarAlignmentImage,required TResult Function( EventPayload_DepthLock value)  depthLock,}){
final _that = this;
switch (_that) {
case EventPayload_Equipment():
return equipment(_that);case EventPayload_Imaging():
return imaging(_that);case EventPayload_Guiding():
return guiding(_that);case EventPayload_Sequencer():
return sequencer(_that);case EventPayload_Safety():
return safety(_that);case EventPayload_System():
return system(_that);case EventPayload_PolarAlignment():
return polarAlignment(_that);case EventPayload_PolarAlignmentStatus():
return polarAlignmentStatus(_that);case EventPayload_PolarAlignmentImage():
return polarAlignmentImage(_that);case EventPayload_DepthLock():
return depthLock(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( EventPayload_Equipment value)?  equipment,TResult? Function( EventPayload_Imaging value)?  imaging,TResult? Function( EventPayload_Guiding value)?  guiding,TResult? Function( EventPayload_Sequencer value)?  sequencer,TResult? Function( EventPayload_Safety value)?  safety,TResult? Function( EventPayload_System value)?  system,TResult? Function( EventPayload_PolarAlignment value)?  polarAlignment,TResult? Function( EventPayload_PolarAlignmentStatus value)?  polarAlignmentStatus,TResult? Function( EventPayload_PolarAlignmentImage value)?  polarAlignmentImage,TResult? Function( EventPayload_DepthLock value)?  depthLock,}){
final _that = this;
switch (_that) {
case EventPayload_Equipment() when equipment != null:
return equipment(_that);case EventPayload_Imaging() when imaging != null:
return imaging(_that);case EventPayload_Guiding() when guiding != null:
return guiding(_that);case EventPayload_Sequencer() when sequencer != null:
return sequencer(_that);case EventPayload_Safety() when safety != null:
return safety(_that);case EventPayload_System() when system != null:
return system(_that);case EventPayload_PolarAlignment() when polarAlignment != null:
return polarAlignment(_that);case EventPayload_PolarAlignmentStatus() when polarAlignmentStatus != null:
return polarAlignmentStatus(_that);case EventPayload_PolarAlignmentImage() when polarAlignmentImage != null:
return polarAlignmentImage(_that);case EventPayload_DepthLock() when depthLock != null:
return depthLock(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( EquipmentEvent field0)?  equipment,TResult Function( ImagingEvent field0)?  imaging,TResult Function( GuidingEvent field0)?  guiding,TResult Function( SequencerEvent field0)?  sequencer,TResult Function( SafetyEvent field0)?  safety,TResult Function( SystemEvent field0)?  system,TResult Function( PolarAlignmentEvent field0)?  polarAlignment,TResult Function( PolarAlignmentStatus field0)?  polarAlignmentStatus,TResult Function( PolarAlignmentImageEvent field0)?  polarAlignmentImage,TResult Function( DepthLockEvent field0)?  depthLock,required TResult orElse(),}) {final _that = this;
switch (_that) {
case EventPayload_Equipment() when equipment != null:
return equipment(_that.field0);case EventPayload_Imaging() when imaging != null:
return imaging(_that.field0);case EventPayload_Guiding() when guiding != null:
return guiding(_that.field0);case EventPayload_Sequencer() when sequencer != null:
return sequencer(_that.field0);case EventPayload_Safety() when safety != null:
return safety(_that.field0);case EventPayload_System() when system != null:
return system(_that.field0);case EventPayload_PolarAlignment() when polarAlignment != null:
return polarAlignment(_that.field0);case EventPayload_PolarAlignmentStatus() when polarAlignmentStatus != null:
return polarAlignmentStatus(_that.field0);case EventPayload_PolarAlignmentImage() when polarAlignmentImage != null:
return polarAlignmentImage(_that.field0);case EventPayload_DepthLock() when depthLock != null:
return depthLock(_that.field0);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( EquipmentEvent field0)  equipment,required TResult Function( ImagingEvent field0)  imaging,required TResult Function( GuidingEvent field0)  guiding,required TResult Function( SequencerEvent field0)  sequencer,required TResult Function( SafetyEvent field0)  safety,required TResult Function( SystemEvent field0)  system,required TResult Function( PolarAlignmentEvent field0)  polarAlignment,required TResult Function( PolarAlignmentStatus field0)  polarAlignmentStatus,required TResult Function( PolarAlignmentImageEvent field0)  polarAlignmentImage,required TResult Function( DepthLockEvent field0)  depthLock,}) {final _that = this;
switch (_that) {
case EventPayload_Equipment():
return equipment(_that.field0);case EventPayload_Imaging():
return imaging(_that.field0);case EventPayload_Guiding():
return guiding(_that.field0);case EventPayload_Sequencer():
return sequencer(_that.field0);case EventPayload_Safety():
return safety(_that.field0);case EventPayload_System():
return system(_that.field0);case EventPayload_PolarAlignment():
return polarAlignment(_that.field0);case EventPayload_PolarAlignmentStatus():
return polarAlignmentStatus(_that.field0);case EventPayload_PolarAlignmentImage():
return polarAlignmentImage(_that.field0);case EventPayload_DepthLock():
return depthLock(_that.field0);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( EquipmentEvent field0)?  equipment,TResult? Function( ImagingEvent field0)?  imaging,TResult? Function( GuidingEvent field0)?  guiding,TResult? Function( SequencerEvent field0)?  sequencer,TResult? Function( SafetyEvent field0)?  safety,TResult? Function( SystemEvent field0)?  system,TResult? Function( PolarAlignmentEvent field0)?  polarAlignment,TResult? Function( PolarAlignmentStatus field0)?  polarAlignmentStatus,TResult? Function( PolarAlignmentImageEvent field0)?  polarAlignmentImage,TResult? Function( DepthLockEvent field0)?  depthLock,}) {final _that = this;
switch (_that) {
case EventPayload_Equipment() when equipment != null:
return equipment(_that.field0);case EventPayload_Imaging() when imaging != null:
return imaging(_that.field0);case EventPayload_Guiding() when guiding != null:
return guiding(_that.field0);case EventPayload_Sequencer() when sequencer != null:
return sequencer(_that.field0);case EventPayload_Safety() when safety != null:
return safety(_that.field0);case EventPayload_System() when system != null:
return system(_that.field0);case EventPayload_PolarAlignment() when polarAlignment != null:
return polarAlignment(_that.field0);case EventPayload_PolarAlignmentStatus() when polarAlignmentStatus != null:
return polarAlignmentStatus(_that.field0);case EventPayload_PolarAlignmentImage() when polarAlignmentImage != null:
return polarAlignmentImage(_that.field0);case EventPayload_DepthLock() when depthLock != null:
return depthLock(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class EventPayload_Equipment extends EventPayload {
  const EventPayload_Equipment(this.field0): super._();
  

@override final  EquipmentEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_EquipmentCopyWith<EventPayload_Equipment> get copyWith => _$EventPayload_EquipmentCopyWithImpl<EventPayload_Equipment>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_Equipment&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.equipment(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_EquipmentCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_EquipmentCopyWith(EventPayload_Equipment value, $Res Function(EventPayload_Equipment) _then) = _$EventPayload_EquipmentCopyWithImpl;
@useResult
$Res call({
 EquipmentEvent field0
});


$EquipmentEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_EquipmentCopyWithImpl<$Res>
    implements $EventPayload_EquipmentCopyWith<$Res> {
  _$EventPayload_EquipmentCopyWithImpl(this._self, this._then);

  final EventPayload_Equipment _self;
  final $Res Function(EventPayload_Equipment) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_Equipment(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as EquipmentEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$EquipmentEventCopyWith<$Res> get field0 {
  
  return $EquipmentEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

/// @nodoc


class EventPayload_Imaging extends EventPayload {
  const EventPayload_Imaging(this.field0): super._();
  

@override final  ImagingEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_ImagingCopyWith<EventPayload_Imaging> get copyWith => _$EventPayload_ImagingCopyWithImpl<EventPayload_Imaging>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_Imaging&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.imaging(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_ImagingCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_ImagingCopyWith(EventPayload_Imaging value, $Res Function(EventPayload_Imaging) _then) = _$EventPayload_ImagingCopyWithImpl;
@useResult
$Res call({
 ImagingEvent field0
});


$ImagingEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_ImagingCopyWithImpl<$Res>
    implements $EventPayload_ImagingCopyWith<$Res> {
  _$EventPayload_ImagingCopyWithImpl(this._self, this._then);

  final EventPayload_Imaging _self;
  final $Res Function(EventPayload_Imaging) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_Imaging(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as ImagingEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ImagingEventCopyWith<$Res> get field0 {
  
  return $ImagingEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

/// @nodoc


class EventPayload_Guiding extends EventPayload {
  const EventPayload_Guiding(this.field0): super._();
  

@override final  GuidingEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_GuidingCopyWith<EventPayload_Guiding> get copyWith => _$EventPayload_GuidingCopyWithImpl<EventPayload_Guiding>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_Guiding&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.guiding(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_GuidingCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_GuidingCopyWith(EventPayload_Guiding value, $Res Function(EventPayload_Guiding) _then) = _$EventPayload_GuidingCopyWithImpl;
@useResult
$Res call({
 GuidingEvent field0
});


$GuidingEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_GuidingCopyWithImpl<$Res>
    implements $EventPayload_GuidingCopyWith<$Res> {
  _$EventPayload_GuidingCopyWithImpl(this._self, this._then);

  final EventPayload_Guiding _self;
  final $Res Function(EventPayload_Guiding) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_Guiding(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as GuidingEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GuidingEventCopyWith<$Res> get field0 {
  
  return $GuidingEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

/// @nodoc


class EventPayload_Sequencer extends EventPayload {
  const EventPayload_Sequencer(this.field0): super._();
  

@override final  SequencerEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_SequencerCopyWith<EventPayload_Sequencer> get copyWith => _$EventPayload_SequencerCopyWithImpl<EventPayload_Sequencer>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_Sequencer&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.sequencer(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_SequencerCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_SequencerCopyWith(EventPayload_Sequencer value, $Res Function(EventPayload_Sequencer) _then) = _$EventPayload_SequencerCopyWithImpl;
@useResult
$Res call({
 SequencerEvent field0
});


$SequencerEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_SequencerCopyWithImpl<$Res>
    implements $EventPayload_SequencerCopyWith<$Res> {
  _$EventPayload_SequencerCopyWithImpl(this._self, this._then);

  final EventPayload_Sequencer _self;
  final $Res Function(EventPayload_Sequencer) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_Sequencer(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as SequencerEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SequencerEventCopyWith<$Res> get field0 {
  
  return $SequencerEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

/// @nodoc


class EventPayload_Safety extends EventPayload {
  const EventPayload_Safety(this.field0): super._();
  

@override final  SafetyEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_SafetyCopyWith<EventPayload_Safety> get copyWith => _$EventPayload_SafetyCopyWithImpl<EventPayload_Safety>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_Safety&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.safety(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_SafetyCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_SafetyCopyWith(EventPayload_Safety value, $Res Function(EventPayload_Safety) _then) = _$EventPayload_SafetyCopyWithImpl;
@useResult
$Res call({
 SafetyEvent field0
});


$SafetyEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_SafetyCopyWithImpl<$Res>
    implements $EventPayload_SafetyCopyWith<$Res> {
  _$EventPayload_SafetyCopyWithImpl(this._self, this._then);

  final EventPayload_Safety _self;
  final $Res Function(EventPayload_Safety) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_Safety(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as SafetyEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SafetyEventCopyWith<$Res> get field0 {
  
  return $SafetyEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

/// @nodoc


class EventPayload_System extends EventPayload {
  const EventPayload_System(this.field0): super._();
  

@override final  SystemEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_SystemCopyWith<EventPayload_System> get copyWith => _$EventPayload_SystemCopyWithImpl<EventPayload_System>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_System&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.system(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_SystemCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_SystemCopyWith(EventPayload_System value, $Res Function(EventPayload_System) _then) = _$EventPayload_SystemCopyWithImpl;
@useResult
$Res call({
 SystemEvent field0
});


$SystemEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_SystemCopyWithImpl<$Res>
    implements $EventPayload_SystemCopyWith<$Res> {
  _$EventPayload_SystemCopyWithImpl(this._self, this._then);

  final EventPayload_System _self;
  final $Res Function(EventPayload_System) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_System(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as SystemEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SystemEventCopyWith<$Res> get field0 {
  
  return $SystemEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

/// @nodoc


class EventPayload_PolarAlignment extends EventPayload {
  const EventPayload_PolarAlignment(this.field0): super._();
  

@override final  PolarAlignmentEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_PolarAlignmentCopyWith<EventPayload_PolarAlignment> get copyWith => _$EventPayload_PolarAlignmentCopyWithImpl<EventPayload_PolarAlignment>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_PolarAlignment&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.polarAlignment(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_PolarAlignmentCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_PolarAlignmentCopyWith(EventPayload_PolarAlignment value, $Res Function(EventPayload_PolarAlignment) _then) = _$EventPayload_PolarAlignmentCopyWithImpl;
@useResult
$Res call({
 PolarAlignmentEvent field0
});




}
/// @nodoc
class _$EventPayload_PolarAlignmentCopyWithImpl<$Res>
    implements $EventPayload_PolarAlignmentCopyWith<$Res> {
  _$EventPayload_PolarAlignmentCopyWithImpl(this._self, this._then);

  final EventPayload_PolarAlignment _self;
  final $Res Function(EventPayload_PolarAlignment) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_PolarAlignment(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PolarAlignmentEvent,
  ));
}


}

/// @nodoc


class EventPayload_PolarAlignmentStatus extends EventPayload {
  const EventPayload_PolarAlignmentStatus(this.field0): super._();
  

@override final  PolarAlignmentStatus field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_PolarAlignmentStatusCopyWith<EventPayload_PolarAlignmentStatus> get copyWith => _$EventPayload_PolarAlignmentStatusCopyWithImpl<EventPayload_PolarAlignmentStatus>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_PolarAlignmentStatus&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.polarAlignmentStatus(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_PolarAlignmentStatusCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_PolarAlignmentStatusCopyWith(EventPayload_PolarAlignmentStatus value, $Res Function(EventPayload_PolarAlignmentStatus) _then) = _$EventPayload_PolarAlignmentStatusCopyWithImpl;
@useResult
$Res call({
 PolarAlignmentStatus field0
});




}
/// @nodoc
class _$EventPayload_PolarAlignmentStatusCopyWithImpl<$Res>
    implements $EventPayload_PolarAlignmentStatusCopyWith<$Res> {
  _$EventPayload_PolarAlignmentStatusCopyWithImpl(this._self, this._then);

  final EventPayload_PolarAlignmentStatus _self;
  final $Res Function(EventPayload_PolarAlignmentStatus) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_PolarAlignmentStatus(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PolarAlignmentStatus,
  ));
}


}

/// @nodoc


class EventPayload_PolarAlignmentImage extends EventPayload {
  const EventPayload_PolarAlignmentImage(this.field0): super._();
  

@override final  PolarAlignmentImageEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_PolarAlignmentImageCopyWith<EventPayload_PolarAlignmentImage> get copyWith => _$EventPayload_PolarAlignmentImageCopyWithImpl<EventPayload_PolarAlignmentImage>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_PolarAlignmentImage&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.polarAlignmentImage(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_PolarAlignmentImageCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_PolarAlignmentImageCopyWith(EventPayload_PolarAlignmentImage value, $Res Function(EventPayload_PolarAlignmentImage) _then) = _$EventPayload_PolarAlignmentImageCopyWithImpl;
@useResult
$Res call({
 PolarAlignmentImageEvent field0
});




}
/// @nodoc
class _$EventPayload_PolarAlignmentImageCopyWithImpl<$Res>
    implements $EventPayload_PolarAlignmentImageCopyWith<$Res> {
  _$EventPayload_PolarAlignmentImageCopyWithImpl(this._self, this._then);

  final EventPayload_PolarAlignmentImage _self;
  final $Res Function(EventPayload_PolarAlignmentImage) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_PolarAlignmentImage(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PolarAlignmentImageEvent,
  ));
}


}

/// @nodoc


class EventPayload_DepthLock extends EventPayload {
  const EventPayload_DepthLock(this.field0): super._();
  

@override final  DepthLockEvent field0;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventPayload_DepthLockCopyWith<EventPayload_DepthLock> get copyWith => _$EventPayload_DepthLockCopyWithImpl<EventPayload_DepthLock>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventPayload_DepthLock&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventPayload.depthLock(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventPayload_DepthLockCopyWith<$Res> implements $EventPayloadCopyWith<$Res> {
  factory $EventPayload_DepthLockCopyWith(EventPayload_DepthLock value, $Res Function(EventPayload_DepthLock) _then) = _$EventPayload_DepthLockCopyWithImpl;
@useResult
$Res call({
 DepthLockEvent field0
});


$DepthLockEventCopyWith<$Res> get field0;

}
/// @nodoc
class _$EventPayload_DepthLockCopyWithImpl<$Res>
    implements $EventPayload_DepthLockCopyWith<$Res> {
  _$EventPayload_DepthLockCopyWithImpl(this._self, this._then);

  final EventPayload_DepthLock _self;
  final $Res Function(EventPayload_DepthLock) _then;

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventPayload_DepthLock(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as DepthLockEvent,
  ));
}

/// Create a copy of EventPayload
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$DepthLockEventCopyWith<$Res> get field0 {
  
  return $DepthLockEventCopyWith<$Res>(_self.field0, (value) {
    return _then(_self.copyWith(field0: value));
  });
}
}

// dart format on
