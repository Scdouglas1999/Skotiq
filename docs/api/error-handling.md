# Error Handling Reference

Complete guide to error handling in the Skotiq API.

## SkotiqError

All API methods may throw `SkotiqError` exceptions. This is a sealed class with multiple error variants.

### Error Types

#### DeviceNotFound

Device not found.

```dart
SkotiqError.deviceNotFound('Device camera-1 not found')
```

#### ConnectionFailed

Device connection failed.

```dart
SkotiqError.connectionFailed('Failed to connect: timeout')
```

#### AlreadyConnected

Device already connected.

```dart
SkotiqError.alreadyConnected('Device camera-1 is already connected')
```

#### NotConnected

Device not connected.

```dart
SkotiqError.notConnected('Device camera-1 is not connected')
```

#### Timeout

Operation timed out.

```dart
SkotiqError.timeout('Exposure timed out after 60 seconds')
```

#### InvalidParameter

Invalid parameter value.

```dart
SkotiqError.invalidParameter('Exposure time must be positive')
```

#### InvalidInput

Invalid input data.

```dart
SkotiqError.invalidInput('Invalid coordinates: RA must be 0-24 hours')
```

#### InvalidDeviceId

Invalid device identifier.

```dart
SkotiqError.invalidDeviceId('Invalid device ID format')
```

#### OperationFailed

Operation failed.

```dart
SkotiqError.operationFailed('Slew failed: mount error')
```

#### ImageError

Image processing error.

```dart
SkotiqError.imageError('Failed to decode image data')
```

#### IoError

File I/O error.

```dart
SkotiqError.ioError('Failed to read file: permission denied')
```

#### PlateSolveError

Plate solving error.

```dart
SkotiqError.plateSolveError('Plate solve failed: no stars detected')
```

#### SequenceError

Sequence execution error.

```dart
SkotiqError.sequenceError('Sequence node failed: exposure error')
```

#### NoImageAvailable

No image available.

```dart
SkotiqError.noImageAvailable()
```

#### ExposureCancelled

Exposure was cancelled.

```dart
SkotiqError.exposureCancelled()
```

#### Cancelled

Operation was cancelled.

```dart
SkotiqError.cancelled()
```

#### CameraError

Camera-specific error.

```dart
SkotiqError.cameraError('Camera temperature too high')
```

#### Internal

Internal error.

```dart
SkotiqError.internal('Unexpected error in device driver')
```

## Error Handling Patterns

### Basic Error Handling

```dart
try {
  await backend.connectDevice(DeviceType.camera, 'camera-1');
} on SkotiqError catch (e) {
  print('Error: ${e.toString()}');
}
```

### Specific Error Handling

```dart
try {
  await backend.cameraStartExposure(
    deviceId: 'camera-1',
    exposureTime: 60.0,
    frameType: FrameType.light,
  );
} on SkotiqError catch (e) {
  switch (e) {
    case SkotiqError_NotConnected():
      print('Camera not connected');
      break;
    case SkotiqError_Timeout():
      print('Exposure timed out');
      break;
    case SkotiqError_OperationFailed(field0: final message):
      print('Operation failed: $message');
      break;
    default:
      print('Unknown error: $e');
  }
}
```

### Error Handling with Pattern Matching

```dart
try {
  await backend.mountSlewToCoordinates('mount-1', 5.5, -5.0);
} on SkotiqError catch (e) {
  e.when(
    deviceNotFound: (msg) => showError('Device not found: $msg'),
    connectionFailed: (msg) => showError('Connection failed: $msg'),
    notConnected: (msg) => showError('Not connected: $msg'),
    timeout: (msg) => showError('Timeout: $msg'),
    operationFailed: (msg) => showError('Operation failed: $msg'),
    // ... handle other cases
    orElse: () => showError('Unknown error: $e'),
  );
}
```

### Error Handling in Async Operations

```dart
Future<void> captureImage() async {
  try {
    final image = await backend.cameraGetLastImage('camera-1');
    if (image == null) {
      throw SkotiqError.noImageAvailable();
    }
    // Process image
  } on SkotiqError_NoImageAvailable {
    print('No image available yet');
  } on SkotiqError_NotConnected {
    print('Camera not connected');
  } catch (e) {
    print('Unexpected error: $e');
  }
}
```

### Error Propagation

```dart
Future<void> startSequence() async {
  try {
    await backend.sequencerStart();
  } on SkotiqError catch (e) {
    // Log error
    logger.error('Sequence start failed', error: e);
    // Re-throw or handle
    rethrow;
  }
}
```

## Error Messages

All error types (except parameterless ones) include a message string that provides details about what went wrong.

```dart
try {
  await backend.connectDevice(DeviceType.camera, 'invalid-id');
} on SkotiqError_ConnectionFailed catch (e) {
  print(e.field0); // "Connection failed: Device not found"
}
```

## Error Events

Errors may also be emitted through the event stream:

```dart
backend.eventStream.listen((event) {
  if (event.severity == EventSeverity.error) {
    print('Error event: ${event.eventType}');
    print('Details: ${event.data}');
  }
});
```

## Best Practices

1. **Always handle errors** - Don't let errors propagate unhandled
2. **Provide user feedback** - Show meaningful error messages to users
3. **Log errors** - Log errors for debugging
4. **Retry logic** - Consider retrying transient errors (timeouts, connection failures)
5. **Graceful degradation** - Handle errors gracefully without crashing

## Example: Comprehensive Error Handling

```dart
Future<bool> connectCamera(String deviceId) async {
  try {
    await backend.connectDevice(DeviceType.camera, deviceId);
    return true;
  } on SkotiqError_DeviceNotFound catch (e) {
    showError('Camera not found: ${e.field0}');
    return false;
  } on SkotiqError_ConnectionFailed catch (e) {
    showError('Connection failed: ${e.field0}');
    // Retry logic could go here
    return false;
  } on SkotiqError_AlreadyConnected {
    // Already connected, this is OK
    return true;
  } on SkotiqError catch (e) {
    logger.error('Unexpected error connecting camera', error: e);
    showError('Unexpected error: ${e.toString()}');
    return false;
  } catch (e) {
    logger.error('Non-Skotiq error', error: e);
    showError('System error: ${e.toString()}');
    return false;
  }
}
```

