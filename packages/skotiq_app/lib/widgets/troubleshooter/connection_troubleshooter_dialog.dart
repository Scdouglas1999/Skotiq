import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The connection-troubleshooter knowledge base (C3) is a pure, side-effect-free
// model that the C3 owner deliberately kept out of the skotiq_core barrel
// (matching its own test suite, which imports the source path directly). We
// follow that precedent here — the same pattern hardware_preset_picker_dialog.dart
// uses for the hardware-presets provider/service.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/troubleshooter/connection_diagnostic.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A first-light-friendly dialog that turns a hostile raw driver error into a
/// plain-language explanation plus an ordered, hardware-aware remediation
/// playbook.
///
/// The raw driver string is never thrown away: it is carried through verbatim
/// and surfaced in a collapsible "Technical details" section, so an advanced
/// user or support can read the exact message while a first-time imager is
/// guided by the friendly copy above it.
///
/// Use the static [show] entry point. It resolves to `true` when the user asked
/// to retry the connection, and `false` (or `null` on barrier dismiss) when the
/// user closed the dialog without retrying — letting the caller re-attempt the
/// connection without re-deriving anything.
class ConnectionTroubleshooterDialog extends StatefulWidget {
  /// The device whose connection failed (drives device-specific copy/steps).
  final DeviceType deviceType;

  /// The driver protocol that was in use (ASCOM / Alpaca / INDI / native /
  /// simulator) — drives protocol-specific remediation branches.
  final DriverType driverType;

  /// The raw driver error string, carried through verbatim. `null` when the
  /// caller had no error text (e.g. an empty discovery result).
  final String? rawError;

  const ConnectionTroubleshooterDialog({
    super.key,
    required this.deviceType,
    required this.driverType,
    this.rawError,
  });

  /// Shows the troubleshooter dialog and resolves to `true` if the user chose
  /// to retry the connection, otherwise `false`.
  static Future<bool> show(
    BuildContext context, {
    required DeviceType deviceType,
    required DriverType driverType,
    String? rawError,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConnectionTroubleshooterDialog(
        deviceType: deviceType,
        driverType: driverType,
        rawError: rawError,
      ),
    );
    return result ?? false;
  }

  @override
  State<ConnectionTroubleshooterDialog> createState() =>
      _ConnectionTroubleshooterDialogState();
}

class _ConnectionTroubleshooterDialogState
    extends State<ConnectionTroubleshooterDialog> {
  late final ConnectionDiagnosis _diagnosis;
  bool _showTechnicalDetails = false;

  @override
  void initState() {
    super.initState();
    _diagnosis = diagnoseConnectionFailure(
      deviceType: widget.deviceType,
      driverType: widget.driverType,
      rawError: widget.rawError,
    );
  }

  /// Maps the diagnostic category to an alert severity. A configuration problem
  /// is informational (the link is up, just mis-set); everything else is a
  /// warning the user must act on.
  SkotiqAlertSeverity get _severity {
    switch (_diagnosis.category) {
      case DiagnosticCategory.configuration:
        return SkotiqAlertSeverity.info;
      case DiagnosticCategory.usb:
      case DiagnosticCategory.driver:
      case DiagnosticCategory.permission:
      case DiagnosticCategory.network:
      case DiagnosticCategory.unknown:
        return SkotiqAlertSeverity.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final rawError = _diagnosis.rawError;

    return SkotiqDialog(
      title: 'Connection help',
      icon: LucideIcons.wrench,
      width: 640,
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SkotiqButton(
          label: 'Retry connection',
          icon: LucideIcons.refreshCw,
          variant: ButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Severity-styled header: the headline as the alert title and the
          // plain-language explanation as the message body.
          SkotiqAlert(
            severity: _severity,
            title: _diagnosis.headline,
            message: _diagnosis.plainLanguage,
          ),
          const SizedBox(height: SkotiqTokens.spaceXl),

          // The ordered remediation playbook.
          Text(
            'Try these steps',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          for (var i = 0; i < _diagnosis.steps.length; i++) ...[
            if (i > 0) const SizedBox(height: SkotiqTokens.spaceLg),
            _RemediationStepRow(
              number: i + 1,
              step: _diagnosis.steps[i],
              colors: colors,
            ),
          ],

          // Collapsible technical-details section. The raw driver string is
          // available but quiet — present for the curious, not shouting at a
          // first-timer.
          if (rawError != null && rawError.trim().isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceXl),
            _TechnicalDetails(
              rawError: rawError,
              expanded: _showTechnicalDetails,
              onToggle: () => setState(
                () => _showTechnicalDetails = !_showTechnicalDetails,
              ),
              colors: colors,
            ),
          ],
        ],
      ),
    );
  }
}

/// A single numbered remediation row: a circular badge with the step number,
/// the imperative instruction in [SkotiqTypography.bodyMedium], and the
/// optional supporting detail in [SkotiqTypography.caption] (muted).
///
/// Mirrors the equipment screen's `_SetupStep` badge styling
/// ([SkotiqDecorations.kpiBadge] on a circle) so the playbook reads as part
/// of the same design language.
class _RemediationStepRow extends StatelessWidget {
  final int number;
  final RemediationStep step;
  final SkotiqColors colors;

  const _RemediationStepRow({
    required this.number,
    required this.step,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final detail = step.detail;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: SkotiqDecorations.kpiBadge(
            colors.primary,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$number',
              style: SkotiqTypography.labelSm.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.instruction,
                style: SkotiqTypography.bodyMedium.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  detail,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A collapsible "Technical details" section showing the raw driver error in a
/// monospace block on a [SkotiqColors.surface] fill. Collapsed by default
/// so the friendly copy leads; the raw string is one tap away.
class _TechnicalDetails extends StatelessWidget {
  final String rawError;
  final bool expanded;
  final VoidCallback onToggle;
  final SkotiqColors colors;

  const _TechnicalDetails({
    required this.rawError,
    required this.expanded,
    required this.onToggle,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The tap lived on a bare gesture wrapper, which publishes an action
          // and no role, so assistive tech read a live control as an inert
          // disabled panel. The flags are only published when given.
          Semantics(
              button: true,
              enabled: true,
              expanded: expanded,
              child: InkWell(
                onTap: onToggle,
                borderRadius: expanded
                    ? const BorderRadius.vertical(
                        top: Radius.circular(SkotiqTokens.radiusMd),
                      )
                    : SkotiqTokens.borderRadiusMd,
                child: Padding(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.terminal,
                        size: SkotiqTokens.iconSm,
                        color: colors.textMuted,
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      Expanded(
                        child: Text(
                          'Technical details',
                          style: SkotiqTypography.label.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      Icon(
                        expanded
                            ? LucideIcons.chevronUp
                            : LucideIcons.chevronDown,
                        size: SkotiqTokens.iconSm,
                        color: colors.textMuted,
                      ),
                    ],
                  ),
                ),
              )),
          if (expanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceMd,
                0,
                SkotiqTokens.spaceMd,
                SkotiqTokens.spaceMd,
              ),
              child: SelectableText(
                rawError,
                style: SkotiqTypography.monoSm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
