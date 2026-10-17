part of '../focus_model_curve_card.dart';

class _ActionRow extends ConsumerStatefulWidget {
  final String profileId;
  final FocuserState focuserState;
  final SkotiqColors colors;
  final VoidCallback onChanged;

  const _ActionRow({
    required this.profileId,
    required this.focuserState,
    required this.colors,
    required this.onChanged,
  });

  @override
  ConsumerState<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends ConsumerState<_ActionRow> {
  bool _busy = false;
  int _operationGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _operationGeneration++;
        if (mounted && _busy) setState(() => _busy = false);
      },
    );
  }

  @override
  void dispose() {
    _operationGeneration++;
    _backendSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SkotiqButton(
          label: 'Add point',
          icon: LucideIcons.plus,
          size: ButtonSize.small,
          variant: ButtonVariant.outline,
          onPressed: _busy ? null : () => _runAction('add'),
          isLoading: _busy,
        ),
        const Spacer(),
        PopupMenuButton<String>(
          enabled: !_busy,
          tooltip: 'More',
          icon: Icon(
            LucideIcons.moreHorizontal,
            color: widget.colors.textSecondary,
          ),
          onSelected: _runAction,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'export', child: Text('Export JSON')),
            PopupMenuItem(value: 'import', child: Text('Import JSON')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'clear', child: Text('Clear model')),
          ],
        ),
      ],
    );
  }

  Future<void> _runAction(String action) async {
    if (_busy) return;
    final backend = ref.read(backendProvider);
    final generation = ++_operationGeneration;
    setState(() => _busy = true);

    try {
      switch (action) {
        case 'add':
          await _addPoint(backend, generation);
        case 'export':
          await _exportData(backend, generation);
        case 'import':
          await _importData(backend, generation);
        case 'clear':
          await _clearData(backend, generation);
      }
    } catch (error) {
      if (_isCurrent(backend, generation)) {
        _showMessage('Focus model action failed: $error');
      }
    } finally {
      if (_isCurrent(backend, generation)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _addPoint(
    SkotiqBackend backend,
    int generation,
  ) async {
    final focuserState = ref.read(focuserStateProvider);
    final filterWheel = ref.read(filterWheelStateProvider);
    final draft = await showDialog<_FocusPointDraft>(
      context: context,
      builder: (_) => _AddFocusPointDialog(
        initialPosition: focuserState.position,
        initialTemperature: focuserState.temperature,
        filterNames: filterWheel.filterNames,
        initialFilter: filterWheel.currentFilterName,
      ),
    );
    if (draft == null || !_ensureCurrent(backend, generation)) return;

    if (backend is NetworkBackend) {
      await backend.addFocusDataPoint(
        temperature: draft.temperature,
        position: draft.position,
        hfr: draft.hfr,
        filter: draft.filter,
      );
    } else {
      await ref.read(focusModelServiceProvider).addDataPoint(
            profileId: widget.profileId,
            temperatureCelsius: draft.temperature,
            focusPosition: draft.position,
            hfr: draft.hfr,
            filterName: draft.filter,
          );
    }
    await _refreshAfterMutation(backend, generation);
    if (_isCurrent(backend, generation)) _showMessage('Focus point added');
  }

  Future<void> _exportData(
    SkotiqBackend backend,
    int generation,
  ) async {
    final exported = backend is NetworkBackend
        ? const JsonEncoder.withIndent('  ')
            .convert(await backend.exportFocusModel())
        : ref.read(focusModelServiceProvider).exportData(widget.profileId);
    if (!_ensureCurrent(backend, generation)) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export focus data'),
        content: SingleChildScrollView(child: SelectableText(exported)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _importData(
    SkotiqBackend backend,
    int generation,
  ) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _FocusImportDialog(),
    );
    if (data == null || !_ensureCurrent(backend, generation)) return;

    if (backend is NetworkBackend) {
      await backend.importFocusModel(data);
    } else {
      await ref
          .read(focusModelServiceProvider)
          .importData(widget.profileId, jsonEncode(data));
    }
    await _refreshAfterMutation(backend, generation);
    if (_isCurrent(backend, generation)) _showMessage('Focus data imported');
  }

  Future<void> _clearData(
    SkotiqBackend backend,
    int generation,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear focus model?'),
        content: const Text(
          'This deletes all collected focus data points and the fitted model. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm != true || !_ensureCurrent(backend, generation)) return;

    if (backend is NetworkBackend) {
      await backend.clearFocusModelData();
    } else {
      await ref
          .read(focusModelServiceProvider)
          .clearProfileData(widget.profileId);
    }
    await _refreshAfterMutation(backend, generation);
    if (_isCurrent(backend, generation)) _showMessage('Focus model cleared');
  }

  Future<void> _refreshAfterMutation(
    SkotiqBackend backend,
    int generation,
  ) async {
    if (!_isCurrent(backend, generation)) return;
    ref.invalidate(focusProfileDataProvider(widget.profileId));
    if (backend is! NetworkBackend) widget.onChanged();
    await ref.read(filterOffsetProvider.notifier).reload();
  }

  bool _ensureCurrent(SkotiqBackend backend, int generation) {
    if (_isCurrent(backend, generation)) return true;
    if (mounted) {
      _showMessage('The imaging host changed. Focus action cancelled.');
    }
    return false;
  }

  bool _isCurrent(SkotiqBackend backend, int generation) {
    return mounted &&
        generation == _operationGeneration &&
        identical(ref.read(backendProvider), backend);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _FocusPointDraft {
  final int position;
  final double hfr;
  final double temperature;
  final String? filter;

  const _FocusPointDraft({
    required this.position,
    required this.hfr,
    required this.temperature,
    required this.filter,
  });
}

class _AddFocusPointDialog extends StatefulWidget {
  final int? initialPosition;
  final double? initialTemperature;
  final List<String> filterNames;
  final String? initialFilter;

  const _AddFocusPointDialog({
    required this.initialPosition,
    required this.initialTemperature,
    required this.filterNames,
    required this.initialFilter,
  });

  @override
  State<_AddFocusPointDialog> createState() => _AddFocusPointDialogState();
}

class _AddFocusPointDialogState extends State<_AddFocusPointDialog> {
  late final TextEditingController _positionController;
  late final TextEditingController _hfrController;
  late final TextEditingController _temperatureController;
  String? _selectedFilter;
  String? _error;

  @override
  void initState() {
    super.initState();
    _positionController = TextEditingController(
      text: widget.initialPosition?.toString() ?? '',
    );
    _hfrController = TextEditingController();
    _temperatureController = TextEditingController(
      text: widget.initialTemperature?.toStringAsFixed(2) ?? '',
    );
    _selectedFilter = widget.filterNames.contains(widget.initialFilter)
        ? widget.initialFilter
        : null;
  }

  @override
  void dispose() {
    _positionController.dispose();
    _hfrController.dispose();
    _temperatureController.dispose();
    super.dispose();
  }

  void _submit() {
    final position = int.tryParse(_positionController.text.trim());
    final hfr = double.tryParse(_hfrController.text.trim());
    final temperature = double.tryParse(_temperatureController.text.trim());
    if (position == null || position < 0) {
      setState(() => _error = 'Enter a non-negative focuser position.');
      return;
    }
    if (hfr == null || !hfr.isFinite || hfr <= 0) {
      setState(() => _error = 'Enter an HFR greater than zero.');
      return;
    }
    if (temperature == null || !temperature.isFinite) {
      setState(() => _error = 'Enter a valid temperature.');
      return;
    }
    Navigator.of(context).pop(
      _FocusPointDraft(
        position: position,
        hfr: hfr,
        temperature: temperature,
        filter: _selectedFilter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add focus data point'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _positionController,
              decoration: const InputDecoration(
                labelText: 'Focuser position (steps)',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _hfrController,
              decoration: const InputDecoration(labelText: 'HFR'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _temperatureController,
              decoration: const InputDecoration(labelText: 'Temperature (°C)'),
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
            ),
            if (widget.filterNames.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selectedFilter,
                decoration: const InputDecoration(labelText: 'Filter'),
                items: widget.filterNames
                    .map((name) => DropdownMenuItem(
                          value: name,
                          child: Text(name),
                        ))
                    .toList(),
                onChanged: (value) => setState(() => _selectedFilter = value),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _FocusImportDialog extends StatefulWidget {
  const _FocusImportDialog();

  @override
  State<_FocusImportDialog> createState() => _FocusImportDialogState();
}

class _FocusImportDialogState extends State<_FocusImportDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final decoded = jsonDecode(_controller.text.trim());
      if (decoded is! Map) {
        throw const FormatException('Expected a JSON object');
      }
      Navigator.of(context).pop(Map<String, dynamic>.from(decoded));
    } catch (error) {
      setState(() => _error = 'Invalid focus-data JSON: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import focus data'),
      content: TextField(
        controller: _controller,
        maxLines: 8,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          hintText: 'Paste JSON exported from another device',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Import')),
      ],
    );
  }
}

/// Last predictive-AF consultation: decision band, predicted vs actual
/// position, and confidence. The model trains and predicts on its own, so this
/// row is the operator's only window into whether the per-filter focus model
/// trusts itself yet.
class _PredictiveAfRow extends ConsumerWidget {
  const _PredictiveAfRow({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(lastPredictiveAfStatusProvider);
    if (status == null) return const SizedBox.shrink();

    final predicted = status.decision.targetPosition;
    final confidence = status.decision.confidence;
    final error = status.predictionErrorSteps;

    final parts = <String>[
      status.filterName,
      status.decisionLabel,
      if (predicted != null) 'predicted $predicted',
      if (confidence != null) 'R² ${confidence.toStringAsFixed(2)}',
      if (status.actualPosition != null) 'actual ${status.actualPosition}',
      if (error != null) 'Δ ${error >= 0 ? '+' : ''}$error steps',
    ];

    final tone = switch (status.decision) {
      ApplyDirect() => colors.success,
      ApplyDampened() => colors.primary,
      ForceAutofocus() => colors.warning,
      InsufficientData() => colors.textMuted,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(LucideIcons.brainCircuit, size: 13, color: tone),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Predictive AF: ${parts.join(' · ')}',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
