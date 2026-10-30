import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:permission_handler/permission_handler.dart';

/// Screen for scanning QR codes to connect to Skotiq servers.
///
/// Pops with one of three results:
///   * [QrConnectionData] — payload was schema-valid, host was local, and the
///     operator confirmed the host+fingerprint sheet.
///   * `null` — operator backed out before a confirmed scan.
///
/// Anything that fails validation surfaces as a snackbar inside the scanner
/// and resumes scanning. Validation is a full schema check, never a
/// `startsWith('{')` sniff, which would admit arbitrary JSON.
class QrScannerScreen extends StatefulWidget {
  final Future<PermissionStatus> Function()? requestCameraPermission;

  const QrScannerScreen({super.key, this.requestCameraPermission});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  MobileScannerController? _controller;
  // Two flags so we don't fire detect callbacks while a confirmation sheet is
  // open; releasing on cancel lets the operator try a different code without
  // leaving the scanner.
  bool _hasScanned = false;
  bool _confirming = false;
  bool _initializing = false;
  bool _cameraActionPending = false;
  bool _permissionBlocked = false;
  String? _cameraError;

  SkotiqColors _colors(BuildContext context) {
    return Theme.of(context).extension<SkotiqColors>() ?? SkotiqColors.dark;
  }

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (_initializing) return;
    setState(() {
      _initializing = true;
      _cameraError = null;
      _permissionBlocked = false;
    });
    final oldController = _controller;
    _controller = null;
    try {
      if (oldController != null) {
        await oldController.dispose();
      }
      final status =
          await (widget.requestCameraPermission?.call() ??
              Permission.camera.request());
      if (!status.isGranted) {
        if (mounted) {
          setState(() {
            _permissionBlocked =
                status.isPermanentlyDenied || status.isRestricted;
            _cameraError =
                'Camera permission is required to scan pairing QR codes. '
                'Allow camera access for Skotiq, then retry.';
          });
        }
        return;
      }

      final controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _cameraError =
              'Camera unavailable. Allow camera permission for Skotiq '
              'and try again.\n\n($e)';
        });
      }
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  Future<void> _runCameraAction(
    String failurePrefix,
    Future<void> Function(MobileScannerController) action,
  ) async {
    final controller = _controller;
    if (_cameraActionPending || controller == null) return;
    setState(() => _cameraActionPending = true);
    try {
      await action(controller);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failurePrefix: $error')));
      }
    } finally {
      if (mounted) setState(() => _cameraActionPending = false);
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_hasScanned || _confirming || _controller == null) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;

      // Mark scanned upfront so a stream of identical detections doesn't queue
      // multiple confirmation sheets.
      _hasScanned = true;
      _confirming = true;

      try {
        final data = QrConnectionData.parseStrict(value);
        if (data.host == 'localhost' || data.host == '127.0.0.1') {
          throw const QrValidationException(
            QrRejectionReason.hostNotLocal,
            'QR code points at this computer only (localhost). '
            'Regenerate the code on the desktop after LAN IP is detected.',
          );
        }
        final confirmed = await _confirmConnection(data);
        if (!mounted) return;
        if (confirmed) {
          Navigator.of(context).pop(data);
          return;
        }
        // Operator cancelled — let them rescan a different code.
        _confirming = false;
        _hasScanned = false;
        return;
      } on QrValidationException catch (e) {
        if (!mounted) return;
        _confirming = false;
        _hasScanned = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rejected QR code: ${e.message}'),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      } catch (error) {
        if (!mounted) return;
        _confirming = false;
        _hasScanned = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not read this QR code: $error'),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }
    }
  }

  Future<bool> _confirmConnection(QrConnectionData data) async {
    final colors = _colors(context);
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: colors.background.withValues(alpha: 0.72),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusLg),
        ),
      ),
      builder: (context) {
        return SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: colors.surfaceElevated,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(SkotiqTokens.radiusLg),
              ),
              border: Border(top: BorderSide(color: colors.border)),
              boxShadow: SkotiqTokens.shadowLg,
            ),
            padding: SkotiqTokens.dialogPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Confirm pairing',
                  style: SkotiqTypography.h4.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqCard(
                  padding: SkotiqTokens.cardPadding,
                  variant: CardVariant.elevated,
                  child: Text.rich(
                    TextSpan(
                      style: SkotiqTypography.body.copyWith(
                        color: colors.textPrimary,
                      ),
                      children: [
                        const TextSpan(text: 'Connect to '),
                        TextSpan(
                          text: '${data.host}:${data.webPort}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const TextSpan(text: '?\n\nServer fingerprint: '),
                        TextSpan(
                          text: data.shortFingerprint,
                          style: SkotiqTypography.mono.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Text(
                  'Verify this fingerprint matches the desktop app before continuing.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.space2xl),
                Row(
                  children: [
                    Expanded(
                      child: SkotiqButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        label: 'Cancel',
                        variant: ButtonVariant.outline,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceMd),
                    Expanded(
                      child: SkotiqButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        label: 'Connect',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors(context);

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        title: const Text('Scan QR Code'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_controller case final controller?)
            ValueListenableBuilder<MobileScannerState>(
              valueListenable: controller,
              builder: (context, camera, _) {
                final ready = camera.isInitialized && camera.isRunning;
                final torchAvailable =
                    camera.torchState != TorchState.unavailable;
                final canSwitch =
                    camera.availableCameras == null ||
                    camera.availableCameras! > 1;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        camera.torchState == TorchState.on
                            ? Icons.flash_on
                            : Icons.flash_off,
                      ),
                      tooltip: torchAvailable
                          ? 'Toggle torch'
                          : 'Torch unavailable',
                      onPressed:
                          ready && torchAvailable && !_cameraActionPending
                          ? () => _runCameraAction(
                              'Could not toggle the torch',
                              (value) => value.toggleTorch(),
                            )
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.flip_camera_ios),
                      tooltip: canSwitch
                          ? 'Switch camera'
                          : 'No second camera available',
                      onPressed: ready && canSwitch && !_cameraActionPending
                          ? () => _runCameraAction(
                              'Could not switch cameras',
                              (value) => value.switchCamera(),
                            )
                          : null,
                    ),
                  ],
                );
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_initializing)
                  const Center(
                    child: SkotiqMark(
                      motion: SkotiqMarkMotion.loading,
                      size: 36,
                    ),
                  )
                else if (_cameraError != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: _CameraRecovery(
                        message: _cameraError!,
                        showSettings: _permissionBlocked,
                        onRetry: _initCamera,
                      ),
                    ),
                  )
                else if (_controller != null)
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    overlayBuilder: (context, constraints) {
                      final overlaySize =
                          (constraints.biggest.shortestSide * 0.65).clamp(
                            200.0,
                            280.0,
                          );
                      return Center(
                        child: Container(
                          width: overlaySize,
                          height: overlaySize,
                          decoration: BoxDecoration(
                            border: Border.all(color: colors.primary, width: 3),
                            borderRadius: BorderRadius.circular(
                              SkotiqTokens.radiusLg,
                            ),
                          ),
                        ),
                      );
                    },
                    errorBuilder: (context, error, _) => _CameraRecovery(
                      message: 'The camera stopped: $error',
                      showSettings:
                          error.errorCode ==
                          MobileScannerErrorCode.permissionDenied,
                      onRetry: _initCamera,
                    ),
                  ),
              ],
            ),
          ),
          // Instructions
          Container(
            padding: const EdgeInsets.all(24),
            color: colors.surface,
            child: Column(
              children: [
                Text(
                  'Scan the QR code displayed on your Skotiq server',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize16,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'On the desktop: Settings → Remote Access → Start pairing, '
                  'then scan the QR shown there.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: SkotiqTypography.fontSize13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraRecovery extends StatelessWidget {
  final String message;
  final bool showSettings;
  final Future<void> Function() onRetry;

  const _CameraRecovery({
    required this.message,
    required this.showSettings,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colors =
        Theme.of(context).extension<SkotiqColors>() ?? SkotiqColors.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.no_photography_outlined,
              color: colors.warning,
              size: 36,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                SkotiqButton(
                  label: 'Retry camera',
                  onPressed: () => unawaited(onRetry()),
                ),
                if (showSettings)
                  SkotiqButton(
                    label: 'Open settings',
                    variant: ButtonVariant.outline,
                    onPressed: () => unawaited(openAppSettings()),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
