import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/mount_slew_watcher.dart';

/// The watcher factory the device service slews with. Overridden in tests to
/// shrink the windows and poll cadence; production keeps the defaults.
final mountSlewWatcherFactoryProvider = Provider<MountSlewWatcherFactory>(
  (ref) =>
      ({
        required readStatus,
        required targetRa,
        required targetDec,
        isCancelled,
        onProgress,
      }) => MountSlewWatcher(
        readStatus: readStatus,
        targetRa: targetRa,
        targetDec: targetDec,
        isCancelled: isCancelled,
        onProgress: onProgress,
      ),
);

/// The slew the device service is watching, or null when none is in flight.
/// Slew controls read it to show how far the mount still has to go.
final mountSlewProgressProvider = StateProvider<MountSlewProgress?>(
  (ref) => null,
);
