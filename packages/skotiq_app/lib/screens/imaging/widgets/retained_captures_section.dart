import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import 'panel_widgets.dart';

/// The captures the camera is keeping because their download failed, each
/// with the action that reads it off the camera. Absent while there are
/// none. The imaging run never waits for these.
class RetainedCapturesSection extends ConsumerStatefulWidget {
  const RetainedCapturesSection({super.key, required this.colors});

  final SkotiqColors colors;

  @override
  ConsumerState<RetainedCapturesSection> createState() =>
      _RetainedCapturesSectionState();
}

class _RetainedCapturesSectionState
    extends ConsumerState<RetainedCapturesSection> {
  /// The location being retrieved, so its button shows it and the others
  /// wait: a camera reads one file at a time.
  String? _retrieving;

  Future<void> _retrieve(RetainedCapture capture) async {
    final host = ref.backendScope(alive: () => mounted);
    final backend = ref.read(deviceBackendProvider);
    setState(() => _retrieving = capture.location);
    try {
      final savedTo = await backend.cameraRetrieveRetainedCapture(
        capture.deviceId,
        capture.location,
      );
      if (mounted && host.isCurrent) {
        ref.read(retainedCapturesRevisionProvider.notifier).state++;
        // The file is on the computer the camera is plugged into, which a
        // linked client is not.
        context.showSuccessSnackBar('Saved on the imaging computer: $savedTo');
      }
    } catch (e) {
      if (mounted && host.isCurrent) {
        ref.read(retainedCapturesRevisionProvider.notifier).state++;
        context.showErrorSnackBar(
          'The capture could not be retrieved: ${userFacingError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _retrieving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final captures =
        ref.watch(retainedCapturesProvider).asData?.value ?? const [];
    if (captures.isEmpty) return const SizedBox.shrink();
    final colors = widget.colors;
    final exposing = ref.watch(cameraStateProvider.select((c) => c.isExposing));
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: PanelSection(
        title: 'Kept on the camera',
        colors: colors,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'These captures could not be downloaded. Imaging goes on; '
              'retrieve each one when the camera is idle.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            for (final capture in captures) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          capture.location.split('/').last,
                          style: SkotiqTypography.labelStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          capture.inCameraMemory
                              ? "In the camera's memory until it is switched "
                                  'off or a later exposure replaces it'
                              : "On the camera's card: ${capture.location}",
                          style: SkotiqTypography.caption.copyWith(
                            color: capture.inCameraMemory
                                ? colors.warning
                                : colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: exposing
                        ? 'The camera is exposing; retrieve when it is idle'
                        : capture.reason,
                    child: OutlinedButton(
                      key: ValueKey<String>(
                        'retainedCapture.retrieve.${capture.location}',
                      ),
                      onPressed: exposing || _retrieving != null
                          ? null
                          : () => _retrieve(capture),
                      child: Text(
                        _retrieving == capture.location
                            ? 'Retrieving…'
                            : 'Retrieve',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
