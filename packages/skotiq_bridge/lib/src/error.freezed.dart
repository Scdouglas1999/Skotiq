// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'error.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SkotiqError {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SkotiqError()';
}


}

/// @nodoc
class $SkotiqErrorCopyWith<$Res>  {
$SkotiqErrorCopyWith(SkotiqError _, $Res Function(SkotiqError) __);
}


/// Adds pattern-matching-related methods to [SkotiqError].
extension SkotiqErrorPatterns on SkotiqError {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SkotiqError_DeviceNotFound value)?  deviceNotFound,TResult Function( SkotiqError_ConnectionFailed value)?  connectionFailed,TResult Function( SkotiqError_AlreadyConnected value)?  alreadyConnected,TResult Function( SkotiqError_NotConnected value)?  notConnected,TResult Function( SkotiqError_DeviceDisconnected value)?  deviceDisconnected,TResult Function( SkotiqError_HardwareError value)?  hardwareError,TResult Function( SkotiqError_CommunicationError value)?  communicationError,TResult Function( SkotiqError_Timeout value)?  timeout,TResult Function( SkotiqError_DeviceTimeout value)?  deviceTimeout,TResult Function( SkotiqError_ConnectionTimeout value)?  connectionTimeout,TResult Function( SkotiqError_InvalidParameter value)?  invalidParameter,TResult Function( SkotiqError_InvalidInput value)?  invalidInput,TResult Function( SkotiqError_InvalidDeviceId value)?  invalidDeviceId,TResult Function( SkotiqError_ParameterOutOfRange value)?  parameterOutOfRange,TResult Function( SkotiqError_OperationFailed value)?  operationFailed,TResult Function( SkotiqError_NotSupported value)?  notSupported,TResult Function( SkotiqError_DeviceBusy value)?  deviceBusy,TResult Function( SkotiqError_ImageError value)?  imageError,TResult Function( SkotiqError_CameraError value)?  cameraError,TResult Function( SkotiqError_NoImageAvailable value)?  noImageAvailable,TResult Function( SkotiqError_ExposureCancelled value)?  exposureCancelled,TResult Function( SkotiqError_ExposureFailed value)?  exposureFailed,TResult Function( SkotiqError_DownloadFailed value)?  downloadFailed,TResult Function( SkotiqError_IoError value)?  ioError,TResult Function( SkotiqError_SerializationError value)?  serializationError,TResult Function( SkotiqError_PlateSolveError value)?  plateSolveError,TResult Function( SkotiqError_SequenceError value)?  sequenceError,TResult Function( SkotiqError_AscomError value)?  ascomError,TResult Function( SkotiqError_AlpacaError value)?  alpacaError,TResult Function( SkotiqError_IndiError value)?  indiError,TResult Function( SkotiqError_NativeError value)?  nativeError,TResult Function( SkotiqError_ComError value)?  comError,TResult Function( SkotiqError_Internal value)?  internal,TResult Function( SkotiqError_Cancelled value)?  cancelled,TResult Function( SkotiqError_RuntimeInitFailed value)?  runtimeInitFailed,TResult Function( SkotiqError_ResourceExhausted value)?  resourceExhausted,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SkotiqError_DeviceNotFound() when deviceNotFound != null:
return deviceNotFound(_that);case SkotiqError_ConnectionFailed() when connectionFailed != null:
return connectionFailed(_that);case SkotiqError_AlreadyConnected() when alreadyConnected != null:
return alreadyConnected(_that);case SkotiqError_NotConnected() when notConnected != null:
return notConnected(_that);case SkotiqError_DeviceDisconnected() when deviceDisconnected != null:
return deviceDisconnected(_that);case SkotiqError_HardwareError() when hardwareError != null:
return hardwareError(_that);case SkotiqError_CommunicationError() when communicationError != null:
return communicationError(_that);case SkotiqError_Timeout() when timeout != null:
return timeout(_that);case SkotiqError_DeviceTimeout() when deviceTimeout != null:
return deviceTimeout(_that);case SkotiqError_ConnectionTimeout() when connectionTimeout != null:
return connectionTimeout(_that);case SkotiqError_InvalidParameter() when invalidParameter != null:
return invalidParameter(_that);case SkotiqError_InvalidInput() when invalidInput != null:
return invalidInput(_that);case SkotiqError_InvalidDeviceId() when invalidDeviceId != null:
return invalidDeviceId(_that);case SkotiqError_ParameterOutOfRange() when parameterOutOfRange != null:
return parameterOutOfRange(_that);case SkotiqError_OperationFailed() when operationFailed != null:
return operationFailed(_that);case SkotiqError_NotSupported() when notSupported != null:
return notSupported(_that);case SkotiqError_DeviceBusy() when deviceBusy != null:
return deviceBusy(_that);case SkotiqError_ImageError() when imageError != null:
return imageError(_that);case SkotiqError_CameraError() when cameraError != null:
return cameraError(_that);case SkotiqError_NoImageAvailable() when noImageAvailable != null:
return noImageAvailable(_that);case SkotiqError_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled(_that);case SkotiqError_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that);case SkotiqError_DownloadFailed() when downloadFailed != null:
return downloadFailed(_that);case SkotiqError_IoError() when ioError != null:
return ioError(_that);case SkotiqError_SerializationError() when serializationError != null:
return serializationError(_that);case SkotiqError_PlateSolveError() when plateSolveError != null:
return plateSolveError(_that);case SkotiqError_SequenceError() when sequenceError != null:
return sequenceError(_that);case SkotiqError_AscomError() when ascomError != null:
return ascomError(_that);case SkotiqError_AlpacaError() when alpacaError != null:
return alpacaError(_that);case SkotiqError_IndiError() when indiError != null:
return indiError(_that);case SkotiqError_NativeError() when nativeError != null:
return nativeError(_that);case SkotiqError_ComError() when comError != null:
return comError(_that);case SkotiqError_Internal() when internal != null:
return internal(_that);case SkotiqError_Cancelled() when cancelled != null:
return cancelled(_that);case SkotiqError_RuntimeInitFailed() when runtimeInitFailed != null:
return runtimeInitFailed(_that);case SkotiqError_ResourceExhausted() when resourceExhausted != null:
return resourceExhausted(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SkotiqError_DeviceNotFound value)  deviceNotFound,required TResult Function( SkotiqError_ConnectionFailed value)  connectionFailed,required TResult Function( SkotiqError_AlreadyConnected value)  alreadyConnected,required TResult Function( SkotiqError_NotConnected value)  notConnected,required TResult Function( SkotiqError_DeviceDisconnected value)  deviceDisconnected,required TResult Function( SkotiqError_HardwareError value)  hardwareError,required TResult Function( SkotiqError_CommunicationError value)  communicationError,required TResult Function( SkotiqError_Timeout value)  timeout,required TResult Function( SkotiqError_DeviceTimeout value)  deviceTimeout,required TResult Function( SkotiqError_ConnectionTimeout value)  connectionTimeout,required TResult Function( SkotiqError_InvalidParameter value)  invalidParameter,required TResult Function( SkotiqError_InvalidInput value)  invalidInput,required TResult Function( SkotiqError_InvalidDeviceId value)  invalidDeviceId,required TResult Function( SkotiqError_ParameterOutOfRange value)  parameterOutOfRange,required TResult Function( SkotiqError_OperationFailed value)  operationFailed,required TResult Function( SkotiqError_NotSupported value)  notSupported,required TResult Function( SkotiqError_DeviceBusy value)  deviceBusy,required TResult Function( SkotiqError_ImageError value)  imageError,required TResult Function( SkotiqError_CameraError value)  cameraError,required TResult Function( SkotiqError_NoImageAvailable value)  noImageAvailable,required TResult Function( SkotiqError_ExposureCancelled value)  exposureCancelled,required TResult Function( SkotiqError_ExposureFailed value)  exposureFailed,required TResult Function( SkotiqError_DownloadFailed value)  downloadFailed,required TResult Function( SkotiqError_IoError value)  ioError,required TResult Function( SkotiqError_SerializationError value)  serializationError,required TResult Function( SkotiqError_PlateSolveError value)  plateSolveError,required TResult Function( SkotiqError_SequenceError value)  sequenceError,required TResult Function( SkotiqError_AscomError value)  ascomError,required TResult Function( SkotiqError_AlpacaError value)  alpacaError,required TResult Function( SkotiqError_IndiError value)  indiError,required TResult Function( SkotiqError_NativeError value)  nativeError,required TResult Function( SkotiqError_ComError value)  comError,required TResult Function( SkotiqError_Internal value)  internal,required TResult Function( SkotiqError_Cancelled value)  cancelled,required TResult Function( SkotiqError_RuntimeInitFailed value)  runtimeInitFailed,required TResult Function( SkotiqError_ResourceExhausted value)  resourceExhausted,}){
final _that = this;
switch (_that) {
case SkotiqError_DeviceNotFound():
return deviceNotFound(_that);case SkotiqError_ConnectionFailed():
return connectionFailed(_that);case SkotiqError_AlreadyConnected():
return alreadyConnected(_that);case SkotiqError_NotConnected():
return notConnected(_that);case SkotiqError_DeviceDisconnected():
return deviceDisconnected(_that);case SkotiqError_HardwareError():
return hardwareError(_that);case SkotiqError_CommunicationError():
return communicationError(_that);case SkotiqError_Timeout():
return timeout(_that);case SkotiqError_DeviceTimeout():
return deviceTimeout(_that);case SkotiqError_ConnectionTimeout():
return connectionTimeout(_that);case SkotiqError_InvalidParameter():
return invalidParameter(_that);case SkotiqError_InvalidInput():
return invalidInput(_that);case SkotiqError_InvalidDeviceId():
return invalidDeviceId(_that);case SkotiqError_ParameterOutOfRange():
return parameterOutOfRange(_that);case SkotiqError_OperationFailed():
return operationFailed(_that);case SkotiqError_NotSupported():
return notSupported(_that);case SkotiqError_DeviceBusy():
return deviceBusy(_that);case SkotiqError_ImageError():
return imageError(_that);case SkotiqError_CameraError():
return cameraError(_that);case SkotiqError_NoImageAvailable():
return noImageAvailable(_that);case SkotiqError_ExposureCancelled():
return exposureCancelled(_that);case SkotiqError_ExposureFailed():
return exposureFailed(_that);case SkotiqError_DownloadFailed():
return downloadFailed(_that);case SkotiqError_IoError():
return ioError(_that);case SkotiqError_SerializationError():
return serializationError(_that);case SkotiqError_PlateSolveError():
return plateSolveError(_that);case SkotiqError_SequenceError():
return sequenceError(_that);case SkotiqError_AscomError():
return ascomError(_that);case SkotiqError_AlpacaError():
return alpacaError(_that);case SkotiqError_IndiError():
return indiError(_that);case SkotiqError_NativeError():
return nativeError(_that);case SkotiqError_ComError():
return comError(_that);case SkotiqError_Internal():
return internal(_that);case SkotiqError_Cancelled():
return cancelled(_that);case SkotiqError_RuntimeInitFailed():
return runtimeInitFailed(_that);case SkotiqError_ResourceExhausted():
return resourceExhausted(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SkotiqError_DeviceNotFound value)?  deviceNotFound,TResult? Function( SkotiqError_ConnectionFailed value)?  connectionFailed,TResult? Function( SkotiqError_AlreadyConnected value)?  alreadyConnected,TResult? Function( SkotiqError_NotConnected value)?  notConnected,TResult? Function( SkotiqError_DeviceDisconnected value)?  deviceDisconnected,TResult? Function( SkotiqError_HardwareError value)?  hardwareError,TResult? Function( SkotiqError_CommunicationError value)?  communicationError,TResult? Function( SkotiqError_Timeout value)?  timeout,TResult? Function( SkotiqError_DeviceTimeout value)?  deviceTimeout,TResult? Function( SkotiqError_ConnectionTimeout value)?  connectionTimeout,TResult? Function( SkotiqError_InvalidParameter value)?  invalidParameter,TResult? Function( SkotiqError_InvalidInput value)?  invalidInput,TResult? Function( SkotiqError_InvalidDeviceId value)?  invalidDeviceId,TResult? Function( SkotiqError_ParameterOutOfRange value)?  parameterOutOfRange,TResult? Function( SkotiqError_OperationFailed value)?  operationFailed,TResult? Function( SkotiqError_NotSupported value)?  notSupported,TResult? Function( SkotiqError_DeviceBusy value)?  deviceBusy,TResult? Function( SkotiqError_ImageError value)?  imageError,TResult? Function( SkotiqError_CameraError value)?  cameraError,TResult? Function( SkotiqError_NoImageAvailable value)?  noImageAvailable,TResult? Function( SkotiqError_ExposureCancelled value)?  exposureCancelled,TResult? Function( SkotiqError_ExposureFailed value)?  exposureFailed,TResult? Function( SkotiqError_DownloadFailed value)?  downloadFailed,TResult? Function( SkotiqError_IoError value)?  ioError,TResult? Function( SkotiqError_SerializationError value)?  serializationError,TResult? Function( SkotiqError_PlateSolveError value)?  plateSolveError,TResult? Function( SkotiqError_SequenceError value)?  sequenceError,TResult? Function( SkotiqError_AscomError value)?  ascomError,TResult? Function( SkotiqError_AlpacaError value)?  alpacaError,TResult? Function( SkotiqError_IndiError value)?  indiError,TResult? Function( SkotiqError_NativeError value)?  nativeError,TResult? Function( SkotiqError_ComError value)?  comError,TResult? Function( SkotiqError_Internal value)?  internal,TResult? Function( SkotiqError_Cancelled value)?  cancelled,TResult? Function( SkotiqError_RuntimeInitFailed value)?  runtimeInitFailed,TResult? Function( SkotiqError_ResourceExhausted value)?  resourceExhausted,}){
final _that = this;
switch (_that) {
case SkotiqError_DeviceNotFound() when deviceNotFound != null:
return deviceNotFound(_that);case SkotiqError_ConnectionFailed() when connectionFailed != null:
return connectionFailed(_that);case SkotiqError_AlreadyConnected() when alreadyConnected != null:
return alreadyConnected(_that);case SkotiqError_NotConnected() when notConnected != null:
return notConnected(_that);case SkotiqError_DeviceDisconnected() when deviceDisconnected != null:
return deviceDisconnected(_that);case SkotiqError_HardwareError() when hardwareError != null:
return hardwareError(_that);case SkotiqError_CommunicationError() when communicationError != null:
return communicationError(_that);case SkotiqError_Timeout() when timeout != null:
return timeout(_that);case SkotiqError_DeviceTimeout() when deviceTimeout != null:
return deviceTimeout(_that);case SkotiqError_ConnectionTimeout() when connectionTimeout != null:
return connectionTimeout(_that);case SkotiqError_InvalidParameter() when invalidParameter != null:
return invalidParameter(_that);case SkotiqError_InvalidInput() when invalidInput != null:
return invalidInput(_that);case SkotiqError_InvalidDeviceId() when invalidDeviceId != null:
return invalidDeviceId(_that);case SkotiqError_ParameterOutOfRange() when parameterOutOfRange != null:
return parameterOutOfRange(_that);case SkotiqError_OperationFailed() when operationFailed != null:
return operationFailed(_that);case SkotiqError_NotSupported() when notSupported != null:
return notSupported(_that);case SkotiqError_DeviceBusy() when deviceBusy != null:
return deviceBusy(_that);case SkotiqError_ImageError() when imageError != null:
return imageError(_that);case SkotiqError_CameraError() when cameraError != null:
return cameraError(_that);case SkotiqError_NoImageAvailable() when noImageAvailable != null:
return noImageAvailable(_that);case SkotiqError_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled(_that);case SkotiqError_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that);case SkotiqError_DownloadFailed() when downloadFailed != null:
return downloadFailed(_that);case SkotiqError_IoError() when ioError != null:
return ioError(_that);case SkotiqError_SerializationError() when serializationError != null:
return serializationError(_that);case SkotiqError_PlateSolveError() when plateSolveError != null:
return plateSolveError(_that);case SkotiqError_SequenceError() when sequenceError != null:
return sequenceError(_that);case SkotiqError_AscomError() when ascomError != null:
return ascomError(_that);case SkotiqError_AlpacaError() when alpacaError != null:
return alpacaError(_that);case SkotiqError_IndiError() when indiError != null:
return indiError(_that);case SkotiqError_NativeError() when nativeError != null:
return nativeError(_that);case SkotiqError_ComError() when comError != null:
return comError(_that);case SkotiqError_Internal() when internal != null:
return internal(_that);case SkotiqError_Cancelled() when cancelled != null:
return cancelled(_that);case SkotiqError_RuntimeInitFailed() when runtimeInitFailed != null:
return runtimeInitFailed(_that);case SkotiqError_ResourceExhausted() when resourceExhausted != null:
return resourceExhausted(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  deviceNotFound,TResult Function( String deviceId,  String reason)?  connectionFailed,TResult Function( String field0)?  alreadyConnected,TResult Function( String field0)?  notConnected,TResult Function( String deviceId,  String reason)?  deviceDisconnected,TResult Function( String deviceId,  String message,  int? errorCode)?  hardwareError,TResult Function( String deviceId,  String message)?  communicationError,TResult Function( String field0)?  timeout,TResult Function( String deviceId,  String operation,  double timeoutSecs)?  deviceTimeout,TResult Function( String deviceId,  double timeoutSecs)?  connectionTimeout,TResult Function( String field0)?  invalidParameter,TResult Function( String field0)?  invalidInput,TResult Function( String deviceId,  String reason)?  invalidDeviceId,TResult Function( String paramName,  String value,  String min,  String max)?  parameterOutOfRange,TResult Function( String field0)?  operationFailed,TResult Function( String deviceId,  String operation)?  notSupported,TResult Function( String deviceId,  String currentOperation)?  deviceBusy,TResult Function( String field0)?  imageError,TResult Function( String field0)?  cameraError,TResult Function()?  noImageAvailable,TResult Function()?  exposureCancelled,TResult Function( String cameraId,  String reason)?  exposureFailed,TResult Function( String cameraId,  String reason)?  downloadFailed,TResult Function( String field0)?  ioError,TResult Function( String field0)?  serializationError,TResult Function( String field0)?  plateSolveError,TResult Function( String field0)?  sequenceError,TResult Function( String progId,  String message,  int errorCode)?  ascomError,TResult Function( String baseUrl,  int deviceNumber,  String message,  int errorCode)?  alpacaError,TResult Function( String server,  int port,  String deviceName,  String message)?  indiError,TResult Function( String vendor,  String message,  int errorCode)?  nativeError,TResult Function( String message,  int hresult)?  comError,TResult Function( String field0)?  internal,TResult Function()?  cancelled,TResult Function( String field0)?  runtimeInitFailed,TResult Function( String resource,  String message)?  resourceExhausted,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SkotiqError_DeviceNotFound() when deviceNotFound != null:
return deviceNotFound(_that.field0);case SkotiqError_ConnectionFailed() when connectionFailed != null:
return connectionFailed(_that.deviceId,_that.reason);case SkotiqError_AlreadyConnected() when alreadyConnected != null:
return alreadyConnected(_that.field0);case SkotiqError_NotConnected() when notConnected != null:
return notConnected(_that.field0);case SkotiqError_DeviceDisconnected() when deviceDisconnected != null:
return deviceDisconnected(_that.deviceId,_that.reason);case SkotiqError_HardwareError() when hardwareError != null:
return hardwareError(_that.deviceId,_that.message,_that.errorCode);case SkotiqError_CommunicationError() when communicationError != null:
return communicationError(_that.deviceId,_that.message);case SkotiqError_Timeout() when timeout != null:
return timeout(_that.field0);case SkotiqError_DeviceTimeout() when deviceTimeout != null:
return deviceTimeout(_that.deviceId,_that.operation,_that.timeoutSecs);case SkotiqError_ConnectionTimeout() when connectionTimeout != null:
return connectionTimeout(_that.deviceId,_that.timeoutSecs);case SkotiqError_InvalidParameter() when invalidParameter != null:
return invalidParameter(_that.field0);case SkotiqError_InvalidInput() when invalidInput != null:
return invalidInput(_that.field0);case SkotiqError_InvalidDeviceId() when invalidDeviceId != null:
return invalidDeviceId(_that.deviceId,_that.reason);case SkotiqError_ParameterOutOfRange() when parameterOutOfRange != null:
return parameterOutOfRange(_that.paramName,_that.value,_that.min,_that.max);case SkotiqError_OperationFailed() when operationFailed != null:
return operationFailed(_that.field0);case SkotiqError_NotSupported() when notSupported != null:
return notSupported(_that.deviceId,_that.operation);case SkotiqError_DeviceBusy() when deviceBusy != null:
return deviceBusy(_that.deviceId,_that.currentOperation);case SkotiqError_ImageError() when imageError != null:
return imageError(_that.field0);case SkotiqError_CameraError() when cameraError != null:
return cameraError(_that.field0);case SkotiqError_NoImageAvailable() when noImageAvailable != null:
return noImageAvailable();case SkotiqError_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled();case SkotiqError_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that.cameraId,_that.reason);case SkotiqError_DownloadFailed() when downloadFailed != null:
return downloadFailed(_that.cameraId,_that.reason);case SkotiqError_IoError() when ioError != null:
return ioError(_that.field0);case SkotiqError_SerializationError() when serializationError != null:
return serializationError(_that.field0);case SkotiqError_PlateSolveError() when plateSolveError != null:
return plateSolveError(_that.field0);case SkotiqError_SequenceError() when sequenceError != null:
return sequenceError(_that.field0);case SkotiqError_AscomError() when ascomError != null:
return ascomError(_that.progId,_that.message,_that.errorCode);case SkotiqError_AlpacaError() when alpacaError != null:
return alpacaError(_that.baseUrl,_that.deviceNumber,_that.message,_that.errorCode);case SkotiqError_IndiError() when indiError != null:
return indiError(_that.server,_that.port,_that.deviceName,_that.message);case SkotiqError_NativeError() when nativeError != null:
return nativeError(_that.vendor,_that.message,_that.errorCode);case SkotiqError_ComError() when comError != null:
return comError(_that.message,_that.hresult);case SkotiqError_Internal() when internal != null:
return internal(_that.field0);case SkotiqError_Cancelled() when cancelled != null:
return cancelled();case SkotiqError_RuntimeInitFailed() when runtimeInitFailed != null:
return runtimeInitFailed(_that.field0);case SkotiqError_ResourceExhausted() when resourceExhausted != null:
return resourceExhausted(_that.resource,_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  deviceNotFound,required TResult Function( String deviceId,  String reason)  connectionFailed,required TResult Function( String field0)  alreadyConnected,required TResult Function( String field0)  notConnected,required TResult Function( String deviceId,  String reason)  deviceDisconnected,required TResult Function( String deviceId,  String message,  int? errorCode)  hardwareError,required TResult Function( String deviceId,  String message)  communicationError,required TResult Function( String field0)  timeout,required TResult Function( String deviceId,  String operation,  double timeoutSecs)  deviceTimeout,required TResult Function( String deviceId,  double timeoutSecs)  connectionTimeout,required TResult Function( String field0)  invalidParameter,required TResult Function( String field0)  invalidInput,required TResult Function( String deviceId,  String reason)  invalidDeviceId,required TResult Function( String paramName,  String value,  String min,  String max)  parameterOutOfRange,required TResult Function( String field0)  operationFailed,required TResult Function( String deviceId,  String operation)  notSupported,required TResult Function( String deviceId,  String currentOperation)  deviceBusy,required TResult Function( String field0)  imageError,required TResult Function( String field0)  cameraError,required TResult Function()  noImageAvailable,required TResult Function()  exposureCancelled,required TResult Function( String cameraId,  String reason)  exposureFailed,required TResult Function( String cameraId,  String reason)  downloadFailed,required TResult Function( String field0)  ioError,required TResult Function( String field0)  serializationError,required TResult Function( String field0)  plateSolveError,required TResult Function( String field0)  sequenceError,required TResult Function( String progId,  String message,  int errorCode)  ascomError,required TResult Function( String baseUrl,  int deviceNumber,  String message,  int errorCode)  alpacaError,required TResult Function( String server,  int port,  String deviceName,  String message)  indiError,required TResult Function( String vendor,  String message,  int errorCode)  nativeError,required TResult Function( String message,  int hresult)  comError,required TResult Function( String field0)  internal,required TResult Function()  cancelled,required TResult Function( String field0)  runtimeInitFailed,required TResult Function( String resource,  String message)  resourceExhausted,}) {final _that = this;
switch (_that) {
case SkotiqError_DeviceNotFound():
return deviceNotFound(_that.field0);case SkotiqError_ConnectionFailed():
return connectionFailed(_that.deviceId,_that.reason);case SkotiqError_AlreadyConnected():
return alreadyConnected(_that.field0);case SkotiqError_NotConnected():
return notConnected(_that.field0);case SkotiqError_DeviceDisconnected():
return deviceDisconnected(_that.deviceId,_that.reason);case SkotiqError_HardwareError():
return hardwareError(_that.deviceId,_that.message,_that.errorCode);case SkotiqError_CommunicationError():
return communicationError(_that.deviceId,_that.message);case SkotiqError_Timeout():
return timeout(_that.field0);case SkotiqError_DeviceTimeout():
return deviceTimeout(_that.deviceId,_that.operation,_that.timeoutSecs);case SkotiqError_ConnectionTimeout():
return connectionTimeout(_that.deviceId,_that.timeoutSecs);case SkotiqError_InvalidParameter():
return invalidParameter(_that.field0);case SkotiqError_InvalidInput():
return invalidInput(_that.field0);case SkotiqError_InvalidDeviceId():
return invalidDeviceId(_that.deviceId,_that.reason);case SkotiqError_ParameterOutOfRange():
return parameterOutOfRange(_that.paramName,_that.value,_that.min,_that.max);case SkotiqError_OperationFailed():
return operationFailed(_that.field0);case SkotiqError_NotSupported():
return notSupported(_that.deviceId,_that.operation);case SkotiqError_DeviceBusy():
return deviceBusy(_that.deviceId,_that.currentOperation);case SkotiqError_ImageError():
return imageError(_that.field0);case SkotiqError_CameraError():
return cameraError(_that.field0);case SkotiqError_NoImageAvailable():
return noImageAvailable();case SkotiqError_ExposureCancelled():
return exposureCancelled();case SkotiqError_ExposureFailed():
return exposureFailed(_that.cameraId,_that.reason);case SkotiqError_DownloadFailed():
return downloadFailed(_that.cameraId,_that.reason);case SkotiqError_IoError():
return ioError(_that.field0);case SkotiqError_SerializationError():
return serializationError(_that.field0);case SkotiqError_PlateSolveError():
return plateSolveError(_that.field0);case SkotiqError_SequenceError():
return sequenceError(_that.field0);case SkotiqError_AscomError():
return ascomError(_that.progId,_that.message,_that.errorCode);case SkotiqError_AlpacaError():
return alpacaError(_that.baseUrl,_that.deviceNumber,_that.message,_that.errorCode);case SkotiqError_IndiError():
return indiError(_that.server,_that.port,_that.deviceName,_that.message);case SkotiqError_NativeError():
return nativeError(_that.vendor,_that.message,_that.errorCode);case SkotiqError_ComError():
return comError(_that.message,_that.hresult);case SkotiqError_Internal():
return internal(_that.field0);case SkotiqError_Cancelled():
return cancelled();case SkotiqError_RuntimeInitFailed():
return runtimeInitFailed(_that.field0);case SkotiqError_ResourceExhausted():
return resourceExhausted(_that.resource,_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  deviceNotFound,TResult? Function( String deviceId,  String reason)?  connectionFailed,TResult? Function( String field0)?  alreadyConnected,TResult? Function( String field0)?  notConnected,TResult? Function( String deviceId,  String reason)?  deviceDisconnected,TResult? Function( String deviceId,  String message,  int? errorCode)?  hardwareError,TResult? Function( String deviceId,  String message)?  communicationError,TResult? Function( String field0)?  timeout,TResult? Function( String deviceId,  String operation,  double timeoutSecs)?  deviceTimeout,TResult? Function( String deviceId,  double timeoutSecs)?  connectionTimeout,TResult? Function( String field0)?  invalidParameter,TResult? Function( String field0)?  invalidInput,TResult? Function( String deviceId,  String reason)?  invalidDeviceId,TResult? Function( String paramName,  String value,  String min,  String max)?  parameterOutOfRange,TResult? Function( String field0)?  operationFailed,TResult? Function( String deviceId,  String operation)?  notSupported,TResult? Function( String deviceId,  String currentOperation)?  deviceBusy,TResult? Function( String field0)?  imageError,TResult? Function( String field0)?  cameraError,TResult? Function()?  noImageAvailable,TResult? Function()?  exposureCancelled,TResult? Function( String cameraId,  String reason)?  exposureFailed,TResult? Function( String cameraId,  String reason)?  downloadFailed,TResult? Function( String field0)?  ioError,TResult? Function( String field0)?  serializationError,TResult? Function( String field0)?  plateSolveError,TResult? Function( String field0)?  sequenceError,TResult? Function( String progId,  String message,  int errorCode)?  ascomError,TResult? Function( String baseUrl,  int deviceNumber,  String message,  int errorCode)?  alpacaError,TResult? Function( String server,  int port,  String deviceName,  String message)?  indiError,TResult? Function( String vendor,  String message,  int errorCode)?  nativeError,TResult? Function( String message,  int hresult)?  comError,TResult? Function( String field0)?  internal,TResult? Function()?  cancelled,TResult? Function( String field0)?  runtimeInitFailed,TResult? Function( String resource,  String message)?  resourceExhausted,}) {final _that = this;
switch (_that) {
case SkotiqError_DeviceNotFound() when deviceNotFound != null:
return deviceNotFound(_that.field0);case SkotiqError_ConnectionFailed() when connectionFailed != null:
return connectionFailed(_that.deviceId,_that.reason);case SkotiqError_AlreadyConnected() when alreadyConnected != null:
return alreadyConnected(_that.field0);case SkotiqError_NotConnected() when notConnected != null:
return notConnected(_that.field0);case SkotiqError_DeviceDisconnected() when deviceDisconnected != null:
return deviceDisconnected(_that.deviceId,_that.reason);case SkotiqError_HardwareError() when hardwareError != null:
return hardwareError(_that.deviceId,_that.message,_that.errorCode);case SkotiqError_CommunicationError() when communicationError != null:
return communicationError(_that.deviceId,_that.message);case SkotiqError_Timeout() when timeout != null:
return timeout(_that.field0);case SkotiqError_DeviceTimeout() when deviceTimeout != null:
return deviceTimeout(_that.deviceId,_that.operation,_that.timeoutSecs);case SkotiqError_ConnectionTimeout() when connectionTimeout != null:
return connectionTimeout(_that.deviceId,_that.timeoutSecs);case SkotiqError_InvalidParameter() when invalidParameter != null:
return invalidParameter(_that.field0);case SkotiqError_InvalidInput() when invalidInput != null:
return invalidInput(_that.field0);case SkotiqError_InvalidDeviceId() when invalidDeviceId != null:
return invalidDeviceId(_that.deviceId,_that.reason);case SkotiqError_ParameterOutOfRange() when parameterOutOfRange != null:
return parameterOutOfRange(_that.paramName,_that.value,_that.min,_that.max);case SkotiqError_OperationFailed() when operationFailed != null:
return operationFailed(_that.field0);case SkotiqError_NotSupported() when notSupported != null:
return notSupported(_that.deviceId,_that.operation);case SkotiqError_DeviceBusy() when deviceBusy != null:
return deviceBusy(_that.deviceId,_that.currentOperation);case SkotiqError_ImageError() when imageError != null:
return imageError(_that.field0);case SkotiqError_CameraError() when cameraError != null:
return cameraError(_that.field0);case SkotiqError_NoImageAvailable() when noImageAvailable != null:
return noImageAvailable();case SkotiqError_ExposureCancelled() when exposureCancelled != null:
return exposureCancelled();case SkotiqError_ExposureFailed() when exposureFailed != null:
return exposureFailed(_that.cameraId,_that.reason);case SkotiqError_DownloadFailed() when downloadFailed != null:
return downloadFailed(_that.cameraId,_that.reason);case SkotiqError_IoError() when ioError != null:
return ioError(_that.field0);case SkotiqError_SerializationError() when serializationError != null:
return serializationError(_that.field0);case SkotiqError_PlateSolveError() when plateSolveError != null:
return plateSolveError(_that.field0);case SkotiqError_SequenceError() when sequenceError != null:
return sequenceError(_that.field0);case SkotiqError_AscomError() when ascomError != null:
return ascomError(_that.progId,_that.message,_that.errorCode);case SkotiqError_AlpacaError() when alpacaError != null:
return alpacaError(_that.baseUrl,_that.deviceNumber,_that.message,_that.errorCode);case SkotiqError_IndiError() when indiError != null:
return indiError(_that.server,_that.port,_that.deviceName,_that.message);case SkotiqError_NativeError() when nativeError != null:
return nativeError(_that.vendor,_that.message,_that.errorCode);case SkotiqError_ComError() when comError != null:
return comError(_that.message,_that.hresult);case SkotiqError_Internal() when internal != null:
return internal(_that.field0);case SkotiqError_Cancelled() when cancelled != null:
return cancelled();case SkotiqError_RuntimeInitFailed() when runtimeInitFailed != null:
return runtimeInitFailed(_that.field0);case SkotiqError_ResourceExhausted() when resourceExhausted != null:
return resourceExhausted(_that.resource,_that.message);case _:
  return null;

}
}

}

/// @nodoc


class SkotiqError_DeviceNotFound extends SkotiqError {
  const SkotiqError_DeviceNotFound(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_DeviceNotFoundCopyWith<SkotiqError_DeviceNotFound> get copyWith => _$SkotiqError_DeviceNotFoundCopyWithImpl<SkotiqError_DeviceNotFound>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_DeviceNotFound&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.deviceNotFound(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_DeviceNotFoundCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_DeviceNotFoundCopyWith(SkotiqError_DeviceNotFound value, $Res Function(SkotiqError_DeviceNotFound) _then) = _$SkotiqError_DeviceNotFoundCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_DeviceNotFoundCopyWithImpl<$Res>
    implements $SkotiqError_DeviceNotFoundCopyWith<$Res> {
  _$SkotiqError_DeviceNotFoundCopyWithImpl(this._self, this._then);

  final SkotiqError_DeviceNotFound _self;
  final $Res Function(SkotiqError_DeviceNotFound) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_DeviceNotFound(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_ConnectionFailed extends SkotiqError {
  const SkotiqError_ConnectionFailed({required this.deviceId, required this.reason}): super._();
  

 final  String deviceId;
 final  String reason;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ConnectionFailedCopyWith<SkotiqError_ConnectionFailed> get copyWith => _$SkotiqError_ConnectionFailedCopyWithImpl<SkotiqError_ConnectionFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ConnectionFailed&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,reason);

@override
String toString() {
  return 'SkotiqError.connectionFailed(deviceId: $deviceId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ConnectionFailedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ConnectionFailedCopyWith(SkotiqError_ConnectionFailed value, $Res Function(SkotiqError_ConnectionFailed) _then) = _$SkotiqError_ConnectionFailedCopyWithImpl;
@useResult
$Res call({
 String deviceId, String reason
});




}
/// @nodoc
class _$SkotiqError_ConnectionFailedCopyWithImpl<$Res>
    implements $SkotiqError_ConnectionFailedCopyWith<$Res> {
  _$SkotiqError_ConnectionFailedCopyWithImpl(this._self, this._then);

  final SkotiqError_ConnectionFailed _self;
  final $Res Function(SkotiqError_ConnectionFailed) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? reason = null,}) {
  return _then(SkotiqError_ConnectionFailed(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_AlreadyConnected extends SkotiqError {
  const SkotiqError_AlreadyConnected(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_AlreadyConnectedCopyWith<SkotiqError_AlreadyConnected> get copyWith => _$SkotiqError_AlreadyConnectedCopyWithImpl<SkotiqError_AlreadyConnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_AlreadyConnected&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.alreadyConnected(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_AlreadyConnectedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_AlreadyConnectedCopyWith(SkotiqError_AlreadyConnected value, $Res Function(SkotiqError_AlreadyConnected) _then) = _$SkotiqError_AlreadyConnectedCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_AlreadyConnectedCopyWithImpl<$Res>
    implements $SkotiqError_AlreadyConnectedCopyWith<$Res> {
  _$SkotiqError_AlreadyConnectedCopyWithImpl(this._self, this._then);

  final SkotiqError_AlreadyConnected _self;
  final $Res Function(SkotiqError_AlreadyConnected) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_AlreadyConnected(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_NotConnected extends SkotiqError {
  const SkotiqError_NotConnected(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_NotConnectedCopyWith<SkotiqError_NotConnected> get copyWith => _$SkotiqError_NotConnectedCopyWithImpl<SkotiqError_NotConnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_NotConnected&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.notConnected(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_NotConnectedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_NotConnectedCopyWith(SkotiqError_NotConnected value, $Res Function(SkotiqError_NotConnected) _then) = _$SkotiqError_NotConnectedCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_NotConnectedCopyWithImpl<$Res>
    implements $SkotiqError_NotConnectedCopyWith<$Res> {
  _$SkotiqError_NotConnectedCopyWithImpl(this._self, this._then);

  final SkotiqError_NotConnected _self;
  final $Res Function(SkotiqError_NotConnected) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_NotConnected(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_DeviceDisconnected extends SkotiqError {
  const SkotiqError_DeviceDisconnected({required this.deviceId, required this.reason}): super._();
  

 final  String deviceId;
 final  String reason;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_DeviceDisconnectedCopyWith<SkotiqError_DeviceDisconnected> get copyWith => _$SkotiqError_DeviceDisconnectedCopyWithImpl<SkotiqError_DeviceDisconnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_DeviceDisconnected&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,reason);

@override
String toString() {
  return 'SkotiqError.deviceDisconnected(deviceId: $deviceId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_DeviceDisconnectedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_DeviceDisconnectedCopyWith(SkotiqError_DeviceDisconnected value, $Res Function(SkotiqError_DeviceDisconnected) _then) = _$SkotiqError_DeviceDisconnectedCopyWithImpl;
@useResult
$Res call({
 String deviceId, String reason
});




}
/// @nodoc
class _$SkotiqError_DeviceDisconnectedCopyWithImpl<$Res>
    implements $SkotiqError_DeviceDisconnectedCopyWith<$Res> {
  _$SkotiqError_DeviceDisconnectedCopyWithImpl(this._self, this._then);

  final SkotiqError_DeviceDisconnected _self;
  final $Res Function(SkotiqError_DeviceDisconnected) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? reason = null,}) {
  return _then(SkotiqError_DeviceDisconnected(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_HardwareError extends SkotiqError {
  const SkotiqError_HardwareError({required this.deviceId, required this.message, this.errorCode}): super._();
  

 final  String deviceId;
 final  String message;
/// Optional vendor-specific error code
 final  int? errorCode;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_HardwareErrorCopyWith<SkotiqError_HardwareError> get copyWith => _$SkotiqError_HardwareErrorCopyWithImpl<SkotiqError_HardwareError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_HardwareError&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.message, message) || other.message == message)&&(identical(other.errorCode, errorCode) || other.errorCode == errorCode));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,message,errorCode);

@override
String toString() {
  return 'SkotiqError.hardwareError(deviceId: $deviceId, message: $message, errorCode: $errorCode)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_HardwareErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_HardwareErrorCopyWith(SkotiqError_HardwareError value, $Res Function(SkotiqError_HardwareError) _then) = _$SkotiqError_HardwareErrorCopyWithImpl;
@useResult
$Res call({
 String deviceId, String message, int? errorCode
});




}
/// @nodoc
class _$SkotiqError_HardwareErrorCopyWithImpl<$Res>
    implements $SkotiqError_HardwareErrorCopyWith<$Res> {
  _$SkotiqError_HardwareErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_HardwareError _self;
  final $Res Function(SkotiqError_HardwareError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? message = null,Object? errorCode = freezed,}) {
  return _then(SkotiqError_HardwareError(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,errorCode: freezed == errorCode ? _self.errorCode : errorCode // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc


class SkotiqError_CommunicationError extends SkotiqError {
  const SkotiqError_CommunicationError({required this.deviceId, required this.message}): super._();
  

 final  String deviceId;
 final  String message;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_CommunicationErrorCopyWith<SkotiqError_CommunicationError> get copyWith => _$SkotiqError_CommunicationErrorCopyWithImpl<SkotiqError_CommunicationError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_CommunicationError&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,message);

@override
String toString() {
  return 'SkotiqError.communicationError(deviceId: $deviceId, message: $message)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_CommunicationErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_CommunicationErrorCopyWith(SkotiqError_CommunicationError value, $Res Function(SkotiqError_CommunicationError) _then) = _$SkotiqError_CommunicationErrorCopyWithImpl;
@useResult
$Res call({
 String deviceId, String message
});




}
/// @nodoc
class _$SkotiqError_CommunicationErrorCopyWithImpl<$Res>
    implements $SkotiqError_CommunicationErrorCopyWith<$Res> {
  _$SkotiqError_CommunicationErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_CommunicationError _self;
  final $Res Function(SkotiqError_CommunicationError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? message = null,}) {
  return _then(SkotiqError_CommunicationError(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_Timeout extends SkotiqError {
  const SkotiqError_Timeout(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_TimeoutCopyWith<SkotiqError_Timeout> get copyWith => _$SkotiqError_TimeoutCopyWithImpl<SkotiqError_Timeout>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_Timeout&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.timeout(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_TimeoutCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_TimeoutCopyWith(SkotiqError_Timeout value, $Res Function(SkotiqError_Timeout) _then) = _$SkotiqError_TimeoutCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_TimeoutCopyWithImpl<$Res>
    implements $SkotiqError_TimeoutCopyWith<$Res> {
  _$SkotiqError_TimeoutCopyWithImpl(this._self, this._then);

  final SkotiqError_Timeout _self;
  final $Res Function(SkotiqError_Timeout) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_Timeout(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_DeviceTimeout extends SkotiqError {
  const SkotiqError_DeviceTimeout({required this.deviceId, required this.operation, required this.timeoutSecs}): super._();
  

 final  String deviceId;
 final  String operation;
 final  double timeoutSecs;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_DeviceTimeoutCopyWith<SkotiqError_DeviceTimeout> get copyWith => _$SkotiqError_DeviceTimeoutCopyWithImpl<SkotiqError_DeviceTimeout>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_DeviceTimeout&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.timeoutSecs, timeoutSecs) || other.timeoutSecs == timeoutSecs));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,operation,timeoutSecs);

@override
String toString() {
  return 'SkotiqError.deviceTimeout(deviceId: $deviceId, operation: $operation, timeoutSecs: $timeoutSecs)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_DeviceTimeoutCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_DeviceTimeoutCopyWith(SkotiqError_DeviceTimeout value, $Res Function(SkotiqError_DeviceTimeout) _then) = _$SkotiqError_DeviceTimeoutCopyWithImpl;
@useResult
$Res call({
 String deviceId, String operation, double timeoutSecs
});




}
/// @nodoc
class _$SkotiqError_DeviceTimeoutCopyWithImpl<$Res>
    implements $SkotiqError_DeviceTimeoutCopyWith<$Res> {
  _$SkotiqError_DeviceTimeoutCopyWithImpl(this._self, this._then);

  final SkotiqError_DeviceTimeout _self;
  final $Res Function(SkotiqError_DeviceTimeout) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? operation = null,Object? timeoutSecs = null,}) {
  return _then(SkotiqError_DeviceTimeout(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,timeoutSecs: null == timeoutSecs ? _self.timeoutSecs : timeoutSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class SkotiqError_ConnectionTimeout extends SkotiqError {
  const SkotiqError_ConnectionTimeout({required this.deviceId, required this.timeoutSecs}): super._();
  

 final  String deviceId;
 final  double timeoutSecs;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ConnectionTimeoutCopyWith<SkotiqError_ConnectionTimeout> get copyWith => _$SkotiqError_ConnectionTimeoutCopyWithImpl<SkotiqError_ConnectionTimeout>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ConnectionTimeout&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.timeoutSecs, timeoutSecs) || other.timeoutSecs == timeoutSecs));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,timeoutSecs);

@override
String toString() {
  return 'SkotiqError.connectionTimeout(deviceId: $deviceId, timeoutSecs: $timeoutSecs)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ConnectionTimeoutCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ConnectionTimeoutCopyWith(SkotiqError_ConnectionTimeout value, $Res Function(SkotiqError_ConnectionTimeout) _then) = _$SkotiqError_ConnectionTimeoutCopyWithImpl;
@useResult
$Res call({
 String deviceId, double timeoutSecs
});




}
/// @nodoc
class _$SkotiqError_ConnectionTimeoutCopyWithImpl<$Res>
    implements $SkotiqError_ConnectionTimeoutCopyWith<$Res> {
  _$SkotiqError_ConnectionTimeoutCopyWithImpl(this._self, this._then);

  final SkotiqError_ConnectionTimeout _self;
  final $Res Function(SkotiqError_ConnectionTimeout) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? timeoutSecs = null,}) {
  return _then(SkotiqError_ConnectionTimeout(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,timeoutSecs: null == timeoutSecs ? _self.timeoutSecs : timeoutSecs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class SkotiqError_InvalidParameter extends SkotiqError {
  const SkotiqError_InvalidParameter(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_InvalidParameterCopyWith<SkotiqError_InvalidParameter> get copyWith => _$SkotiqError_InvalidParameterCopyWithImpl<SkotiqError_InvalidParameter>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_InvalidParameter&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.invalidParameter(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_InvalidParameterCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_InvalidParameterCopyWith(SkotiqError_InvalidParameter value, $Res Function(SkotiqError_InvalidParameter) _then) = _$SkotiqError_InvalidParameterCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_InvalidParameterCopyWithImpl<$Res>
    implements $SkotiqError_InvalidParameterCopyWith<$Res> {
  _$SkotiqError_InvalidParameterCopyWithImpl(this._self, this._then);

  final SkotiqError_InvalidParameter _self;
  final $Res Function(SkotiqError_InvalidParameter) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_InvalidParameter(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_InvalidInput extends SkotiqError {
  const SkotiqError_InvalidInput(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_InvalidInputCopyWith<SkotiqError_InvalidInput> get copyWith => _$SkotiqError_InvalidInputCopyWithImpl<SkotiqError_InvalidInput>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_InvalidInput&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.invalidInput(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_InvalidInputCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_InvalidInputCopyWith(SkotiqError_InvalidInput value, $Res Function(SkotiqError_InvalidInput) _then) = _$SkotiqError_InvalidInputCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_InvalidInputCopyWithImpl<$Res>
    implements $SkotiqError_InvalidInputCopyWith<$Res> {
  _$SkotiqError_InvalidInputCopyWithImpl(this._self, this._then);

  final SkotiqError_InvalidInput _self;
  final $Res Function(SkotiqError_InvalidInput) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_InvalidInput(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_InvalidDeviceId extends SkotiqError {
  const SkotiqError_InvalidDeviceId({required this.deviceId, required this.reason}): super._();
  

 final  String deviceId;
 final  String reason;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_InvalidDeviceIdCopyWith<SkotiqError_InvalidDeviceId> get copyWith => _$SkotiqError_InvalidDeviceIdCopyWithImpl<SkotiqError_InvalidDeviceId>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_InvalidDeviceId&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,reason);

@override
String toString() {
  return 'SkotiqError.invalidDeviceId(deviceId: $deviceId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_InvalidDeviceIdCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_InvalidDeviceIdCopyWith(SkotiqError_InvalidDeviceId value, $Res Function(SkotiqError_InvalidDeviceId) _then) = _$SkotiqError_InvalidDeviceIdCopyWithImpl;
@useResult
$Res call({
 String deviceId, String reason
});




}
/// @nodoc
class _$SkotiqError_InvalidDeviceIdCopyWithImpl<$Res>
    implements $SkotiqError_InvalidDeviceIdCopyWith<$Res> {
  _$SkotiqError_InvalidDeviceIdCopyWithImpl(this._self, this._then);

  final SkotiqError_InvalidDeviceId _self;
  final $Res Function(SkotiqError_InvalidDeviceId) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? reason = null,}) {
  return _then(SkotiqError_InvalidDeviceId(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_ParameterOutOfRange extends SkotiqError {
  const SkotiqError_ParameterOutOfRange({required this.paramName, required this.value, required this.min, required this.max}): super._();
  

 final  String paramName;
 final  String value;
 final  String min;
 final  String max;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ParameterOutOfRangeCopyWith<SkotiqError_ParameterOutOfRange> get copyWith => _$SkotiqError_ParameterOutOfRangeCopyWithImpl<SkotiqError_ParameterOutOfRange>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ParameterOutOfRange&&(identical(other.paramName, paramName) || other.paramName == paramName)&&(identical(other.value, value) || other.value == value)&&(identical(other.min, min) || other.min == min)&&(identical(other.max, max) || other.max == max));
}


@override
int get hashCode => Object.hash(runtimeType,paramName,value,min,max);

@override
String toString() {
  return 'SkotiqError.parameterOutOfRange(paramName: $paramName, value: $value, min: $min, max: $max)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ParameterOutOfRangeCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ParameterOutOfRangeCopyWith(SkotiqError_ParameterOutOfRange value, $Res Function(SkotiqError_ParameterOutOfRange) _then) = _$SkotiqError_ParameterOutOfRangeCopyWithImpl;
@useResult
$Res call({
 String paramName, String value, String min, String max
});




}
/// @nodoc
class _$SkotiqError_ParameterOutOfRangeCopyWithImpl<$Res>
    implements $SkotiqError_ParameterOutOfRangeCopyWith<$Res> {
  _$SkotiqError_ParameterOutOfRangeCopyWithImpl(this._self, this._then);

  final SkotiqError_ParameterOutOfRange _self;
  final $Res Function(SkotiqError_ParameterOutOfRange) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? paramName = null,Object? value = null,Object? min = null,Object? max = null,}) {
  return _then(SkotiqError_ParameterOutOfRange(
paramName: null == paramName ? _self.paramName : paramName // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,min: null == min ? _self.min : min // ignore: cast_nullable_to_non_nullable
as String,max: null == max ? _self.max : max // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_OperationFailed extends SkotiqError {
  const SkotiqError_OperationFailed(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_OperationFailedCopyWith<SkotiqError_OperationFailed> get copyWith => _$SkotiqError_OperationFailedCopyWithImpl<SkotiqError_OperationFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_OperationFailed&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.operationFailed(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_OperationFailedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_OperationFailedCopyWith(SkotiqError_OperationFailed value, $Res Function(SkotiqError_OperationFailed) _then) = _$SkotiqError_OperationFailedCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_OperationFailedCopyWithImpl<$Res>
    implements $SkotiqError_OperationFailedCopyWith<$Res> {
  _$SkotiqError_OperationFailedCopyWithImpl(this._self, this._then);

  final SkotiqError_OperationFailed _self;
  final $Res Function(SkotiqError_OperationFailed) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_OperationFailed(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_NotSupported extends SkotiqError {
  const SkotiqError_NotSupported({required this.deviceId, required this.operation}): super._();
  

 final  String deviceId;
 final  String operation;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_NotSupportedCopyWith<SkotiqError_NotSupported> get copyWith => _$SkotiqError_NotSupportedCopyWithImpl<SkotiqError_NotSupported>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_NotSupported&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.operation, operation) || other.operation == operation));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,operation);

@override
String toString() {
  return 'SkotiqError.notSupported(deviceId: $deviceId, operation: $operation)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_NotSupportedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_NotSupportedCopyWith(SkotiqError_NotSupported value, $Res Function(SkotiqError_NotSupported) _then) = _$SkotiqError_NotSupportedCopyWithImpl;
@useResult
$Res call({
 String deviceId, String operation
});




}
/// @nodoc
class _$SkotiqError_NotSupportedCopyWithImpl<$Res>
    implements $SkotiqError_NotSupportedCopyWith<$Res> {
  _$SkotiqError_NotSupportedCopyWithImpl(this._self, this._then);

  final SkotiqError_NotSupported _self;
  final $Res Function(SkotiqError_NotSupported) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? operation = null,}) {
  return _then(SkotiqError_NotSupported(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_DeviceBusy extends SkotiqError {
  const SkotiqError_DeviceBusy({required this.deviceId, required this.currentOperation}): super._();
  

 final  String deviceId;
 final  String currentOperation;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_DeviceBusyCopyWith<SkotiqError_DeviceBusy> get copyWith => _$SkotiqError_DeviceBusyCopyWithImpl<SkotiqError_DeviceBusy>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_DeviceBusy&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.currentOperation, currentOperation) || other.currentOperation == currentOperation));
}


@override
int get hashCode => Object.hash(runtimeType,deviceId,currentOperation);

@override
String toString() {
  return 'SkotiqError.deviceBusy(deviceId: $deviceId, currentOperation: $currentOperation)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_DeviceBusyCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_DeviceBusyCopyWith(SkotiqError_DeviceBusy value, $Res Function(SkotiqError_DeviceBusy) _then) = _$SkotiqError_DeviceBusyCopyWithImpl;
@useResult
$Res call({
 String deviceId, String currentOperation
});




}
/// @nodoc
class _$SkotiqError_DeviceBusyCopyWithImpl<$Res>
    implements $SkotiqError_DeviceBusyCopyWith<$Res> {
  _$SkotiqError_DeviceBusyCopyWithImpl(this._self, this._then);

  final SkotiqError_DeviceBusy _self;
  final $Res Function(SkotiqError_DeviceBusy) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? currentOperation = null,}) {
  return _then(SkotiqError_DeviceBusy(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,currentOperation: null == currentOperation ? _self.currentOperation : currentOperation // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_ImageError extends SkotiqError {
  const SkotiqError_ImageError(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ImageErrorCopyWith<SkotiqError_ImageError> get copyWith => _$SkotiqError_ImageErrorCopyWithImpl<SkotiqError_ImageError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ImageError&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.imageError(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ImageErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ImageErrorCopyWith(SkotiqError_ImageError value, $Res Function(SkotiqError_ImageError) _then) = _$SkotiqError_ImageErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_ImageErrorCopyWithImpl<$Res>
    implements $SkotiqError_ImageErrorCopyWith<$Res> {
  _$SkotiqError_ImageErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_ImageError _self;
  final $Res Function(SkotiqError_ImageError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_ImageError(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_CameraError extends SkotiqError {
  const SkotiqError_CameraError(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_CameraErrorCopyWith<SkotiqError_CameraError> get copyWith => _$SkotiqError_CameraErrorCopyWithImpl<SkotiqError_CameraError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_CameraError&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.cameraError(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_CameraErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_CameraErrorCopyWith(SkotiqError_CameraError value, $Res Function(SkotiqError_CameraError) _then) = _$SkotiqError_CameraErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_CameraErrorCopyWithImpl<$Res>
    implements $SkotiqError_CameraErrorCopyWith<$Res> {
  _$SkotiqError_CameraErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_CameraError _self;
  final $Res Function(SkotiqError_CameraError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_CameraError(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_NoImageAvailable extends SkotiqError {
  const SkotiqError_NoImageAvailable(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_NoImageAvailable);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SkotiqError.noImageAvailable()';
}


}




/// @nodoc


class SkotiqError_ExposureCancelled extends SkotiqError {
  const SkotiqError_ExposureCancelled(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ExposureCancelled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SkotiqError.exposureCancelled()';
}


}




/// @nodoc


class SkotiqError_ExposureFailed extends SkotiqError {
  const SkotiqError_ExposureFailed({required this.cameraId, required this.reason}): super._();
  

 final  String cameraId;
 final  String reason;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ExposureFailedCopyWith<SkotiqError_ExposureFailed> get copyWith => _$SkotiqError_ExposureFailedCopyWithImpl<SkotiqError_ExposureFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ExposureFailed&&(identical(other.cameraId, cameraId) || other.cameraId == cameraId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,cameraId,reason);

@override
String toString() {
  return 'SkotiqError.exposureFailed(cameraId: $cameraId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ExposureFailedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ExposureFailedCopyWith(SkotiqError_ExposureFailed value, $Res Function(SkotiqError_ExposureFailed) _then) = _$SkotiqError_ExposureFailedCopyWithImpl;
@useResult
$Res call({
 String cameraId, String reason
});




}
/// @nodoc
class _$SkotiqError_ExposureFailedCopyWithImpl<$Res>
    implements $SkotiqError_ExposureFailedCopyWith<$Res> {
  _$SkotiqError_ExposureFailedCopyWithImpl(this._self, this._then);

  final SkotiqError_ExposureFailed _self;
  final $Res Function(SkotiqError_ExposureFailed) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? cameraId = null,Object? reason = null,}) {
  return _then(SkotiqError_ExposureFailed(
cameraId: null == cameraId ? _self.cameraId : cameraId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_DownloadFailed extends SkotiqError {
  const SkotiqError_DownloadFailed({required this.cameraId, required this.reason}): super._();
  

 final  String cameraId;
 final  String reason;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_DownloadFailedCopyWith<SkotiqError_DownloadFailed> get copyWith => _$SkotiqError_DownloadFailedCopyWithImpl<SkotiqError_DownloadFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_DownloadFailed&&(identical(other.cameraId, cameraId) || other.cameraId == cameraId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,cameraId,reason);

@override
String toString() {
  return 'SkotiqError.downloadFailed(cameraId: $cameraId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_DownloadFailedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_DownloadFailedCopyWith(SkotiqError_DownloadFailed value, $Res Function(SkotiqError_DownloadFailed) _then) = _$SkotiqError_DownloadFailedCopyWithImpl;
@useResult
$Res call({
 String cameraId, String reason
});




}
/// @nodoc
class _$SkotiqError_DownloadFailedCopyWithImpl<$Res>
    implements $SkotiqError_DownloadFailedCopyWith<$Res> {
  _$SkotiqError_DownloadFailedCopyWithImpl(this._self, this._then);

  final SkotiqError_DownloadFailed _self;
  final $Res Function(SkotiqError_DownloadFailed) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? cameraId = null,Object? reason = null,}) {
  return _then(SkotiqError_DownloadFailed(
cameraId: null == cameraId ? _self.cameraId : cameraId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_IoError extends SkotiqError {
  const SkotiqError_IoError(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_IoErrorCopyWith<SkotiqError_IoError> get copyWith => _$SkotiqError_IoErrorCopyWithImpl<SkotiqError_IoError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_IoError&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.ioError(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_IoErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_IoErrorCopyWith(SkotiqError_IoError value, $Res Function(SkotiqError_IoError) _then) = _$SkotiqError_IoErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_IoErrorCopyWithImpl<$Res>
    implements $SkotiqError_IoErrorCopyWith<$Res> {
  _$SkotiqError_IoErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_IoError _self;
  final $Res Function(SkotiqError_IoError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_IoError(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_SerializationError extends SkotiqError {
  const SkotiqError_SerializationError(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_SerializationErrorCopyWith<SkotiqError_SerializationError> get copyWith => _$SkotiqError_SerializationErrorCopyWithImpl<SkotiqError_SerializationError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_SerializationError&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.serializationError(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_SerializationErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_SerializationErrorCopyWith(SkotiqError_SerializationError value, $Res Function(SkotiqError_SerializationError) _then) = _$SkotiqError_SerializationErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_SerializationErrorCopyWithImpl<$Res>
    implements $SkotiqError_SerializationErrorCopyWith<$Res> {
  _$SkotiqError_SerializationErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_SerializationError _self;
  final $Res Function(SkotiqError_SerializationError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_SerializationError(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_PlateSolveError extends SkotiqError {
  const SkotiqError_PlateSolveError(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_PlateSolveErrorCopyWith<SkotiqError_PlateSolveError> get copyWith => _$SkotiqError_PlateSolveErrorCopyWithImpl<SkotiqError_PlateSolveError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_PlateSolveError&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.plateSolveError(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_PlateSolveErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_PlateSolveErrorCopyWith(SkotiqError_PlateSolveError value, $Res Function(SkotiqError_PlateSolveError) _then) = _$SkotiqError_PlateSolveErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_PlateSolveErrorCopyWithImpl<$Res>
    implements $SkotiqError_PlateSolveErrorCopyWith<$Res> {
  _$SkotiqError_PlateSolveErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_PlateSolveError _self;
  final $Res Function(SkotiqError_PlateSolveError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_PlateSolveError(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_SequenceError extends SkotiqError {
  const SkotiqError_SequenceError(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_SequenceErrorCopyWith<SkotiqError_SequenceError> get copyWith => _$SkotiqError_SequenceErrorCopyWithImpl<SkotiqError_SequenceError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_SequenceError&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.sequenceError(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_SequenceErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_SequenceErrorCopyWith(SkotiqError_SequenceError value, $Res Function(SkotiqError_SequenceError) _then) = _$SkotiqError_SequenceErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_SequenceErrorCopyWithImpl<$Res>
    implements $SkotiqError_SequenceErrorCopyWith<$Res> {
  _$SkotiqError_SequenceErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_SequenceError _self;
  final $Res Function(SkotiqError_SequenceError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_SequenceError(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_AscomError extends SkotiqError {
  const SkotiqError_AscomError({required this.progId, required this.message, required this.errorCode}): super._();
  

 final  String progId;
 final  String message;
 final  int errorCode;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_AscomErrorCopyWith<SkotiqError_AscomError> get copyWith => _$SkotiqError_AscomErrorCopyWithImpl<SkotiqError_AscomError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_AscomError&&(identical(other.progId, progId) || other.progId == progId)&&(identical(other.message, message) || other.message == message)&&(identical(other.errorCode, errorCode) || other.errorCode == errorCode));
}


@override
int get hashCode => Object.hash(runtimeType,progId,message,errorCode);

@override
String toString() {
  return 'SkotiqError.ascomError(progId: $progId, message: $message, errorCode: $errorCode)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_AscomErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_AscomErrorCopyWith(SkotiqError_AscomError value, $Res Function(SkotiqError_AscomError) _then) = _$SkotiqError_AscomErrorCopyWithImpl;
@useResult
$Res call({
 String progId, String message, int errorCode
});




}
/// @nodoc
class _$SkotiqError_AscomErrorCopyWithImpl<$Res>
    implements $SkotiqError_AscomErrorCopyWith<$Res> {
  _$SkotiqError_AscomErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_AscomError _self;
  final $Res Function(SkotiqError_AscomError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? progId = null,Object? message = null,Object? errorCode = null,}) {
  return _then(SkotiqError_AscomError(
progId: null == progId ? _self.progId : progId // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,errorCode: null == errorCode ? _self.errorCode : errorCode // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SkotiqError_AlpacaError extends SkotiqError {
  const SkotiqError_AlpacaError({required this.baseUrl, required this.deviceNumber, required this.message, required this.errorCode}): super._();
  

 final  String baseUrl;
 final  int deviceNumber;
 final  String message;
 final  int errorCode;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_AlpacaErrorCopyWith<SkotiqError_AlpacaError> get copyWith => _$SkotiqError_AlpacaErrorCopyWithImpl<SkotiqError_AlpacaError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_AlpacaError&&(identical(other.baseUrl, baseUrl) || other.baseUrl == baseUrl)&&(identical(other.deviceNumber, deviceNumber) || other.deviceNumber == deviceNumber)&&(identical(other.message, message) || other.message == message)&&(identical(other.errorCode, errorCode) || other.errorCode == errorCode));
}


@override
int get hashCode => Object.hash(runtimeType,baseUrl,deviceNumber,message,errorCode);

@override
String toString() {
  return 'SkotiqError.alpacaError(baseUrl: $baseUrl, deviceNumber: $deviceNumber, message: $message, errorCode: $errorCode)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_AlpacaErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_AlpacaErrorCopyWith(SkotiqError_AlpacaError value, $Res Function(SkotiqError_AlpacaError) _then) = _$SkotiqError_AlpacaErrorCopyWithImpl;
@useResult
$Res call({
 String baseUrl, int deviceNumber, String message, int errorCode
});




}
/// @nodoc
class _$SkotiqError_AlpacaErrorCopyWithImpl<$Res>
    implements $SkotiqError_AlpacaErrorCopyWith<$Res> {
  _$SkotiqError_AlpacaErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_AlpacaError _self;
  final $Res Function(SkotiqError_AlpacaError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? baseUrl = null,Object? deviceNumber = null,Object? message = null,Object? errorCode = null,}) {
  return _then(SkotiqError_AlpacaError(
baseUrl: null == baseUrl ? _self.baseUrl : baseUrl // ignore: cast_nullable_to_non_nullable
as String,deviceNumber: null == deviceNumber ? _self.deviceNumber : deviceNumber // ignore: cast_nullable_to_non_nullable
as int,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,errorCode: null == errorCode ? _self.errorCode : errorCode // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SkotiqError_IndiError extends SkotiqError {
  const SkotiqError_IndiError({required this.server, required this.port, required this.deviceName, required this.message}): super._();
  

 final  String server;
 final  int port;
 final  String deviceName;
 final  String message;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_IndiErrorCopyWith<SkotiqError_IndiError> get copyWith => _$SkotiqError_IndiErrorCopyWithImpl<SkotiqError_IndiError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_IndiError&&(identical(other.server, server) || other.server == server)&&(identical(other.port, port) || other.port == port)&&(identical(other.deviceName, deviceName) || other.deviceName == deviceName)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,server,port,deviceName,message);

@override
String toString() {
  return 'SkotiqError.indiError(server: $server, port: $port, deviceName: $deviceName, message: $message)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_IndiErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_IndiErrorCopyWith(SkotiqError_IndiError value, $Res Function(SkotiqError_IndiError) _then) = _$SkotiqError_IndiErrorCopyWithImpl;
@useResult
$Res call({
 String server, int port, String deviceName, String message
});




}
/// @nodoc
class _$SkotiqError_IndiErrorCopyWithImpl<$Res>
    implements $SkotiqError_IndiErrorCopyWith<$Res> {
  _$SkotiqError_IndiErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_IndiError _self;
  final $Res Function(SkotiqError_IndiError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? server = null,Object? port = null,Object? deviceName = null,Object? message = null,}) {
  return _then(SkotiqError_IndiError(
server: null == server ? _self.server : server // ignore: cast_nullable_to_non_nullable
as String,port: null == port ? _self.port : port // ignore: cast_nullable_to_non_nullable
as int,deviceName: null == deviceName ? _self.deviceName : deviceName // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_NativeError extends SkotiqError {
  const SkotiqError_NativeError({required this.vendor, required this.message, required this.errorCode}): super._();
  

 final  String vendor;
 final  String message;
 final  int errorCode;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_NativeErrorCopyWith<SkotiqError_NativeError> get copyWith => _$SkotiqError_NativeErrorCopyWithImpl<SkotiqError_NativeError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_NativeError&&(identical(other.vendor, vendor) || other.vendor == vendor)&&(identical(other.message, message) || other.message == message)&&(identical(other.errorCode, errorCode) || other.errorCode == errorCode));
}


@override
int get hashCode => Object.hash(runtimeType,vendor,message,errorCode);

@override
String toString() {
  return 'SkotiqError.nativeError(vendor: $vendor, message: $message, errorCode: $errorCode)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_NativeErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_NativeErrorCopyWith(SkotiqError_NativeError value, $Res Function(SkotiqError_NativeError) _then) = _$SkotiqError_NativeErrorCopyWithImpl;
@useResult
$Res call({
 String vendor, String message, int errorCode
});




}
/// @nodoc
class _$SkotiqError_NativeErrorCopyWithImpl<$Res>
    implements $SkotiqError_NativeErrorCopyWith<$Res> {
  _$SkotiqError_NativeErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_NativeError _self;
  final $Res Function(SkotiqError_NativeError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? vendor = null,Object? message = null,Object? errorCode = null,}) {
  return _then(SkotiqError_NativeError(
vendor: null == vendor ? _self.vendor : vendor // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,errorCode: null == errorCode ? _self.errorCode : errorCode // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SkotiqError_ComError extends SkotiqError {
  const SkotiqError_ComError({required this.message, required this.hresult}): super._();
  

 final  String message;
 final  int hresult;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ComErrorCopyWith<SkotiqError_ComError> get copyWith => _$SkotiqError_ComErrorCopyWithImpl<SkotiqError_ComError>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ComError&&(identical(other.message, message) || other.message == message)&&(identical(other.hresult, hresult) || other.hresult == hresult));
}


@override
int get hashCode => Object.hash(runtimeType,message,hresult);

@override
String toString() {
  return 'SkotiqError.comError(message: $message, hresult: $hresult)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ComErrorCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ComErrorCopyWith(SkotiqError_ComError value, $Res Function(SkotiqError_ComError) _then) = _$SkotiqError_ComErrorCopyWithImpl;
@useResult
$Res call({
 String message, int hresult
});




}
/// @nodoc
class _$SkotiqError_ComErrorCopyWithImpl<$Res>
    implements $SkotiqError_ComErrorCopyWith<$Res> {
  _$SkotiqError_ComErrorCopyWithImpl(this._self, this._then);

  final SkotiqError_ComError _self;
  final $Res Function(SkotiqError_ComError) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,Object? hresult = null,}) {
  return _then(SkotiqError_ComError(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,hresult: null == hresult ? _self.hresult : hresult // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class SkotiqError_Internal extends SkotiqError {
  const SkotiqError_Internal(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_InternalCopyWith<SkotiqError_Internal> get copyWith => _$SkotiqError_InternalCopyWithImpl<SkotiqError_Internal>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_Internal&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.internal(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_InternalCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_InternalCopyWith(SkotiqError_Internal value, $Res Function(SkotiqError_Internal) _then) = _$SkotiqError_InternalCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_InternalCopyWithImpl<$Res>
    implements $SkotiqError_InternalCopyWith<$Res> {
  _$SkotiqError_InternalCopyWithImpl(this._self, this._then);

  final SkotiqError_Internal _self;
  final $Res Function(SkotiqError_Internal) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_Internal(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_Cancelled extends SkotiqError {
  const SkotiqError_Cancelled(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_Cancelled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SkotiqError.cancelled()';
}


}




/// @nodoc


class SkotiqError_RuntimeInitFailed extends SkotiqError {
  const SkotiqError_RuntimeInitFailed(this.field0): super._();
  

 final  String field0;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_RuntimeInitFailedCopyWith<SkotiqError_RuntimeInitFailed> get copyWith => _$SkotiqError_RuntimeInitFailedCopyWithImpl<SkotiqError_RuntimeInitFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_RuntimeInitFailed&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SkotiqError.runtimeInitFailed(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_RuntimeInitFailedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_RuntimeInitFailedCopyWith(SkotiqError_RuntimeInitFailed value, $Res Function(SkotiqError_RuntimeInitFailed) _then) = _$SkotiqError_RuntimeInitFailedCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$SkotiqError_RuntimeInitFailedCopyWithImpl<$Res>
    implements $SkotiqError_RuntimeInitFailedCopyWith<$Res> {
  _$SkotiqError_RuntimeInitFailedCopyWithImpl(this._self, this._then);

  final SkotiqError_RuntimeInitFailed _self;
  final $Res Function(SkotiqError_RuntimeInitFailed) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SkotiqError_RuntimeInitFailed(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SkotiqError_ResourceExhausted extends SkotiqError {
  const SkotiqError_ResourceExhausted({required this.resource, required this.message}): super._();
  

 final  String resource;
 final  String message;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SkotiqError_ResourceExhaustedCopyWith<SkotiqError_ResourceExhausted> get copyWith => _$SkotiqError_ResourceExhaustedCopyWithImpl<SkotiqError_ResourceExhausted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SkotiqError_ResourceExhausted&&(identical(other.resource, resource) || other.resource == resource)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,resource,message);

@override
String toString() {
  return 'SkotiqError.resourceExhausted(resource: $resource, message: $message)';
}


}

/// @nodoc
abstract mixin class $SkotiqError_ResourceExhaustedCopyWith<$Res> implements $SkotiqErrorCopyWith<$Res> {
  factory $SkotiqError_ResourceExhaustedCopyWith(SkotiqError_ResourceExhausted value, $Res Function(SkotiqError_ResourceExhausted) _then) = _$SkotiqError_ResourceExhaustedCopyWithImpl;
@useResult
$Res call({
 String resource, String message
});




}
/// @nodoc
class _$SkotiqError_ResourceExhaustedCopyWithImpl<$Res>
    implements $SkotiqError_ResourceExhaustedCopyWith<$Res> {
  _$SkotiqError_ResourceExhaustedCopyWithImpl(this._self, this._then);

  final SkotiqError_ResourceExhausted _self;
  final $Res Function(SkotiqError_ResourceExhausted) _then;

/// Create a copy of SkotiqError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? resource = null,Object? message = null,}) {
  return _then(SkotiqError_ResourceExhausted(
resource: null == resource ? _self.resource : resource // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
