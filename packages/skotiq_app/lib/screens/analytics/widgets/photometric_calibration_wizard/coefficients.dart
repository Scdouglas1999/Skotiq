part of '../photometric_calibration_wizard.dart';

extension _PhotometricWizardCoefficients on _PhotometricCalibrationWizardState {
  Widget _buildStep3ComputeCoefficients(SkotiqColors colors) {
    if (_computedCoefficients == null && !_isComputing && !_fitAttempted) {
      // Automatically trigger computation
      WidgetsBinding.instance.addPostFrameCallback((_) => _computeFit());
    }

    if (_isComputing) {
      return const Center(child: CircularProgressIndicator());
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

    final spots = coeff.fitData
        .map((match) => FlSpot(match.catalogMag, match.residual))
        .toList(growable: false);

    var minX = spots.first.x, maxX = spots.first.x;
    var minY = spots.first.y, maxY = spots.first.y;
    for (final spot in spots) {
      if (spot.x < minX) minX = spot.x;
      if (spot.x > maxX) maxX = spot.x;
      if (spot.y < minY) minY = spot.y;
      if (spot.y > maxY) maxY = spot.y;
    }
    final yRange = math.max(0.1, maxY - minY);

    return ScatterChart(
      ScatterChartData(
        minX: minX - 0.5,
        maxX: maxX + 0.5,
        minY: minY - yRange * 0.2,
        maxY: maxY + yRange * 0.2,
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: colors.border),
        ),
        gridData: FlGridData(
          drawVerticalLine: true,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: colors.border.withValues(alpha: 0.35)),
          getDrawingVerticalLine: (_) =>
              FlLine(color: colors.border.withValues(alpha: 0.25)),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            axisNameWidget: Text('Catalog Magnitude',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(1),
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text('Residual (mag)',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(2),
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
          ),
        ),
        scatterSpots: spots
            .map(
              (spot) => ScatterSpot(
                spot.x,
                spot.y,
                dotPainter: FlDotCirclePainter(
                  radius: 3,
                  color: spot.y.abs() > 2 * coeff.rmsResidual
                      ? colors.error
                      : colors.primary,
                  strokeWidth: 0,
                ),
              ),
            )
            .toList(growable: false),
        scatterTouchData: ScatterTouchData(enabled: false),
      ),
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
      final coefficients = authority is NetworkBackend
          ? await authority.computePhotometricTransform(
              starMatches: starMatches,
              filterName: filterName,
              equipmentProfileId: profileId,
            )
          : ref
              .read(photometricTransformServiceProvider)
              .computeTransformCoefficients(
                starMatches: starMatches,
                filterName: filterName,
                equipmentProfileId: profileId,
              );

      if (!_isCurrentOperation(generation, authority)) return;
      _update(() {
        _computedCoefficients = coefficients;
        _isComputing = false;
        if (coefficients == null) {
          _statusMessage =
              'Failed to compute fit. Check that stars have sufficient '
              'airmass and color index spread.';
        }
      });
    } catch (error) {
      if (!_isCurrentOperation(generation, authority)) return;
      _update(() {
        _isComputing = false;
        _statusMessage = 'Computation failed: $error';
      });
    }
  }

  // Step 4: save
}
