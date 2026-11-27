import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// What this device is, as far as the app's behavior depends on it.
///
/// The one place that reads the platform for these questions. Layout (phone,
/// tablet, desktop width) is not a device trait: the shell decides it from
/// the window, and no trait here decides layout.
class DeviceTraits {
  const DeviceTraits({required this.touchOs, required this.nativeLibrary});

  /// Android or iOS: exports go through the share sheet, there is no save
  /// dialog or folder to open, locations come from the device's GPS, and the
  /// pointer is a finger.
  final bool touchOs;

  /// The native library is loaded in this process: it can decode FITS files,
  /// launch programs such as PHD2, and run a rig. The phone app carries none.
  final bool nativeLibrary;

  /// A desktop that carries the native library.
  static const desktop = DeviceTraits(touchOs: false, nativeLibrary: true);

  /// The phone or tablet app.
  static const phone = DeviceTraits(touchOs: true, nativeLibrary: false);

  /// This process's traits: the test override when one is set, else what the
  /// platform says.
  static DeviceTraits get current => debugOverride ?? _ofThisProcess;

  /// Lets a test on a desktop host take the phone's branches.
  @visibleForTesting
  static DeviceTraits? debugOverride;

  static final DeviceTraits _ofThisProcess = () {
    if (kIsWeb) return const DeviceTraits(touchOs: false, nativeLibrary: false);
    return Platform.isAndroid || Platform.isIOS ? phone : desktop;
  }();
}
