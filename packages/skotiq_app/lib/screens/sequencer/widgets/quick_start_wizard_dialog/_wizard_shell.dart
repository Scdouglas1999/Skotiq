// ignore_for_file: unused_element

part of '../quick_start_wizard_dialog.dart';

extension _WizardShell on _QuickStartWizardDialogState {
  // BUILD

  Widget _buildDialog(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final mediaQuery = MediaQuery.of(context);
    final keyboardAvailableHeight =
        mediaQuery.size.height - mediaQuery.viewInsets.vertical;
    final keyboardCompact =
        mediaQuery.viewInsets.bottom > 0 && keyboardAvailableHeight < 480;
    final dialogInset = keyboardCompact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 40, vertical: 24);
    final baseConstraints = AdaptiveDialogConstraints.hybrid(
      context,
      designMaxWidth: 700,
      designMaxHeight: 700,
    );
    final keyboardSafeMaxHeight = math.max(
      0.0,
      keyboardAvailableHeight - dialogInset.vertical,
    );

    final dialog = Dialog(
      backgroundColor: colors.surface,
      insetPadding: dialogInset,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: baseConstraints.copyWith(
          maxHeight: math.min(
            baseConstraints.maxHeight,
            keyboardSafeMaxHeight,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(colors, compact: keyboardCompact),
            if (!keyboardCompact) _buildStepIndicator(colors),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: keyboardCompact
                    ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
                    : const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                child: _buildCurrentStep(colors),
              ),
            ),
            _buildFooter(colors, compact: keyboardCompact),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: _finishingAsTemplate == null,
      child: dialog,
    );
  }

  Widget _buildHeader(SkotiqColors colors, {required bool compact}) {
    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 8, 8, 8)
          : const EdgeInsets.fromLTRB(24, 20, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.wand2, color: colors.primary, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quick-Start Sequence Wizard',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 2),
                  Text(
                    _stepTitle(_currentStep),
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: SkotiqTypography.fontSize13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: Icon(LucideIcons.x, color: colors.textSecondary, size: 20),
            tooltip: 'Close',
            visualDensity: compact ? VisualDensity.compact : null,
            constraints: compact
                ? const BoxConstraints.tightFor(width: 36, height: 36)
                : null,
            onPressed: _finishingAsTemplate == null
                ? () => Navigator.of(context).pop()
                : null,
          ),
        ],
      ),
    );
  }

  String _stepTitle(int step) {
    switch (step) {
      case 0:
        return 'Step 1 of 5: Choose Your Target';
      case 1:
        return 'Step 2 of 5: Filters & Exposures';
      case 2:
        return 'Step 3 of 5: Automation';
      case 3:
        return 'Step 4 of 5: Safety';
      case 4:
        return 'Step 5 of 5: Review & Create';
      default:
        return '';
    }
  }

  Widget _buildStepIndicator(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children:
            List.generate(_QuickStartWizardDialogState._totalSteps, (index) {
          final isCompleted = index < _currentStep;
          final isCurrent = index == _currentStep;

          return Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: isCompleted || isCurrent
                          ? colors.primary
                          : colors.border,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline2),
                    ),
                  ),
                ),
                if (index < _QuickStartWizardDialogState._totalSteps - 1)
                  const SizedBox(width: 4),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStep(SkotiqColors colors) {
    switch (_currentStep) {
      case 0:
        return _buildTargetStep(colors);
      case 1:
        return _buildFiltersStep(colors);
      case 2:
        return _buildAutomationStep(colors);
      case 3:
        return _buildSafetyStep(colors);
      case 4:
        return _buildReviewStep(colors);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildFooter(SkotiqColors colors, {required bool compact}) {
    final isReviewStep =
        _currentStep == _QuickStartWizardDialogState._totalSteps - 1;
    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: isReviewStep
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _finishingAsTemplate == null
                          ? () => _update(() => _currentStep--)
                          : null,
                      icon: Icon(
                        LucideIcons.chevronLeft,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                      label: Text(
                        'Back',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _finishingAsTemplate == null
                          ? () => Navigator.of(context).pop()
                          : null,
                      child: Text(
                        'Cancel',
                        style: TextStyle(color: colors.textMuted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      SkotiqButton(
                        onPressed: _finishingAsTemplate == null && _canAdvance()
                            ? _saveAsTemplate
                            : null,
                        icon: LucideIcons.save,
                        label: 'Save as Template',
                        variant: ButtonVariant.outline,
                        isLoading: _finishingAsTemplate == true,
                      ),
                      SkotiqButton(
                        onPressed: _finishingAsTemplate == null && _canAdvance()
                            ? _createSequence
                            : null,
                        icon: LucideIcons.sparkles,
                        label: 'Create sequence',
                        isLoading: _finishingAsTemplate == false,
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_currentStep > 0)
                  TextButton.icon(
                    onPressed: () => _update(() => _currentStep--),
                    icon: Icon(
                      LucideIcons.chevronLeft,
                      size: 16,
                      color: colors.textSecondary,
                    ),
                    label: Text(
                      'Back',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  )
                else
                  const SizedBox.shrink(),
                Row(
                  children: [
                    SkotiqButton(
                      label: 'Cancel',
                      onPressed: () => Navigator.of(context).pop(),
                      variant: ButtonVariant.ghost,
                      size: compact ? ButtonSize.small : ButtonSize.medium,
                    ),
                    const SizedBox(width: 12),
                    SkotiqButton(
                      onPressed: _canAdvance()
                          ? () => _update(() => _currentStep++)
                          : null,
                      icon: LucideIcons.chevronRight,
                      label: 'Next',
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
