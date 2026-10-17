import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/troubleshooter/connection_troubleshooter_dialog.dart';

/// Mixin that provides unified device connection/disconnection handling.
///
/// This eliminates duplicate connect/disconnect handler code across equipment screens.
/// All device connection handlers should use this mixin instead of implementing
/// their own try/catch/setState patterns.
mixin DeviceConnectionMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  /// Connects to a device with unified error handling.
  ///
  /// [deviceId] - The unique identifier of the device to connect
  /// [deviceName] - Display name for error messages
  /// [connectFn] - The async function that performs the actual connection
  /// [onConnected] - Optional callback after successful connection (e.g., for profile dialog)
  /// [deviceType] - The kind of device being connected (camera, mount, ...).
  ///   Opt-in: when supplied together with [driverType], a connect failure is
  ///   routed through the guided [ConnectionTroubleshooterDialog] instead of a
  ///   bare error snackbar.
  /// [driverType] - The driver protocol in use (ASCOM / Alpaca / INDI / native /
  ///   simulator). When `null` it is derived defensively from [deviceId] via
  ///   [driverTypeFromDeviceId], falling back to [DriverType.native].
  ///
  /// Callers that pass neither [deviceType] nor [driverType] get a bare error
  /// snackbar instead of the troubleshooter.
  Future<void> connectDevice({
    required String deviceId,
    required String deviceName,
    required Future<void> Function(String) connectFn,
    Future<void> Function()? onConnected,
    DeviceType? deviceType,
    DriverType? driverType,
  }) async {
    if (_isConnecting) return;

    setState(() => _isConnecting = true);
    try {
      await connectFn(deviceId);

      if (onConnected != null && mounted) {
        await onConnected();
      }
    } catch (e) {
      // Opt-in troubleshooter path: only when the caller supplied the device
      // type. The driver type is resolved defensively — prefer the passed
      // `driverType`, otherwise derive it from the namespaced device id, and
      // fall back to native when the prefix is unrecognised — so a caller that
      // knows the device type but not the exact protocol still gets the guided
      // recovery flow rather than the bare snackbar.
      final resolvedDriverType =
          driverType ?? driverTypeFromDeviceId(deviceId) ?? DriverType.native;
      if (deviceType != null && mounted) {
        // The raw driver string is never swallowed — the dialog carries it
        // through verbatim in its "Technical details" section
        // (errors-are-a-feature).
        final retry = await ConnectionTroubleshooterDialog.show(
          context,
          deviceType: deviceType,
          driverType: resolvedDriverType,
          rawError: e.toString(),
        );
        if (retry && mounted) {
          // Re-attempt exactly once. A second failure falls back to the
          // snackbar rather than re-opening the dialog, so the retry is bounded
          // by construction (no recursion, no loop).
          try {
            await connectFn(deviceId);
            if (onConnected != null && mounted) {
              await onConnected();
            }
          } catch (retryError) {
            if (mounted) {
              context.showErrorSnackBar(
                'Failed to connect $deviceName: $retryError',
              );
            }
          }
        }
      } else if (mounted) {
        context.showErrorSnackBar('Failed to connect $deviceName: $e');
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  /// Disconnects from a device with unified error handling.
  ///
  /// [disconnectFn] - The async function that performs the actual disconnection
  /// [deviceType] - Display name for error messages (e.g., 'camera', 'mount')
  Future<void> disconnectDevice({
    required Future<void> Function() disconnectFn,
    required String deviceType,
  }) async {
    try {
      await disconnectFn();
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to disconnect $deviceType: $e');
      }
    }
  }
}
