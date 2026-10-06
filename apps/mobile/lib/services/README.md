# Mobile Services - Background Operation Support

This directory contains production-ready services for background operation, notifications, and power management in the Nightshade mobile app.

## Overview

The mobile services enable the app to:
- Run imaging sequences in the background without interruption
- Display persistent progress notifications during sequences
- Monitor battery levels and automatically protect data
- Keep the CPU awake during active imaging operations
- Notify users of important events (sequence completion, errors, meridian flips)

## Services

### 1. ForegroundService (`foreground_service.dart`)

Android foreground service that keeps the app alive during background imaging operations.

**Key Features:**
- Displays persistent notification with sequence progress
- Updates notification in real-time as sequence progresses
- Prevents Android from killing the app during long exposures
- Automatically stops when sequence completes or fails

**Usage:**
```dart
final service = ImagingForegroundService();
await service.initialize();

// Start service when sequence begins
await service.startService(
  targetName: 'M31',
  totalExposures: 100,
);

// Update progress during sequence
service.updateProgress(
  completedExposures: 50,
  totalExposures: 100,
  currentFilter: 'Ha',
  statusMessage: 'Exposing...',
);

// Stop service when sequence ends
await service.stopService(
  sequenceCompleted: true,
);
```

**Platform Support:** Android only (iOS uses different background modes)

### 2. MobileNotificationService (`notification_service.dart`)

Local notification service for important imaging events.

**Key Features:**
- Multiple notification channels (sequence events, warnings, info)
- Customizable notification settings (enable/disable by type)
- Rich notifications with actions (planned future enhancement)
- Tappable notifications that navigate to relevant screens

**Notification Types:**
- **Sequence Complete**: Shows when imaging sequence finishes successfully
- **Sequence Failed**: Shows when sequence encounters an error
- **Meridian Flip**: Informs user when mount performs meridian flip
- **Low Disk Space**: Warns when storage is running low
- **Low Battery**: Multiple warning levels (20%, 15%, 10%)

**Usage:**
```dart
final service = MobileNotificationService();
await service.initialize();

// Send completion notification
await service.notifySequenceComplete('M31', 100);

// Send error notification
await service.notifySequenceFailed('M31', 'Mount connection lost');

// Send battery warning
await service.notifyLowBattery(15);
```

**Settings:**
```dart
service.enableSequenceNotifications = true;
service.enableMeridianFlipNotifications = true;
service.enableWarningNotifications = true;
```

**Platform Support:** Android and iOS

### 3. PowerService (`power_service.dart`)

Battery monitoring and wake lock management service.

**Key Features:**
- Acquires CPU wake lock to prevent device sleep during imaging
- Monitors battery level every 30 seconds (configurable)
- Automatic warnings at 20%, 15%, and 10% battery
- Never pauses the run for the phone's own battery: it is no risk to the rig
- Real-time battery level stream for UI updates
- Smart warning system (only warns once per level, resets when charging)

**Battery Warning Levels:**
- **Normal**: >20% battery
- **Low**: 20% battery - first warning
- **VeryLow**: 15% battery - second warning
- **Critical**: 10% battery - last warning; the run keeps running

**Usage:**
```dart
final service = PowerService();
await service.initialize();

// Start imaging session (acquires wake lock + starts monitoring)
await service.startImagingSession();

// Set up callbacks
service.onBatteryLevelChanged = (level) {
  print('Battery: $level%');
};

service.onCriticalBattery = () {
  // Pause sequence automatically
};

// Stop imaging session (releases wake lock + stops monitoring)
await service.stopImagingSession();

// Manual controls
await service.acquireWakeLock();
service.startBatteryMonitoring();
service.stopBatteryMonitoring();
await service.releaseWakeLock();
```

**Settings:**
```dart
service.enableCpuWakeLock = true;  // Keep CPU awake (required)
service.enableScreenWakeLock = false;  // Keep screen on (optional)
service.batteryCheckIntervalSeconds = 30;  // Check frequency
```

**Platform Support:** Android and iOS

### 4. MobileSequenceHooks (`mobile_sequence_hooks.dart`)

Integration layer that connects sequence execution to mobile services.

**Key Features:**
- Automatically starts/stops services based on sequence state
- Listens to sequence progress and updates foreground notification
- Handles critical battery by auto-pausing sequence
- Detects meridian flip events and sends notifications
- Platform-aware (only activates on Android/iOS)

**How It Works:**
The hooks provider watches two key providers:
1. `sequenceExecutionStateProvider` - Sequence lifecycle events
2. `sequenceProgressProvider` - Real-time progress updates

**State Transitions:**

```
IDLE → RUNNING
  ├─ Start foreground service (Android)
  ├─ Acquire wake lock
  └─ Start battery monitoring

RUNNING → PAUSED
  └─ Keep wake lock active (for quick resume)

PAUSED → RUNNING
  └─ Ensure wake lock still active

RUNNING → COMPLETED
  ├─ Stop foreground service
  ├─ Send completion notification
  ├─ Release wake lock
  └─ Stop battery monitoring

RUNNING → FAILED
  ├─ Stop foreground service
  ├─ Send failure notification
  ├─ Release wake lock
  └─ Stop battery monitoring
```

**Usage:**
```dart
// In main.dart or root widget
Consumer(
  builder: (context, ref, _) {
    // Watch the provider to initialize hooks
    ref.watch(mobileSequenceHooksProvider);

    return YourApp();
  },
);
```

**Automatic Behaviors:**
- Foreground service notification updates every time progress changes
- Battery warnings sent at 20%, 15%, 10%
- At 10% battery (critical) the operator is told; the run is not paused
- Meridian flip notifications detected from progress messages
- All services automatically cleaned up on sequence stop

**Platform Support:** Android and iOS (with platform-specific adaptations)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Sequence Provider                      │
│           (nightshade_core package)                     │
└───────────────────┬─────────────────────────────────────┘
                    │
                    │ State Changes
                    │
                    ▼
┌─────────────────────────────────────────────────────────┐
│              MobileSequenceHooks                        │
│            (watches state, coordinates services)        │
└─────┬──────────────┬──────────────┬─────────────────────┘
      │              │              │
      ▼              ▼              ▼
┌────────────┐ ┌────────────┐ ┌────────────┐
│ Foreground │ │Notification│ │   Power    │
│  Service   │ │  Service   │ │  Service   │
└────────────┘ └────────────┘ └────────────┘
      │              │              │
      ▼              ▼              ▼
 Android OS    iOS/Android      Android/iOS
Notifications  Notifications   Wake Lock API
```

## Setup

### Android Configuration

Already configured in `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Permissions -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />

<!-- Service Declaration -->
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="dataSync"
    android:exported="false" />
```

### iOS Configuration

For iOS, you would need to configure background modes in `ios/Runner/Info.plist` (future enhancement):

```xml
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>processing</string>
</array>
```

## Testing

### Battery Warning Testing

To test battery warnings without draining your battery:

```dart
// In power_service.dart, temporarily modify _getBatteryWarningLevel:
BatteryWarningLevel _getBatteryWarningLevel(int percentage) {
  // TEST MODE: Treat any level as low
  if (percentage <= 80) return BatteryWarningLevel.critical;
  if (percentage <= 90) return BatteryWarningLevel.veryLow;
  if (percentage <= 95) return BatteryWarningLevel.low;
  return BatteryWarningLevel.normal;
}
```

### Foreground Service Testing

1. Start a sequence on Android device
2. Press home button (app goes to background)
3. Pull down notification shade
4. Verify persistent notification shows progress
5. Tap notification to return to app
6. Verify service stops when sequence completes

### Wake Lock Testing

1. Start a sequence
2. Leave device idle (don't touch it)
3. After screen timeout, device should stay responsive
4. Sequence should continue running
5. Verify wake lock released when sequence stops

## Best Practices

### 1. Service Lifecycle

Always use the paired start/stop methods:
```dart
await service.startImagingSession();  // Starts everything
// ... imaging happens ...
await service.stopImagingSession();   // Stops everything
```

### 2. Error Handling

Wrap service calls in try-catch:
```dart
try {
  await service.startService(...);
} catch (e) {
  print('Failed to start service: $e');
  // Continue anyway - app will work without background service
}
```

### 3. Platform Checks

Services automatically handle platform differences, but you can check:
```dart
if (Platform.isAndroid) {
  // Android-specific code
}
```

### 4. Battery Safety

The phone's battery running low only notifies. The phone pausing the run
(a desktop host's run included) for its own battery was removed on
2026-10-06: only a risk to the hardware pauses or ends a run by itself.

## Future Enhancements

### Planned Features
- [ ] Disk space monitoring and warnings
- [ ] Network quality monitoring (for WiFi-connected mounts)
- [ ] Custom notification actions (pause/resume from notification)
- [ ] User-configurable battery thresholds
- [ ] Background upload of captured images
- [ ] iOS background mode support
- [ ] Notification settings UI in app settings

### Potential Improvements
- Adaptive battery monitoring (slower checks when battery high)
- Smart wake lock (release during long waits, re-acquire before exposure)
- Battery usage statistics
- Power consumption estimates per sequence
- Integration with device power saving modes

## Troubleshooting

### "Foreground service not starting"
- Check Android permissions granted
- Verify notification permission granted (Android 13+)
- Check logcat for errors: `adb logcat | grep Foreground`

### "Wake lock not working"
- Verify WAKE_LOCK permission in manifest
- Check device battery optimization settings
- Some manufacturers restrict wake locks - check device-specific settings

### "Notifications not appearing"
- Check notification permission granted
- Verify notification channels created successfully
- Check device notification settings for the app
- Some ROMs (Xiaomi, Oppo) have aggressive notification blocking

### "Battery monitoring not accurate"
- Battery API varies by device manufacturer
- Some devices only update battery in 5% increments
- Charging detection may lag on some devices

## Dependencies

- `flutter_foreground_task: ^6.0.0` - Android foreground service
- `flutter_local_notifications: ^16.0.0` - Local notifications
- `wakelock_plus: ^1.1.0` - Wake lock management
- `battery_plus: ^5.0.0` - Battery monitoring

## License

Part of the Nightshade project.
