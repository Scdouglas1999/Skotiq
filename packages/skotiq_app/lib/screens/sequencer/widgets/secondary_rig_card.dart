// Dual-rig / multi-camera synchronized imaging — Secondary Rig card.
//
// A small, additive card for configuring + running a secondary (piggyback)
// camera that captures its own exposure loop alongside the primary sequence,
// coordinated with the primary's dithers natively. v1 scope: same mount, no
// secondary guiding/dither/plate-solve/autofocus.
//
// Strings are intentionally hardcoded English (a concurrent i18n pass extracts
// them later). Kept self-contained so it can be dropped into the sequencer or
// equipment area without touching surrounding layout.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';

class SecondaryRigCard extends ConsumerWidget {
  const SecondaryRigCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(secondaryRigConfigProvider);
    final notifier = ref.read(secondaryRigConfigProvider.notifier);
    final statusAsync = ref.watch(secondaryRigStatusProvider);
    final camerasAsync = ref.watch(availableCamerasProvider);
    final primaryCameraId = ref.watch(
      cameraStateProvider.select((state) => state.deviceId),
    );
    final selectedCameraAvailable = camerasAsync.valueOrNull?.any(
          (camera) =>
              camera.id == config.cameraId && camera.id != primaryCameraId,
        ) ??
        false;
    final operationInProgress = ref.watch(
      secondaryRigOperationInProgressProvider,
    );
    final theme = Theme.of(context);

    final status = statusAsync.value;
    final statusKnown = statusAsync.hasValue;
    final isArmed = status != null;
    final controlsLocked = !statusKnown || isArmed || operationInProgress;

    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.camera_alt_outlined, size: 20),
                const SizedBox(width: 8),
                Text('Secondary Rig', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (operationInProgress)
                  SizedBox.square(
                    dimension: 18,
                    child: SkotiqSpinner(
                        size: 18, color: SkotiqColors.of(context).primary),
                  )
                else if (status != null)
                  _StatusBadge(status: status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Piggyback camera on the same mount. Pauses during dithers.',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 24),

            // Camera selection.
            camerasAsync.when(
              data: (cameras) {
                final selectable = cameras
                    .where((camera) => camera.id != primaryCameraId)
                    .toList(growable: false);
                final selectedId = selectable.any(
                  (camera) => camera.id == config.cameraId,
                )
                    ? config.cameraId
                    : null;
                final helperText = selectable.isEmpty
                    ? 'No additional camera detected.'
                    : config.cameraId == primaryCameraId
                        ? 'Choose a camera other than the primary camera.'
                        : config.cameraId != null && selectedId == null
                            ? 'The previously selected camera is unavailable.'
                            : null;
                return AccessibleDropdownFormField<String>(
                  initialValue: selectedId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Secondary camera',
                    helperText: helperText,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final camera in selectable)
                      DropdownMenuItem(
                        value: camera.id,
                        child: Text(camera.name),
                      ),
                  ],
                  onChanged: controlsLocked ? null : notifier.setCamera,
                );
              },
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(
                'Cameras unavailable.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
            const SizedBox(height: 12),

            // Exposure + bin row.
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: 'Exposure (s)',
                    value: config.exposureSecs,
                    enabled: !controlsLocked,
                    requiredValue: true,
                    onChanged: (value) =>
                        notifier.setExposure(value ?? double.nan),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _NumberField(
                    label: 'Gain',
                    value: config.gain?.toDouble(),
                    enabled: !controlsLocked,
                    wholeNumber: true,
                    onChanged: (v) => notifier.setGain(v?.round()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Frame count + dither policy row.
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: 'Frames (blank = until end)',
                    value: config.frameCount?.toDouble(),
                    enabled: !controlsLocked,
                    wholeNumber: true,
                    onChanged: (v) => notifier
                        .setFrameCount(v == null || v <= 0 ? null : v.round()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AccessibleDropdownFormField<SecondaryDitherPolicy>(
                    initialValue: config.ditherPolicy,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'On dither',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final p in SecondaryDitherPolicy.values)
                        DropdownMenuItem(value: p, child: Text(p.label)),
                    ],
                    onChanged: controlsLocked
                        ? null
                        : (p) {
                            if (p != null) notifier.setDitherPolicy(p);
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Controls.
            Row(
              children: [
                if (statusAsync.hasError) ...[
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop defensively'),
                    onPressed:
                        operationInProgress ? null : () => _stop(context, ref),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry status'),
                    onPressed: operationInProgress
                        ? null
                        : () => ref.invalidate(secondaryRigStatusProvider),
                  ),
                ] else if (!statusKnown)
                  const Text('Checking secondary rig status…')
                else if (!isArmed)
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start secondary'),
                    onPressed: config.isValid &&
                            selectedCameraAvailable &&
                            !operationInProgress
                        ? () => _start(context, ref)
                        : null,
                  )
                else
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop secondary'),
                    onPressed:
                        operationInProgress ? null : () => _stop(context, ref),
                  ),
                const SizedBox(width: 8),
                if (status != null)
                  Flexible(
                    child: Text(
                      '${status.framesCaptured} captured'
                      '${status.framesAborted > 0 ? ' · ${status.framesAborted} aborted' : ''}',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            if (status?.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                status!.lastError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (statusAsync.hasError) ...[
              const SizedBox(height: 8),
              Text(
                'Secondary rig status is unavailable. Start is disabled because the host may still be exposing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    try {
      // v1: no automatic target/save-path inheritance from the UI — the
      // headless/start-with-context path can pass those. Here we arm with
      // whatever the primary save path is, if discoverable.
      await ref
          .read(secondaryRigControllerProvider)
          .start(const SecondaryRigStartContext());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start secondary rig: $e')),
        );
      }
    }
  }

  Future<void> _stop(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(secondaryRigControllerProvider).stop();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop secondary rig: $e')),
        );
      }
    }
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final SecondaryRigStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final (label, color) = switch (status) {
      _ when status.waitingForDither => ('Paused (dither)', colors.warning),
      _ when status.exposing => ('Exposing', colors.success),
      _ when status.running => ('Running', colors.success),
      _ => ('Idle', colors.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.requiredValue = false,
    this.wholeNumber = false,
  });
  final String label;
  final double? value;
  final bool enabled;
  final ValueChanged<double?> onChanged;
  final bool requiredValue;
  final bool wholeNumber;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      enabled: enabled,
      initialValue: _formattedValue,
      keyboardType: TextInputType.numberWithOptions(
        decimal: !wholeNumber,
        signed: true,
      ),
      inputFormatters: [
        TextInputFormatter.withFunction((oldValue, newValue) {
          final pattern =
              wholeNumber ? RegExp(r'^-?\d*$') : RegExp(r'^-?\d*\.?\d*$');
          return pattern.hasMatch(newValue.text) ? newValue : oldValue;
        }),
      ],
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (text) {
        final trimmed = text?.trim() ?? '';
        if (trimmed.isEmpty) {
          return requiredValue ? 'Required' : null;
        }
        return double.tryParse(trimmed) == null ? 'Enter a number' : null;
      },
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (text) {
        onChanged(double.tryParse(text.trim()));
      },
    );
  }

  String get _formattedValue {
    if (value == null || !value!.isFinite) return '';
    return value == value!.roundToDouble()
        ? value!.toInt().toString()
        : value!.toString();
  }
}
