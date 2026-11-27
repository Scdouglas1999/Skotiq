import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this process was started as. Fixed at launch: connecting a desktop
/// to a rig, or going back to driving its own equipment, restarts the app.
enum LaunchRole {
  /// A desktop window that owns the hardware.
  hostGui,

  /// The windowless daemon (`--headless`) that owns the hardware.
  hostDaemon,

  /// A desktop window driving another computer's rig (`--remote-host`).
  linkedClient,

  /// The phone or tablet app.
  mobile;

  /// Started as the machine that owns the hardware and the database.
  bool get ownsRig => this == hostGui || this == hostDaemon;

  /// Started with a screen and a person in front of it.
  bool get hasWindow => this != hostDaemon;
}

/// This process's [LaunchRole]. Each entry point overrides it; a container
/// that does not is a host window.
final launchRoleProvider = Provider<LaunchRole>((ref) => LaunchRole.hostGui);
