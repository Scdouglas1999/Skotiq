// Defect-map status blocks, bucket chips and status lines.
part of '../calibration_section.dart';

class _StatusBlock extends ConsumerWidget {
  final SkotiqColors colors;
  final String? cameraId;
  final String? cameraName;
  final int sensorWidth;
  final int sensorHeight;
  final double? temperatureC;
  final String? disabledReason;

  const _StatusBlock({
    required this.colors,
    required this.cameraId,
    required this.cameraName,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.temperatureC,
    required this.disabledReason,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (disabledReason != null) {
      return _StatusLine(
        colors: colors,
        icon: LucideIcons.alertCircle,
        iconColor: colors.warning,
        message: disabledReason!,
      );
    }

    final statusAsync = ref.watch(defectMapStatusProvider(
      DefectMapQuery(
        cameraId: cameraId!,
        width: sensorWidth,
        height: sensorHeight,
        sensorTemperatureCelsius: temperatureC!,
      ),
    ));

    return statusAsync.when(
      data: (status) {
        if (status == null) {
          return _NoMapForBucketBlock(
            colors: colors,
            cameraId: cameraId!,
            cameraName: cameraName ?? cameraId!,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            currentTemperatureC: temperatureC!,
          );
        }
        final pixels = _formatThousands(status.defectivePixelCount);
        final age = _relativeAge(status.lastRebuiltAt);
        return _StatusLine(
          colors: colors,
          icon: LucideIcons.checkCircle2,
          iconColor: colors.success,
          message:
              'Defect map: $pixels pixels (built $age at ${status.temperatureBucket.label})',
        );
      },
      loading: () => _StatusLine(
        colors: colors,
        icon: SkotiqIcons.loading,
        iconColor: colors.textSecondary,
        message: 'Loading defect map status...',
      ),
      error: (err, _) => _StatusLine(
        colors: colors,
        icon: SkotiqIcons.warning,
        iconColor: colors.error,
        message: 'Failed to load defect map status: $err',
      ),
    );
  }
}

/// Empty-state block shown when no defect map exists for the current
/// (camera, sensor, temperature bucket) tuple. Falls back to scanning
/// neighbouring temperature buckets so the user is offered the nearest
/// existing map as a one-click alternative — this covers the common
/// case where the cooler set-point sits 5C away from the temperature the
/// darks were captured at.
class _NoMapForBucketBlock extends ConsumerWidget {
  /// Range of buckets to probe around the current temperature when
  /// looking for an existing map at a neighbouring set-point. 9 buckets
  /// at 5C each spans 40C of cooler range, which covers everything from
  /// a -25C uncooled CMOS at one extreme to a TEC running at +15C on a
  /// hot night at the other.
  static const int _maxBucketOffsetSteps = 9;
  static const double _bucketStepCelsius = 5.0;

  final SkotiqColors colors;
  final String cameraId;
  final String cameraName;
  final int sensorWidth;
  final int sensorHeight;
  final double currentTemperatureC;

  const _NoMapForBucketBlock({
    required this.colors,
    required this.cameraId,
    required this.cameraName,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.currentTemperatureC,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentBucket =
        DefectMapTemperatureBucket.fromCelsius(currentTemperatureC);
    final fallback = _findNearestExistingBucket(ref, currentBucket);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(
          colors: colors,
          icon: SkotiqIcons.info,
          iconColor: colors.textSecondary,
          message: 'No defect map for $cameraName at ${currentBucket.label}.',
        ),
        const SizedBox(height: 6),
        Text(
          'Capture 20+ dark frames at this temperature, then click Build '
          'to generate one.',
          style: SkotiqTypography.caption
              .copyWith(color: colors.textSecondary, height: 1.4),
        ),
        if (fallback != null) ...[
          const SizedBox(height: 10),
          _AlternateBucketChip(
            colors: colors,
            cameraId: cameraId,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            currentBucket: currentBucket,
            alternateBucket: fallback,
          ),
        ],
      ],
    );
  }

  /// Probe neighbouring temperature buckets (alternating outward from the
  /// current bucket) and return the closest one that has a stored map.
  /// Returns null if no map exists anywhere within the probed range.
  ///
  /// Implementation note: this synchronously reads cached
  /// `defectMapStatusProvider` values for each probed bucket. Riverpod's
  /// FutureProvider.family lazily computes on read and the widget rebuilds
  /// when each future resolves, so the first frame may show no fallback
  /// and a follow-up frame may surface one once the probes complete.
  DefectMapTemperatureBucket? _findNearestExistingBucket(
    WidgetRef ref,
    DefectMapTemperatureBucket currentBucket,
  ) {
    for (var step = 1; step <= _maxBucketOffsetSteps; step++) {
      for (final sign in const [-1, 1]) {
        final candidateCelsius =
            currentBucket.celsius + (sign * step * _bucketStepCelsius);
        final status = ref.watch(defectMapStatusProvider(
          DefectMapQuery(
            cameraId: cameraId,
            width: sensorWidth,
            height: sensorHeight,
            sensorTemperatureCelsius: candidateCelsius,
          ),
        ));
        final existing = status.valueOrNull;
        if (existing != null && existing.storedOnDisk) {
          return existing.temperatureBucket;
        }
      }
    }
    return null;
  }
}

class _AlternateBucketChip extends ConsumerWidget {
  final SkotiqColors colors;
  final String cameraId;
  final int sensorWidth;
  final int sensorHeight;
  final DefectMapTemperatureBucket currentBucket;
  final DefectMapTemperatureBucket alternateBucket;

  const _AlternateBucketChip({
    required this.colors,
    required this.cameraId,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.currentBucket,
    required this.alternateBucket,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delta =
        (alternateBucket.celsius - currentBucket.celsius).toStringAsFixed(0);
    final signedDelta =
        alternateBucket.celsius >= currentBucket.celsius ? '+$delta' : delta;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.accent,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(SkotiqIcons.temperature, size: 14, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'A map exists for ${alternateBucket.label} ($signedDelta C '
              'from current).',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textPrimary, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          SkotiqButton(
            label: 'Use ${alternateBucket.label} map',
            icon: SkotiqIcons.check,
            size: ButtonSize.small,
            variant: ButtonVariant.outline,
            onPressed: () async {
              final notifier = ref.read(defectMapNotifierProvider.notifier);
              // Enable the existing alternate-bucket map for capture-time
              // application. The notifier scopes the apply flag to the
              // camera id, not the bucket, so this is exactly the same
              // call the user would have flipped via the Apply switch.
              await notifier.setApplyDuringCapture(
                cameraId: cameraId,
                apply: true,
                width: sensorWidth,
                height: sensorHeight,
                sensorTemperatureCelsius: alternateBucket.celsius,
              );
              if (!context.mounted) return;
              final state = ref.read(defectMapNotifierProvider);
              if (state.errorMessage != null) {
                context.showErrorSnackBar(state.errorMessage!);
              } else {
                context.showSuccessSnackBar(
                  'Using ${alternateBucket.label} defect map for this '
                  'camera until you build one at ${currentBucket.label}.',
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final Color iconColor;
  final String message;

  const _StatusLine({
    required this.colors,
    required this.icon,
    required this.iconColor,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      backgroundColor: colors.background,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textPrimary, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
