part of '../photometric_calibration_wizard.dart';

extension _PhotometricWizardSaveNavigation
    on _PhotometricCalibrationWizardState {
  Widget _buildStep4Save(SkotiqColors colors) {
    final coeff = _computedCoefficients;
    if (coeff == null) {
      return Text(
        'No coefficients to save.',
        style: SkotiqTypography.body.copyWith(color: colors.error),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Save Calibration',
          style: SkotiqTypography.button.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 12),
        SkotiqPanel(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCoefficientRow(colors, 'Filter', coeff.filterName),
              _buildCoefficientRow(
                  colors, 'Zero Point', coeff.zeroPoint.toStringAsFixed(4)),
              _buildCoefficientRow(colors, 'Extinction',
                  coeff.extinctionCoefficient.toStringAsFixed(4)),
              _buildCoefficientRow(
                  colors, 'Color Term', coeff.colorTerm.toStringAsFixed(4)),
              _buildCoefficientRow(
                  colors, 'RMS', coeff.rmsResidual.toStringAsFixed(4)),
              _buildCoefficientRow(
                  colors, 'Stars', '${coeff.matchedStarCount}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'These coefficients will be applied to future photometry '
          'measurements taken with the "$_filterName" filter. The standard '
          'equation M_std = m_inst - k*X + T*(B-V) + zp will be used '
          'to convert instrumental magnitudes to the standard system.',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        if (_statusMessage.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _statusMessage,
            style: SkotiqTypography.caption.copyWith(
                color: _statusMessage.contains('Saved')
                    ? colors.success
                    : colors.textMuted),
          ),
        ],
      ],
    );
  }

  // Navigation

  Widget _buildNavigationButtons(SkotiqColors colors) {
    final isBusy = _isComputing || _isSaving;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (_step > 0)
          SkotiqButton(
            onPressed: isBusy ? null : () => _update(() => _step--),
            label: 'Back',
            variant: ButtonVariant.ghost,
          )
        else
          const SizedBox.shrink(),
        if (_step < 3)
          SkotiqButton(
            onPressed: !isBusy && _canAdvance() ? () => _advance() : null,
            label: 'Next',
          )
        else
          SkotiqButton(
            onPressed:
                _computedCoefficients != null && !isBusy ? _saveAndClose : null,
            icon: LucideIcons.save,
            isLoading: _isSaving,
            label: 'Save coefficients',
          ),
      ],
    );
  }

  bool _canAdvance() {
    switch (_step) {
      case 0:
        return _selectedImageIds.isNotEmpty && _filterName.isNotEmpty;
      case 1:
        return _starMatches.length >= 4;
      case 2:
        return _computedCoefficients != null;
      default:
        return false;
    }
  }

  void _advance() {
    if (_canAdvance()) {
      _update(() => _step++);
    }
  }

  Future<void> _saveAndClose() async {
    final coeff = _computedCoefficients;
    if (coeff == null || _isSaving || _isComputing) return;

    final authority = ref.read(backendProvider);
    final generation = ++_operationGeneration;
    _update(() {
      _isSaving = true;
      _statusMessage = 'Saving coefficients...';
    });

    try {
      if (authority is NetworkBackend) {
        await authority.savePhotometricTransform(coeff);
      } else {
        await ref
            .read(photometricTransformServiceProvider)
            .saveTransform(coeff);
      }
      if (!_isCurrentOperation(generation, authority)) return;
      _update(() => _statusMessage = 'Saved successfully!');
      await Future.delayed(const Duration(milliseconds: 500));
      if (!_isCurrentOperation(generation, authority)) return;
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!_isCurrentOperation(generation, authority)) return;
      _update(() {
        _isSaving = false;
        _statusMessage = 'Save failed: $error';
      });
    }
  }
}
