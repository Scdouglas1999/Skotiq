// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'depthlock_events.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$DepthLockEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DepthLockEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'DepthLockEvent()';
}


}

/// @nodoc
class $DepthLockEventCopyWith<$Res>  {
$DepthLockEventCopyWith(DepthLockEvent _, $Res Function(DepthLockEvent) __);
}


/// Adds pattern-matching-related methods to [DepthLockEvent].
extension DepthLockEventPatterns on DepthLockEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( DepthLockEvent_GoalUpdated value)?  goalUpdated,TResult Function( DepthLockEvent_EvidenceRejected value)?  evidenceRejected,TResult Function( DepthLockEvent_AnalysisDropped value)?  analysisDropped,TResult Function( DepthLockEvent_GoalChanged value)?  goalChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case DepthLockEvent_GoalUpdated() when goalUpdated != null:
return goalUpdated(_that);case DepthLockEvent_EvidenceRejected() when evidenceRejected != null:
return evidenceRejected(_that);case DepthLockEvent_AnalysisDropped() when analysisDropped != null:
return analysisDropped(_that);case DepthLockEvent_GoalChanged() when goalChanged != null:
return goalChanged(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( DepthLockEvent_GoalUpdated value)  goalUpdated,required TResult Function( DepthLockEvent_EvidenceRejected value)  evidenceRejected,required TResult Function( DepthLockEvent_AnalysisDropped value)  analysisDropped,required TResult Function( DepthLockEvent_GoalChanged value)  goalChanged,}){
final _that = this;
switch (_that) {
case DepthLockEvent_GoalUpdated():
return goalUpdated(_that);case DepthLockEvent_EvidenceRejected():
return evidenceRejected(_that);case DepthLockEvent_AnalysisDropped():
return analysisDropped(_that);case DepthLockEvent_GoalChanged():
return goalChanged(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( DepthLockEvent_GoalUpdated value)?  goalUpdated,TResult? Function( DepthLockEvent_EvidenceRejected value)?  evidenceRejected,TResult? Function( DepthLockEvent_AnalysisDropped value)?  analysisDropped,TResult? Function( DepthLockEvent_GoalChanged value)?  goalChanged,}){
final _that = this;
switch (_that) {
case DepthLockEvent_GoalUpdated() when goalUpdated != null:
return goalUpdated(_that);case DepthLockEvent_EvidenceRejected() when evidenceRejected != null:
return evidenceRejected(_that);case DepthLockEvent_AnalysisDropped() when analysisDropped != null:
return analysisDropped(_that);case DepthLockEvent_GoalChanged() when goalChanged != null:
return goalChanged(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String goalId,  BigInt revision,  String filterName,  String state,  double? score,  double? conservativeScore,  double threshold,  double? uncertaintyAdu,  double coverage,  int evidenceFrames,  int confirmationFrames,  String reason,  bool automaticCompletion,  int? framesRemaining,  bool reachable)?  goalUpdated,TResult Function( String goalId,  BigInt revision,  String sourcePath,  String reason)?  evidenceRejected,TResult Function( String sourcePath,  String reason)?  analysisDropped,TResult Function( String goalId,  BigInt revision,  String change)?  goalChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case DepthLockEvent_GoalUpdated() when goalUpdated != null:
return goalUpdated(_that.goalId,_that.revision,_that.filterName,_that.state,_that.score,_that.conservativeScore,_that.threshold,_that.uncertaintyAdu,_that.coverage,_that.evidenceFrames,_that.confirmationFrames,_that.reason,_that.automaticCompletion,_that.framesRemaining,_that.reachable);case DepthLockEvent_EvidenceRejected() when evidenceRejected != null:
return evidenceRejected(_that.goalId,_that.revision,_that.sourcePath,_that.reason);case DepthLockEvent_AnalysisDropped() when analysisDropped != null:
return analysisDropped(_that.sourcePath,_that.reason);case DepthLockEvent_GoalChanged() when goalChanged != null:
return goalChanged(_that.goalId,_that.revision,_that.change);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String goalId,  BigInt revision,  String filterName,  String state,  double? score,  double? conservativeScore,  double threshold,  double? uncertaintyAdu,  double coverage,  int evidenceFrames,  int confirmationFrames,  String reason,  bool automaticCompletion,  int? framesRemaining,  bool reachable)  goalUpdated,required TResult Function( String goalId,  BigInt revision,  String sourcePath,  String reason)  evidenceRejected,required TResult Function( String sourcePath,  String reason)  analysisDropped,required TResult Function( String goalId,  BigInt revision,  String change)  goalChanged,}) {final _that = this;
switch (_that) {
case DepthLockEvent_GoalUpdated():
return goalUpdated(_that.goalId,_that.revision,_that.filterName,_that.state,_that.score,_that.conservativeScore,_that.threshold,_that.uncertaintyAdu,_that.coverage,_that.evidenceFrames,_that.confirmationFrames,_that.reason,_that.automaticCompletion,_that.framesRemaining,_that.reachable);case DepthLockEvent_EvidenceRejected():
return evidenceRejected(_that.goalId,_that.revision,_that.sourcePath,_that.reason);case DepthLockEvent_AnalysisDropped():
return analysisDropped(_that.sourcePath,_that.reason);case DepthLockEvent_GoalChanged():
return goalChanged(_that.goalId,_that.revision,_that.change);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String goalId,  BigInt revision,  String filterName,  String state,  double? score,  double? conservativeScore,  double threshold,  double? uncertaintyAdu,  double coverage,  int evidenceFrames,  int confirmationFrames,  String reason,  bool automaticCompletion,  int? framesRemaining,  bool reachable)?  goalUpdated,TResult? Function( String goalId,  BigInt revision,  String sourcePath,  String reason)?  evidenceRejected,TResult? Function( String sourcePath,  String reason)?  analysisDropped,TResult? Function( String goalId,  BigInt revision,  String change)?  goalChanged,}) {final _that = this;
switch (_that) {
case DepthLockEvent_GoalUpdated() when goalUpdated != null:
return goalUpdated(_that.goalId,_that.revision,_that.filterName,_that.state,_that.score,_that.conservativeScore,_that.threshold,_that.uncertaintyAdu,_that.coverage,_that.evidenceFrames,_that.confirmationFrames,_that.reason,_that.automaticCompletion,_that.framesRemaining,_that.reachable);case DepthLockEvent_EvidenceRejected() when evidenceRejected != null:
return evidenceRejected(_that.goalId,_that.revision,_that.sourcePath,_that.reason);case DepthLockEvent_AnalysisDropped() when analysisDropped != null:
return analysisDropped(_that.sourcePath,_that.reason);case DepthLockEvent_GoalChanged() when goalChanged != null:
return goalChanged(_that.goalId,_that.revision,_that.change);case _:
  return null;

}
}

}

/// @nodoc


class DepthLockEvent_GoalUpdated extends DepthLockEvent {
  const DepthLockEvent_GoalUpdated({required this.goalId, required this.revision, required this.filterName, required this.state, this.score, this.conservativeScore, required this.threshold, this.uncertaintyAdu, required this.coverage, required this.evidenceFrames, required this.confirmationFrames, required this.reason, required this.automaticCompletion, this.framesRemaining, required this.reachable}): super._();
  

 final  String goalId;
 final  BigInt revision;
 final  String filterName;
/// `insufficientEvidence` | `collecting` | `confirmationPending` |
/// `achieved` | `unreliable`.
 final  String state;
 final  double? score;
 final  double? conservativeScore;
 final  double threshold;
 final  double? uncertaintyAdu;
 final  double coverage;
 final  int evidenceFrames;
 final  int confirmationFrames;
 final  String reason;
 final  bool automaticCompletion;
/// Exposures still needed (threshold plus confirmation), when the
/// noise model can say; `None` before anything is measurable or
/// when the goal is unreachable at its floor.
 final  int? framesRemaining;
 final  bool reachable;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DepthLockEvent_GoalUpdatedCopyWith<DepthLockEvent_GoalUpdated> get copyWith => _$DepthLockEvent_GoalUpdatedCopyWithImpl<DepthLockEvent_GoalUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DepthLockEvent_GoalUpdated&&(identical(other.goalId, goalId) || other.goalId == goalId)&&(identical(other.revision, revision) || other.revision == revision)&&(identical(other.filterName, filterName) || other.filterName == filterName)&&(identical(other.state, state) || other.state == state)&&(identical(other.score, score) || other.score == score)&&(identical(other.conservativeScore, conservativeScore) || other.conservativeScore == conservativeScore)&&(identical(other.threshold, threshold) || other.threshold == threshold)&&(identical(other.uncertaintyAdu, uncertaintyAdu) || other.uncertaintyAdu == uncertaintyAdu)&&(identical(other.coverage, coverage) || other.coverage == coverage)&&(identical(other.evidenceFrames, evidenceFrames) || other.evidenceFrames == evidenceFrames)&&(identical(other.confirmationFrames, confirmationFrames) || other.confirmationFrames == confirmationFrames)&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.automaticCompletion, automaticCompletion) || other.automaticCompletion == automaticCompletion)&&(identical(other.framesRemaining, framesRemaining) || other.framesRemaining == framesRemaining)&&(identical(other.reachable, reachable) || other.reachable == reachable));
}


@override
int get hashCode => Object.hash(runtimeType,goalId,revision,filterName,state,score,conservativeScore,threshold,uncertaintyAdu,coverage,evidenceFrames,confirmationFrames,reason,automaticCompletion,framesRemaining,reachable);

@override
String toString() {
  return 'DepthLockEvent.goalUpdated(goalId: $goalId, revision: $revision, filterName: $filterName, state: $state, score: $score, conservativeScore: $conservativeScore, threshold: $threshold, uncertaintyAdu: $uncertaintyAdu, coverage: $coverage, evidenceFrames: $evidenceFrames, confirmationFrames: $confirmationFrames, reason: $reason, automaticCompletion: $automaticCompletion, framesRemaining: $framesRemaining, reachable: $reachable)';
}


}

/// @nodoc
abstract mixin class $DepthLockEvent_GoalUpdatedCopyWith<$Res> implements $DepthLockEventCopyWith<$Res> {
  factory $DepthLockEvent_GoalUpdatedCopyWith(DepthLockEvent_GoalUpdated value, $Res Function(DepthLockEvent_GoalUpdated) _then) = _$DepthLockEvent_GoalUpdatedCopyWithImpl;
@useResult
$Res call({
 String goalId, BigInt revision, String filterName, String state, double? score, double? conservativeScore, double threshold, double? uncertaintyAdu, double coverage, int evidenceFrames, int confirmationFrames, String reason, bool automaticCompletion, int? framesRemaining, bool reachable
});




}
/// @nodoc
class _$DepthLockEvent_GoalUpdatedCopyWithImpl<$Res>
    implements $DepthLockEvent_GoalUpdatedCopyWith<$Res> {
  _$DepthLockEvent_GoalUpdatedCopyWithImpl(this._self, this._then);

  final DepthLockEvent_GoalUpdated _self;
  final $Res Function(DepthLockEvent_GoalUpdated) _then;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? goalId = null,Object? revision = null,Object? filterName = null,Object? state = null,Object? score = freezed,Object? conservativeScore = freezed,Object? threshold = null,Object? uncertaintyAdu = freezed,Object? coverage = null,Object? evidenceFrames = null,Object? confirmationFrames = null,Object? reason = null,Object? automaticCompletion = null,Object? framesRemaining = freezed,Object? reachable = null,}) {
  return _then(DepthLockEvent_GoalUpdated(
goalId: null == goalId ? _self.goalId : goalId // ignore: cast_nullable_to_non_nullable
as String,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as BigInt,filterName: null == filterName ? _self.filterName : filterName // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,score: freezed == score ? _self.score : score // ignore: cast_nullable_to_non_nullable
as double?,conservativeScore: freezed == conservativeScore ? _self.conservativeScore : conservativeScore // ignore: cast_nullable_to_non_nullable
as double?,threshold: null == threshold ? _self.threshold : threshold // ignore: cast_nullable_to_non_nullable
as double,uncertaintyAdu: freezed == uncertaintyAdu ? _self.uncertaintyAdu : uncertaintyAdu // ignore: cast_nullable_to_non_nullable
as double?,coverage: null == coverage ? _self.coverage : coverage // ignore: cast_nullable_to_non_nullable
as double,evidenceFrames: null == evidenceFrames ? _self.evidenceFrames : evidenceFrames // ignore: cast_nullable_to_non_nullable
as int,confirmationFrames: null == confirmationFrames ? _self.confirmationFrames : confirmationFrames // ignore: cast_nullable_to_non_nullable
as int,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,automaticCompletion: null == automaticCompletion ? _self.automaticCompletion : automaticCompletion // ignore: cast_nullable_to_non_nullable
as bool,framesRemaining: freezed == framesRemaining ? _self.framesRemaining : framesRemaining // ignore: cast_nullable_to_non_nullable
as int?,reachable: null == reachable ? _self.reachable : reachable // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class DepthLockEvent_EvidenceRejected extends DepthLockEvent {
  const DepthLockEvent_EvidenceRejected({required this.goalId, required this.revision, required this.sourcePath, required this.reason}): super._();
  

 final  String goalId;
 final  BigInt revision;
 final  String sourcePath;
 final  String reason;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DepthLockEvent_EvidenceRejectedCopyWith<DepthLockEvent_EvidenceRejected> get copyWith => _$DepthLockEvent_EvidenceRejectedCopyWithImpl<DepthLockEvent_EvidenceRejected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DepthLockEvent_EvidenceRejected&&(identical(other.goalId, goalId) || other.goalId == goalId)&&(identical(other.revision, revision) || other.revision == revision)&&(identical(other.sourcePath, sourcePath) || other.sourcePath == sourcePath)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,goalId,revision,sourcePath,reason);

@override
String toString() {
  return 'DepthLockEvent.evidenceRejected(goalId: $goalId, revision: $revision, sourcePath: $sourcePath, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $DepthLockEvent_EvidenceRejectedCopyWith<$Res> implements $DepthLockEventCopyWith<$Res> {
  factory $DepthLockEvent_EvidenceRejectedCopyWith(DepthLockEvent_EvidenceRejected value, $Res Function(DepthLockEvent_EvidenceRejected) _then) = _$DepthLockEvent_EvidenceRejectedCopyWithImpl;
@useResult
$Res call({
 String goalId, BigInt revision, String sourcePath, String reason
});




}
/// @nodoc
class _$DepthLockEvent_EvidenceRejectedCopyWithImpl<$Res>
    implements $DepthLockEvent_EvidenceRejectedCopyWith<$Res> {
  _$DepthLockEvent_EvidenceRejectedCopyWithImpl(this._self, this._then);

  final DepthLockEvent_EvidenceRejected _self;
  final $Res Function(DepthLockEvent_EvidenceRejected) _then;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? goalId = null,Object? revision = null,Object? sourcePath = null,Object? reason = null,}) {
  return _then(DepthLockEvent_EvidenceRejected(
goalId: null == goalId ? _self.goalId : goalId // ignore: cast_nullable_to_non_nullable
as String,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as BigInt,sourcePath: null == sourcePath ? _self.sourcePath : sourcePath // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class DepthLockEvent_AnalysisDropped extends DepthLockEvent {
  const DepthLockEvent_AnalysisDropped({required this.sourcePath, required this.reason}): super._();
  

 final  String sourcePath;
 final  String reason;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DepthLockEvent_AnalysisDroppedCopyWith<DepthLockEvent_AnalysisDropped> get copyWith => _$DepthLockEvent_AnalysisDroppedCopyWithImpl<DepthLockEvent_AnalysisDropped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DepthLockEvent_AnalysisDropped&&(identical(other.sourcePath, sourcePath) || other.sourcePath == sourcePath)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,sourcePath,reason);

@override
String toString() {
  return 'DepthLockEvent.analysisDropped(sourcePath: $sourcePath, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $DepthLockEvent_AnalysisDroppedCopyWith<$Res> implements $DepthLockEventCopyWith<$Res> {
  factory $DepthLockEvent_AnalysisDroppedCopyWith(DepthLockEvent_AnalysisDropped value, $Res Function(DepthLockEvent_AnalysisDropped) _then) = _$DepthLockEvent_AnalysisDroppedCopyWithImpl;
@useResult
$Res call({
 String sourcePath, String reason
});




}
/// @nodoc
class _$DepthLockEvent_AnalysisDroppedCopyWithImpl<$Res>
    implements $DepthLockEvent_AnalysisDroppedCopyWith<$Res> {
  _$DepthLockEvent_AnalysisDroppedCopyWithImpl(this._self, this._then);

  final DepthLockEvent_AnalysisDropped _self;
  final $Res Function(DepthLockEvent_AnalysisDropped) _then;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourcePath = null,Object? reason = null,}) {
  return _then(DepthLockEvent_AnalysisDropped(
sourcePath: null == sourcePath ? _self.sourcePath : sourcePath // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class DepthLockEvent_GoalChanged extends DepthLockEvent {
  const DepthLockEvent_GoalChanged({required this.goalId, required this.revision, required this.change}): super._();
  

 final  String goalId;
 final  BigInt revision;
 final  String change;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DepthLockEvent_GoalChangedCopyWith<DepthLockEvent_GoalChanged> get copyWith => _$DepthLockEvent_GoalChangedCopyWithImpl<DepthLockEvent_GoalChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DepthLockEvent_GoalChanged&&(identical(other.goalId, goalId) || other.goalId == goalId)&&(identical(other.revision, revision) || other.revision == revision)&&(identical(other.change, change) || other.change == change));
}


@override
int get hashCode => Object.hash(runtimeType,goalId,revision,change);

@override
String toString() {
  return 'DepthLockEvent.goalChanged(goalId: $goalId, revision: $revision, change: $change)';
}


}

/// @nodoc
abstract mixin class $DepthLockEvent_GoalChangedCopyWith<$Res> implements $DepthLockEventCopyWith<$Res> {
  factory $DepthLockEvent_GoalChangedCopyWith(DepthLockEvent_GoalChanged value, $Res Function(DepthLockEvent_GoalChanged) _then) = _$DepthLockEvent_GoalChangedCopyWithImpl;
@useResult
$Res call({
 String goalId, BigInt revision, String change
});




}
/// @nodoc
class _$DepthLockEvent_GoalChangedCopyWithImpl<$Res>
    implements $DepthLockEvent_GoalChangedCopyWith<$Res> {
  _$DepthLockEvent_GoalChangedCopyWithImpl(this._self, this._then);

  final DepthLockEvent_GoalChanged _self;
  final $Res Function(DepthLockEvent_GoalChanged) _then;

/// Create a copy of DepthLockEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? goalId = null,Object? revision = null,Object? change = null,}) {
  return _then(DepthLockEvent_GoalChanged(
goalId: null == goalId ? _self.goalId : goalId // ignore: cast_nullable_to_non_nullable
as String,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as BigInt,change: null == change ? _self.change : change // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
