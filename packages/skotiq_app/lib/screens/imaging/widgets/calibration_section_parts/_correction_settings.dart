// Correction settings panel, dropdown row and formatters.
part of '../calibration_section.dart';

/// Settings sub-section: method / kernel / save-original /
/// auto-apply. Each change is persisted via [defectMapSettingsProvider]
/// AND pushed to the running sequencer (when the camera is connected and
/// has a known temperature) so the next captured frame uses the new
/// settings without requiring a sequencer restart.
class _CorrectionSettings extends ConsumerWidget {
  final SkotiqColors colors;
  final String? cameraId;
  final int sensorWidth;
  final int sensorHeight;
  final double? temperatureC;

  const _CorrectionSettings({
    required this.colors,
    required this.cameraId,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.temperatureC,
  });

  bool get _canPushToSequencer =>
      cameraId != null &&
      cameraId!.isNotEmpty &&
      sensorWidth > 0 &&
      sensorHeight > 0 &&
      temperatureC != null;

  Future<void> _runSettingsChange(
    BuildContext context,
    Future<void> Function() change,
  ) async {
    try {
      await change();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not update defect-map settings: $error'),
          backgroundColor: colors.error,
        ),
      );
    }
  }

  Future<void> _pushIfActive(WidgetRef ref) async {
    // Reconcile even when the new setting is OFF. The native sequencer owns a
    // pre-loaded runtime slot; merely persisting autoApply=false would leave a
    // previously loaded map active for subsequent frames.
    if (!_canPushToSequencer) return;
    final notifier = ref.read(defectMapNotifierProvider.notifier);
    await notifier.syncCurrentSettingsToSequencer(
      cameraId: cameraId!,
      width: sensorWidth,
      height: sensorHeight,
      sensorTemperatureCelsius: temperatureC!,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(defectMapSettingsProvider);
    if (settings.isLoading) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: SkotiqSpinner(size: 16, color: colors.primary),
          ),
          const SizedBox(width: 8),
          Text(
            'Loading correction settings…',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      );
    }
    final loadError = settings.loadError;
    if (loadError != null) {
      return Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 16, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not load correction settings from the imaging host.',
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
          ),
          TextButton(
            onPressed: () => ref.invalidate(defectMapSettingsProvider),
            child: const Text('Retry'),
          ),
        ],
      );
    }
    final notifier = ref.read(defectMapSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Correction settings',
          style: SkotiqTypography.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
              letterSpacing: 0.5),
        ),
        const SizedBox(height: 8),
        // Auto-apply: enables defect correction whenever a map exists for
        // the connected camera at the current temperature bucket.
        Row(
          children: [
            Expanded(
              child: Text(
                'Auto-apply when map exists',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            SkotiqSwitch(
              value: settings.autoApply,
              onChanged: (value) async {
                await _runSettingsChange(context, () async {
                  await notifier.setAutoApply(value);
                  // Toggling auto-apply with a map present should
                  // propagate to the sequencer immediately.
                  await _pushIfActive(ref);
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Method. The imaging side pane can be narrower than the dropdown's
        // intrinsic label width, so stack the control below its label locally
        // instead of letting the row clip offscreen.
        _ResponsiveDropdownSetting(
          label: 'Replacement method',
          colors: colors,
          value: settings.method.label,
          items: DefectMapMethod.values.map((m) => m.label).toList(),
          onChanged: (value) async {
            if (value == null) return;
            final method = DefectMapMethod.values.firstWhere(
              (m) => m.label == value,
            );
            await _runSettingsChange(context, () async {
              await notifier.setMethod(method);
              await _pushIfActive(ref);
            });
          },
        ),
        const SizedBox(height: 6),
        // Kernel.
        _ResponsiveDropdownSetting(
          label: 'Kernel size',
          colors: colors,
          value: settings.kernel.label,
          items: DefectMapKernelSize.values.map((k) => k.label).toList(),
          onChanged: (value) async {
            if (value == null) return;
            final kernel = DefectMapKernelSize.values.firstWhere(
              (k) => k.label == value,
            );
            await _runSettingsChange(context, () async {
              await notifier.setKernel(kernel);
              await _pushIfActive(ref);
            });
          },
        ),
        const SizedBox(height: 6),
        // Save original — when on, the original uncorrected frame is
        // archived to a `Raw/` sibling directory.
        Row(
          children: [
            Expanded(
              child: Text(
                'Save original to Raw/ subdir',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            SkotiqSwitch(
              value: settings.saveOriginal,
              onChanged: (value) async {
                await _runSettingsChange(context, () async {
                  await notifier.setSaveOriginal(value);
                  await _pushIfActive(ref);
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _ResponsiveDropdownSetting extends StatelessWidget {
  const _ResponsiveDropdownSetting({
    required this.label,
    required this.colors,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final SkotiqColors colors;
  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label,
      style: SkotiqTypography.caption.copyWith(color: colors.textPrimary),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final dropdown = SkotiqDropdown(
          value: value,
          items: items,
          isExpanded: constraints.maxWidth < 360,
          onChanged: onChanged,
        );

        if (constraints.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              labelWidget,
              const SizedBox(height: 6),
              dropdown,
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: labelWidget),
            const SizedBox(width: 12),
            dropdown,
          ],
        );
      },
    );
  }
}

/// Insert thousands separators into a non-negative integer's decimal
/// representation. We deliberately avoid the `intl` NumberFormat machinery
/// here because it would force a locale dependency for a single grouping
/// rule.
String _formatThousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    if (i > 0 && remaining % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Format a build timestamp as a coarse "x time ago" string. Returns
/// "(unknown date)" when the source had no usable mtime.
String _relativeAge(DateTime? at) {
  if (at == null) return '(unknown date)';
  final delta = DateTime.now().toUtc().difference(at.toUtc());
  if (delta.isNegative) {
    // Clock skew. Treat as "just now" rather than reporting a negative age.
    return 'just now';
  }
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) {
    final m = delta.inMinutes;
    return '$m minute${m == 1 ? '' : 's'} ago';
  }
  if (delta.inDays < 1) {
    final h = delta.inHours;
    return '$h hour${h == 1 ? '' : 's'} ago';
  }
  if (delta.inDays < 30) {
    final d = delta.inDays;
    return '$d day${d == 1 ? '' : 's'} ago';
  }
  if (delta.inDays < 365) {
    final months = (delta.inDays / 30).floor();
    return '$months month${months == 1 ? '' : 's'} ago';
  }
  final years = (delta.inDays / 365).floor();
  return '$years year${years == 1 ? '' : 's'} ago';
}
