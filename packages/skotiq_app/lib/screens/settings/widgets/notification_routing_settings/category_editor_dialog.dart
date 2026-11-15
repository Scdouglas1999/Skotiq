part of '../notification_routing_settings.dart';

class _CategoryEditorDialog extends StatefulWidget {
  final NotificationCategory category;
  final NotificationRoutingRule rule;

  /// Transports that hold enough configuration to deliver. Anything outside
  /// this set is dropped by the router when the event fires.
  final Set<NotificationTransportKind> configuredTransports;
  final Future<void> Function(NotificationRoutingRule) onSave;

  const _CategoryEditorDialog({
    required this.category,
    required this.rule,
    required this.configuredTransports,
    required this.onSave,
  });

  @override
  State<_CategoryEditorDialog> createState() => _CategoryEditorDialogState();
}

class _CategoryEditorDialogState extends State<_CategoryEditorDialog> {
  late bool _enabled;
  late Set<NotificationTransportKind> _selectedTransports;
  late EventSeverity _minSeverity;
  late TextEditingController _maxPerHourController;
  late TextEditingController _debounceController;
  late TextEditingController _titleTemplateController;
  late TextEditingController _bodyTemplateController;
  String? _validationError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _enabled = widget.rule.enabled;
    _selectedTransports = widget.rule.transports.toSet();
    _minSeverity = widget.rule.minSeverity;
    _maxPerHourController =
        TextEditingController(text: widget.rule.maxPerHour.toString());
    _debounceController =
        TextEditingController(text: widget.rule.debounceSeconds.toString());
    _titleTemplateController =
        TextEditingController(text: widget.rule.titleTemplate ?? '');
    _bodyTemplateController =
        TextEditingController(text: widget.rule.bodyTemplate ?? '');
  }

  @override
  void dispose() {
    _maxPerHourController.dispose();
    _debounceController.dispose();
    _titleTemplateController.dispose();
    _bodyTemplateController.dispose();
    super.dispose();
  }

  /// Selected transports the router would drop for want of configuration,
  /// in the enum's display order.
  List<NotificationTransportKind> get _unconfiguredSelection =>
      NotificationTransportKind.values
          .where((t) =>
              _selectedTransports.contains(t) &&
              !widget.configuredTransports.contains(t))
          .toList();

  @override
  Widget build(BuildContext context) {
    final c = SkotiqColors.of(context);
    final unconfigured = _unconfiguredSelection;
    return PopScope(
      canPop: !_saving,
      child: SkotiqDialog(
        title: widget.category.label,
        width: SkotiqDialog.widthConfirm,
        closeEnabled: !_saving,
        onClose: () => Navigator.of(context).pop(),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
          SkotiqButton(
            label: 'Save',
            isLoading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_validationError != null) ...[
              SkotiqBanner(tone: BannerTone.error, title: _validationError!),
              const SizedBox(height: SkotiqTokens.spaceLg),
            ],
            SkotiqSwitchRow(
              label: 'Send this event',
              subtitle: 'Off, it is not sent anywhere.',
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            Text(
              'SEND TO',
              style: SkotiqTypography.eyebrow.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            for (final t in NotificationTransportKind.values)
              _TransportChoice(
                label: _transportLabel(t, widget.configuredTransports),
                selected: _selectedTransports.contains(t),
                onChanged: (v) => setState(() {
                  if (v) {
                    _selectedTransports.add(t);
                  } else {
                    _selectedTransports.remove(t);
                  }
                }),
              ),
            if (_selectedTransports.isEmpty)
              _note('Nothing picked: it shows only in the app.', c.textMuted),
            if (unconfigured.isNotEmpty)
              _note(
                '${unconfigured.map((t) => t.label).join(', ')} '
                '${unconfigured.length == 1 ? 'is' : 'are'} not set up, so '
                'this event will not reach you there. Set '
                '${unconfigured.length == 1 ? 'it' : 'them'} up on the '
                'Notifications page.',
                c.warning,
              ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            FormRow(
              label: 'Least severe',
              labelWidth: _labelWidth,
              child: SkotiqDropdown(
                value: _minSeverity.name,
                items: [for (final s in EventSeverity.values) s.name],
                itemLabels: [
                  for (final s in EventSeverity.values) _severityLabel(s),
                ],
                onChanged: (v) {
                  final picked = EventSeverity.values
                      .where((s) => s.name == v)
                      .firstOrNull;
                  if (picked != null) setState(() => _minSeverity = picked);
                },
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'At most',
              labelWidth: _labelWidth,
              help: '0 sends every one.',
              child: _numberField(_maxPerHourController, 'per hour'),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Wait',
              labelWidth: _labelWidth,
              help: 'Repeats inside this time are dropped. 0 drops none.',
              child: _numberField(_debounceController, 's'),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Title',
              labelWidth: _labelWidth,
              child: SkotiqTextField(
                controller: _titleTemplateController,
                hint: r'Default, or e.g. ${target.name} done',
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
            FormRow(
              label: 'Message',
              labelWidth: _labelWidth,
              help: 'Preview: ${_previewBody()}',
              child: SkotiqTextField(
                controller: _bodyTemplateController,
                maxLines: 3,
                hint: r'Default, or e.g. Finished ${target.name}',
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const double _labelWidth = 96;

  Widget _note(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
        child: Text(
          text,
          style: SkotiqTypography.bodySm.copyWith(color: color),
        ),
      );

  Widget _numberField(TextEditingController controller, String unit) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 120,
        child: SkotiqTextField(
          controller: controller,
          keyboardType: TextInputType.number,
          suffix: unit,
          mono: true,
        ),
      ),
    );
  }

  static String _severityLabel(EventSeverity severity) => switch (severity) {
        EventSeverity.info => 'Information',
        EventSeverity.warning => 'Warning',
        EventSeverity.error => 'Error',
        EventSeverity.critical => 'Critical',
      };

  Future<void> _save() async {
    final maxPerHour = _parseNonNegativeIntField(
      _maxPerHourController.text,
      label: 'At most per hour',
    );
    if (maxPerHour.error != null) {
      setState(() => _validationError = maxPerHour.error);
      return;
    }
    final debounce = _parseNonNegativeIntField(
      _debounceController.text,
      label: 'Wait',
    );
    if (debounce.error != null) {
      setState(() => _validationError = debounce.error);
      return;
    }
    final updated = NotificationRoutingRule(
      transports: _selectedTransports.isEmpty
          ? const [NotificationTransportKind.inApp]
          : _selectedTransports.toList(),
      minSeverity: _minSeverity,
      maxPerHour: maxPerHour.value!,
      debounceSeconds: debounce.value!,
      titleTemplate: _titleTemplateController.text.trim().isEmpty
          ? null
          : _titleTemplateController.text,
      bodyTemplate: _bodyTemplateController.text.trim().isEmpty
          ? null
          : _bodyTemplateController.text,
      enabled: _enabled,
    );
    setState(() {
      _saving = true;
      _validationError = null;
    });
    try {
      await widget.onSave(updated);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _validationError =
              'Could not save: ${userFacingError(error)}. Try again.';
        });
      }
    }
  }

  String _previewBody() {
    final tpl = _bodyTemplateController.text.trim();
    if (tpl.isEmpty) return 'the default message';
    return previewInterpolation(tpl);
  }
}

/// One place an event can be sent, as a checkbox row.
class _TransportChoice extends StatelessWidget {
  const _TransportChoice({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: SkotiqTokens.borderRadiusSm,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
          child: Row(
            children: [
              SkotiqCheckbox(
                value: selected,
                onChanged: (v) => onChanged(v ?? false),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  label,
                  style:
                      SkotiqTypography.body.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Per-transport configuration + test send sections
