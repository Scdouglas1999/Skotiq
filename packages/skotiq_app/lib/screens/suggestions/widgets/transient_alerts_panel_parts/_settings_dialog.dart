// Transient settings dialog and source labels.
part of '../transient_alerts_panel.dart';

// Settings dialog

class _TransientSettingsDialog extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TransientSettingsDialog> createState() =>
      _TransientSettingsDialogState();
}

class _TransientSettingsDialogState
    extends ConsumerState<_TransientSettingsDialog> {
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the alert settings.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final settings = ref.watch(transientAlertSettingsProvider);
    final notifier = ref.read(transientAlertSettingsProvider.notifier);

    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        'Transient Alert Settings',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: SizedBox(
        width: dialogMaxWidth(context, 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sources
              Text(
                'Alert Sources',
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              ...TransientSource.values.map((source) {
                return CheckboxListTile(
                  title: Text(
                    _transientSourceLabel(source),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      color: colors.textPrimary,
                    ),
                  ),
                  subtitle: switch (source) {
                    TransientSource.tns => Text(
                        'Requires TNS bot credentials in Science settings',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textMuted,
                        ),
                      ),
                    TransientSource.manual => null,
                    // A source this build cannot poll must not present as
                    // subscribable: ticking it would look like a subscription
                    // and then report "No active alerts" from a feed nobody
                    // ever asked.
                    _ when !kFetchableTransientSources.contains(source) => Text(
                        'Not polled — this build has no live feed for it; '
                        'alerts from it can still be entered by hand',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.warning,
                        ),
                      ),
                    _ => null,
                  },
                  dense: true,
                  value: settings.enabledSources.contains(source),
                  onChanged: (_) => _run(() => notifier.toggleSource(source)),
                  controlAffinity: ListTileControlAffinity.leading,
                );
              }),

              const SizedBox(height: 16),

              // Magnitude threshold
              Text(
                'Magnitude Threshold',
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Only show objects brighter than this magnitude',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '5',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted),
                  ),
                  Expanded(
                    child: Slider(
                      value: settings.magnitudeThreshold,
                      min: 5.0,
                      max: 20.0,
                      divisions: 30,
                      label: settings.magnitudeThreshold.toStringAsFixed(1),
                      onChanged: (val) =>
                          _run(() => notifier.setMagnitudeThreshold(val)),
                    ),
                  ),
                  Text(
                    '20',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '<= ${settings.magnitudeThreshold.toStringAsFixed(1)}',
                    style: SkotiqTypography.h6.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Types to monitor
              Text(
                'Types to Monitor',
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: TransientType.values.map((type) {
                  final isEnabled = settings.typesToMonitor.contains(type);
                  // The chips are a subscription list, so they must announce
                  // on/off the way the checkboxes above them already do —
                  // assistive tech saw eight plain buttons and no way to tell,
                  // or verify after toggling, which types were monitored.
                  return MergeSemantics(
                    child: Semantics(
                      checked: isEnabled,
                      child: FilterChip(
                        label: Text(
                          TransientTypeStyle.shortLabel(type),
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: isEnabled
                                ? colors.primary
                                : colors.textSecondary,
                          ),
                        ),
                        selected: isEnabled,
                        onSelected: (_) =>
                            _run(() => notifier.toggleType(type)),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 16),

              // Notification settings
              SwitchListTile(
                title: Text(
                  'Notify on new alerts',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textPrimary,
                  ),
                ),
                dense: true,
                value: settings.notifyOnNew,
                onChanged: (val) => _run(() => notifier.setNotifyOnNew(val)),
              ),
              SwitchListTile(
                title: Text(
                  'Auto-queue bright transients',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textPrimary,
                  ),
                ),
                // Off states the BEHAVIOUR; on states the number, beside the
                // slider that owns it. Asserting a threshold while the control
                // that sets it is hidden claims an auto-queue depth that need
                // not match the Magnitude Threshold slider above.
                subtitle: Text(
                  settings.autoQueueBright
                      ? 'Automatically adds transients brighter than mag '
                          '${settings.autoQueueMagnitude.toStringAsFixed(1)} '
                          'to targets'
                      : 'Add bright new transients to your targets '
                          'automatically. Turn this on to set the cutoff.',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted),
                ),
                dense: true,
                value: settings.autoQueueBright,
                onChanged: (val) =>
                    _run(() => notifier.setAutoQueueBright(val)),
              ),
              // The threshold this switch acts on. It defaults to mag 10, which
              // is brighter than almost every transient an amateur rig can
              // reach (most TNS supernovae sit at mag 13-17), so auto-queue
              // shipped switchable but effectively inert: the number was
              // settable over the headless API and by nothing in the app.
              if (settings.autoQueueBright) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 8),
                  child: Row(
                    children: [
                      Text(
                        '5',
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textMuted),
                      ),
                      Expanded(
                        child: Slider(
                          value: settings.autoQueueMagnitude.clamp(5.0, 20.0),
                          min: 5.0,
                          max: 20.0,
                          divisions: 30,
                          label: settings.autoQueueMagnitude.toStringAsFixed(1),
                          semanticFormatterCallback: (value) =>
                              'Auto-queue magnitude ${value.toStringAsFixed(1)}',
                          onChanged: (val) =>
                              _run(() => notifier.setAutoQueueMagnitude(val)),
                        ),
                      ),
                      Text(
                        '20',
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textMuted),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '<= ${settings.autoQueueMagnitude.toStringAsFixed(1)}',
                        style: SkotiqTypography.h6.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                // An auto-queue threshold fainter than the display threshold
                // can never fire: the feed drops those alerts before
                // auto-queue ever sees them.
                if (settings.autoQueueMagnitude > settings.magnitudeThreshold)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Alerts fainter than the magnitude threshold '
                      '(${settings.magnitudeThreshold.toStringAsFixed(1)}) are '
                      'filtered out before auto-queue sees them.',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.warning),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String _transientSourceLabel(TransientSource source) {
  switch (source) {
    case TransientSource.aavso:
      return 'AAVSO (Variable Stars)';
    case TransientSource.tns:
      return 'TNS (Transient Name Server)';
    case TransientSource.mpec:
      return 'MPEC (Minor Planets)';
    case TransientSource.cbat:
      return 'CBAT (Astronomical Telegrams)';
    case TransientSource.manual:
      return 'Manual Entries';
  }
}
