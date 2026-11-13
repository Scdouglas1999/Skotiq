import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/mount_home_watcher.dart';

/// The watcher factory the device service homes with. Overridden in tests to
/// shrink the motion window and poll cadence; production keeps the defaults.
final mountHomeWatcherFactoryProvider = Provider<MountHomeWatcherFactory>(
  (ref) =>
      ({required readStatus, isCancelled}) =>
          MountHomeWatcher(readStatus: readStatus, isCancelled: isCancelled),
);
