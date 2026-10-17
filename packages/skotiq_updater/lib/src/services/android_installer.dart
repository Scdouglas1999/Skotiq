import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Channel the Android host listens on to launch the package installer.
///
/// Installing an APK cannot be done from Dart: it needs an Android `Intent`
/// against a `content://` URI from the app's own FileProvider, and on
/// Android 8+ it needs the user to have granted this app permission to
/// install packages. Both live on the platform side.
@visibleForTesting
const MethodChannel androidInstallerChannel = MethodChannel('skotiq/updater');

/// Overrides the installer for tests. Production leaves this null.
@visibleForTesting
Future<void> Function(String apkPath)? debugInstallApkOverride;

/// Ask Android to install the APK at [apkPath].
///
/// Returns once the system installer has been launched, not once the install
/// finishes: Android shows its own confirmation and then replaces the running
/// app. A refusal by the user is not an error this can observe.
///
/// Throws [AndroidInstallException] when the installer could not be launched
/// at all — most often because the user has not granted "install unknown
/// apps" for Skotiq, which is a condition the UI must be able to explain
/// rather than swallow.
Future<void> installApkViaPlatform(String apkPath) async {
  final override = debugInstallApkOverride;
  if (override != null) return override(apkPath);

  try {
    await androidInstallerChannel.invokeMethod<void>('installApk', {
      'apkPath': apkPath,
    });
  } on PlatformException catch (e) {
    throw AndroidInstallException(
      code: e.code,
      message: e.message ?? 'The Android package installer could not start.',
    );
  } on MissingPluginException {
    throw AndroidInstallException(
      code: 'unavailable',
      message:
          'This build has no Android installer channel, so it cannot install '
          'an update itself. Install the downloaded APK manually.',
    );
  }
}

/// Whether the user has granted this app permission to install packages.
///
/// Android 8 and later gate APK installs behind a per-app setting. Checking
/// first lets the UI send the user straight to that screen instead of having
/// the install silently do nothing.
Future<bool> canRequestPackageInstalls() async {
  try {
    final granted = await androidInstallerChannel.invokeMethod<bool>(
      'canRequestPackageInstalls',
    );
    return granted ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Open the system screen where the user grants install permission.
Future<void> openInstallPermissionSettings() async {
  try {
    await androidInstallerChannel.invokeMethod<void>(
      'openInstallPermissionSettings',
    );
  } on PlatformException catch (e) {
    throw AndroidInstallException(
      code: e.code,
      message: e.message ?? 'Could not open the install-permission screen.',
    );
  } on MissingPluginException {
    throw AndroidInstallException(
      code: 'unavailable',
      message: 'This build has no Android installer channel.',
    );
  }
}

/// Raised when the Android side could not launch or prepare an install.
class AndroidInstallException implements Exception {
  final String code;
  final String message;

  AndroidInstallException({required this.code, required this.message});

  /// True when the user has not granted install permission yet, which
  /// the UI answers with a button rather than an error.
  bool get isPermissionDenied => code == 'install_permission_denied';

  @override
  String toString() => 'AndroidInstallException($code): $message';
}
