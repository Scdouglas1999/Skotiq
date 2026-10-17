part of '../science_analytics_tab.dart';

// Photometric transforms card

class _PhotometricTransformsCard extends ConsumerWidget {
  final SkotiqColors colors;

  const _PhotometricTransformsCard({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transformsAsync = ref.watch(activeProfileTransformsProvider);

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Photometric Transforms',
                  style: SkotiqTypography.bodyMedium.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const _ScienceInfoButton(title: 'Photometric transforms'),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          transformsAsync.when(
            data: (transforms) => _buildTransformContent(context, transforms),
            loading: () => SizedBox(
              height: 60,
              child: Center(
                child: SizedBox(
                  width: SkotiqTokens.iconMd,
                  height: SkotiqTokens.iconMd,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
            error: (error, _) => Text(
              'Failed to load transforms: $error',
              style: SkotiqTypography.caption.copyWith(
                color: colors.error,
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SizedBox(
            width: double.infinity,
            child: SkotiqButton(
              onPressed: () => _openCalibrationWizard(context),
              icon: LucideIcons.beaker,
              label: 'Calibrate',
              variant: ButtonVariant.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransformContent(
      BuildContext context, List<PhotometricTransformRow> transforms) {
    if (transforms.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
        child: Text(
          'No transform coefficients computed yet. Use the Calibrate button '
          'to run the photometric calibration wizard on a standard star field.',
          style: SkotiqTypography.caption.copyWith(
            color: colors.textMuted,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in transforms) ...[
          _TransformRow(colors: colors, transform: t),
          if (t != transforms.last)
            const SizedBox(height: SkotiqTokens.spaceXs + 2),
        ],
      ],
    );
  }

  void _openCalibrationWizard(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const PhotometricCalibrationWizard(),
    );
  }
}

class _TransformRow extends StatelessWidget {
  final SkotiqColors colors;
  final PhotometricTransformRow transform;

  const _TransformRow({
    required this.colors,
    required this.transform,
  });

  @override
  Widget build(BuildContext context) {
    final quality = _qualityLabel(transform.rmsResidual);
    final qualityColor = _qualityColor(transform.rmsResidual, colors);
    final age = DateTime.now().difference(transform.dateComputed);
    final ageLabel = age.inDays == 0
        ? 'Today'
        : age.inDays == 1
            ? '1 day ago'
            : '${age.inDays} days ago';

    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceXs + 2,
                  vertical: 2,
                ),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.primary),
                child: Text(
                  transform.filterName,
                  style: SkotiqTypography.labelStrongSm.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceXs + 2,
                  vertical: 2,
                ),
                decoration:
                    SkotiqDecorations.chip(colors, tone: qualityColor),
                child: Text(
                  quality,
                  style: SkotiqTypography.caption.copyWith(
                      color: qualityColor, fontWeight: FontWeight.w600),
                ),
              ),
              const Spacer(),
              Text(
                ageLabel,
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs + 2),
          Row(
            children: [
              _CoefficientChip(
                colors: colors,
                label: 'ZP',
                value: transform.zeroPoint.toStringAsFixed(3),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs + 2),
              _CoefficientChip(
                colors: colors,
                label: 'k',
                value: transform.extinctionCoefficient.toStringAsFixed(3),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs + 2),
              _CoefficientChip(
                colors: colors,
                label: 'T',
                value: transform.colorTerm.toStringAsFixed(3),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs + 2),
              _CoefficientChip(
                colors: colors,
                label: 'RMS',
                value: '${transform.rmsResidual.toStringAsFixed(3)} mag',
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            '${transform.matchedStarCount} stars matched  |  '
            'Catalog: ${transform.catalogSource}',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }

  String _qualityLabel(double rms) {
    if (rms <= 0.03) return 'Excellent';
    if (rms <= 0.05) return 'Good';
    if (rms <= 0.10) return 'Acceptable';
    return 'Poor';
  }

  Color _qualityColor(double rms, SkotiqColors colors) {
    if (rms <= 0.03) return colors.success;
    if (rms <= 0.05) return colors.info;
    if (rms <= 0.10) return colors.warning;
    return colors.error;
  }
}

class _CoefficientChip extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;

  const _CoefficientChip({
    required this.colors,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: SkotiqTypography.caption
                .copyWith(color: colors.textMuted, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            style: SkotiqTypography.labelQuiet.copyWith(
              color: colors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
