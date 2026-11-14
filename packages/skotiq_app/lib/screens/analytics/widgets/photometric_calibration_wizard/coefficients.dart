part of '../photometric_calibration_wizard.dart';

extension _PhotometricWizardCoefficients on _PhotometricCalibrationWizardState {
  Widget _buildStep3ComputeCoefficients(SkotiqColors colors) {
    if (_computedCoefficients == null && !_isComputing && !_fitAttempted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _computeFit());
    }

    if (_isComputing) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }

    final coeff = _computedCoefficients;
    if (coeff == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _statusMessage.isEmpty ? 'Fit computation failed.' : _statusMessage,
            style: SkotiqTypography.bodySm.copyWith(color: colors.error),
          ),
          const SizedBox(height: 12),
          SkotiqButton(
            label: 'Retry fit',
            icon: LucideIcons.refreshCw,
            size: ButtonSize.small,
            onPressed: () {
              _fitAttempted = false;
              _computeFit();
            },
          ),
        ],
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Transformation Coefficients',
            style: SkotiqTypography.button.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          _buildCoefficientRow(
              colors, 'Zero Point (ZP)', coeff.zeroPoint.toStringAsFixed(4)),
          _buildCoefficientRow(colors, 'Extinction (k)',
              coeff.extinctionCoefficient.toStringAsFixed(4)),
          _buildCoefficientRow(
              colors, 'Color Term (T)', coeff.colorTerm.toStringAsFixed(4)),
          _buildCoefficientRow(
              colors, 'RMS Residual', coeff.rmsResidual.toStringAsFixed(4)),
          _buildCoefficientRow(
              colors, 'Stars Used', '${coeff.matchedStarCount}'),
          const SizedBox(height: 8),
          _buildQualityIndicator(colors, coeff),
          const SizedBox(height: 12),
          Text(
            'Residual Plot',
            style: SkotiqTypography.label.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          AdaptiveChartContainer(
            preferredHeight: 180,
            child: _buildResidualPlot(colors, coeff),
          ),
        ],
      ),
    );
  }

  Widget _buildCoefficientRow(SkotiqColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary)),
          Text(
            value,
            style: SkotiqTypography.readoutSm.copyWith(
                color: colors.textPrimary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityIndicator(
      SkotiqColors colors, PhotometricTransformCoefficients coeff) {
    final rms = coeff.rmsResidual;
    final Color qualityColor;
    final String qualityLabel;
    if (rms < 0.05) {
      qualityColor = colors.success;
      qualityLabel = 'Excellent';
    } else if (rms < 0.10) {
      qualityColor = colors.success;
      qualityLabel = 'Good';
    } else if (rms < 0.20) {
      qualityColor = colors.warning;
      qualityLabel = 'Acceptable';
    } else {
      qualityColor = colors.error;
      qualityLabel = 'Poor';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: SkotiqDecorations.chip(colors, tone: qualityColor),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: qualityColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Fit Quality: $qualityLabel (RMS ${rms.toStringAsFixed(4)} mag)',
            style: SkotiqTypography.labelSm.copyWith(
              color: qualityColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResidualPlot(
      SkotiqColors colors, PhotometricTransformCoefficients coeff) {
    if (coeff.fitData.isEmpty) {
      return Center(
        child: Text('No fit data available',
            style: SkotiqTypography.body.copyWith(color: colors.textMuted)),
      );
    }

    // Residuals past twice the fit's RMS are outliers, drawn in the error
    // tone.
    final outlierLimit = 2 * coeff.rmsResidual;
    final inliers = <Offset>[];
    final outliers = <Offset>[];
    for (final match in coeff.fitData) {
      final point = Offset(match.catalogMag, match.residual);
      (match.residual.abs() > outlierLimit ? outliers : inliers).add(point);
    }

    return SkotiqChart(
      semanticLabel: 'Fit residuals of ${coeff.fitData.length} stars, '
          '${outliers.length} past twice the RMS',
      series: <ChartSeries>[
        ChartSeries(
          points: inliers,
          label: 'Residual',
          kind: ChartSeriesKind.scatter,
          dotRadius: 3,
        ),
        if (outliers.isNotEmpty)
          ChartSeries(
            points: outliers,
            label: 'Outlier',
            tone: SeriesChartTone.error,
            kind: ChartSeriesKind.scatter,
            dotRadius: 3,
          ),
      ],
      x: ChartAxis(
        title: 'Catalog Magnitude',
        format: (mag) => mag.toStringAsFixed(1),
      ),
      y: ChartAxis(
        title: 'Residual (mag)',
        format: (mag) => mag.toStringAsFixed(2),
        includeZero: true,
      ),
      rules: const [ChartRule.y(0)],
      readout: false,
    );
  }

  Future<void> _computeFit() async {
    if (_starMatches.length < 4 || _isComputing || _isSaving) return;

    final generation = ++_operationGeneration;
    final authority = ref.read(backendProvider);
    final starMatches = List<CatalogStarMatch>.unmodifiable(_starMatches);
    final filterName = _filterName.trim();

    _update(() {
      _isComputing = true;
      _fitAttempted = true;
    });

    try {
      final profileId = ref.read(activeEquipmentProfileIdProvider);
      final (:coefficients, :refusal) =
          await ref.read(photometricTransformsProvider).fit(
                starMatches: starMatches,
                filterName: filterName,
                equipmentProfileId: profileId,
              );

      if (!_isCurrentOperation(generation, authority)) return;
      _update(() {
        _computedCoefficients = coefficients;
        _isComputing = false;
        if (coefficients == null) {
          _statusMessage = refusal ??
              'Failed to compute fit. Check that stars have sufficient '
                  'airmass and color index spread.';
        }
      });
    } catch (error) {
      if (!_isCurrentOperation(generation, authority)) return;
      _update(() {
        _isComputing = false;
        _statusMessage = 'Computation failed: ${userFacingError(error)}';
      });
    }
  }
}
