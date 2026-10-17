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
    final dialog = AlertDialog(
      backgroundColor: c.surface,
      title: Text(
        widget.category.label,
        style: SkotiqTypography.buttonLg.copyWith(
          color: c.textPrimary,
        ),
      ),
      content: SizedBox(
        width: dialogMaxWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkotiqSwitch(
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                  const SizedBox(width: 8),
                  Text('Rule enabled',
                      style: SkotiqTypography.body.copyWith(
                        color: c.textPrimary,
                      )),
                ],
              ),
              const SizedBox(height: 12),
              Text('Transports',
                  style: SkotiqTypography.body.copyWith(
                    color: c.textSecondary,
                  )),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: NotificationTransportKind.values.map((t) {
                  final selected = _selectedTransports.contains(t);
                  return FilterChip(
                    label:
                        Text(_transportLabel(t, widget.configuredTransports)),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedTransports.add(t);
                      } else {
                        _selectedTransports.remove(t);
                      }
                    }),
                  );
                }).toList(),
              ),
              if (_selectedTransports.isEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'No transports selected — defaulting to in-app only.',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: c.textMuted,
                  ),
                ),
              ],
              if (_unconfiguredSelection.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${_unconfiguredSelection.map((t) => t.label).join(', ')} '
                  '${_unconfiguredSelection.length == 1 ? 'is' : 'are'} not '
                  'configured, so this rule will not reach you there. Set the '
                  'credentials up under Transports below.',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: c.warning,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text('Minimum severity',
                  style: SkotiqTypography.body.copyWith(
                    color: c.textSecondary,
                  )),
              const SizedBox(height: 6),
              AccessibleDropdown<EventSeverity>(
                value: _minSeverity,
                isDense: true,
                items: EventSeverity.values
                    .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s.name),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _minSeverity = v);
                },
              ),
              const SizedBox(height: 12),
              _numericField(
                label: 'Max per hour (0 = unlimited)',
                controller: _maxPerHourController,
              ),
              const SizedBox(height: 12),
              _numericField(
                label: 'Debounce seconds (0 = none)',
                controller: _debounceController,
              ),
              const SizedBox(height: 12),
              Text('Title template (empty = default)',
                  style: SkotiqTypography.body.copyWith(
                    color: c.textSecondary,
                  )),
              const SizedBox(height: 6),
              TextField(
                controller: _titleTemplateController,
                style: SkotiqTypography.body.copyWith(
                  color: c.textPrimary,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: r'e.g. ${target.name} done',
                ),
              ),
              const SizedBox(height: 12),
              Text('Body template (empty = default)',
                  style: SkotiqTypography.body.copyWith(
                    color: c.textSecondary,
                  )),
              const SizedBox(height: 6),
              TextField(
                controller: _bodyTemplateController,
                maxLines: 3,
                style: SkotiqTypography.body.copyWith(
                  color: c.textPrimary,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: r'e.g. Finished ${target.name} at ${time.local}',
                ),
              ),
              const SizedBox(height: 6),
              Text('Live preview:',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: c.textMuted,
                  )),
              const SizedBox(height: 4),
              Text(
                _previewBody(),
                style: SkotiqTypography.caption.copyWith(
                  color: c.textPrimary,
                  fontStyle: FontStyle.italic,
                ),
              ),
              if (_validationError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _validationError!,
                  style: SkotiqTypography.caption.copyWith(
                    color: c.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  final maxPerHour = _parseNonNegativeIntField(
                    _maxPerHourController.text,
                    label: 'Max per hour',
                  );
                  if (maxPerHour.error != null) {
                    setState(() => _validationError = maxPerHour.error);
                    return;
                  }
                  final debounce = _parseNonNegativeIntField(
                    _debounceController.text,
                    label: 'Debounce seconds',
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
                    if (context.mounted) Navigator.of(context).pop();
                  } catch (_) {
                    if (mounted) {
                      setState(() {
                        _saving = false;
                        _validationError =
                            'Could not save this routing rule. Please try again.';
                      });
                    }
                  }
                },
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
    return PopScope(canPop: !_saving, child: dialog);
  }

  Widget _numericField(
      {required String label, required TextEditingController controller}) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: SkotiqTypography.body.copyWith(
                color: SkotiqColors.of(context).textSecondary,
              )),
        ),
        SizedBox(
          width: 80,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            style: SkotiqTypography.body.copyWith(
              color: SkotiqColors.of(context).textPrimary,
            ),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
      ],
    );
  }

  String _previewBody() {
    final tpl = _bodyTemplateController.text.trim();
    if (tpl.isEmpty) return '(default template)';
    return previewInterpolation(tpl);
  }
}

// Per-transport configuration + test send sections
