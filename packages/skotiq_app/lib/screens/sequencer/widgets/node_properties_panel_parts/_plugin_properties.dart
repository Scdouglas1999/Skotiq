// Properties editor for plugin-contributed instruction nodes. Plugins own an
// opaque JSON config blob plus an optional per-node timeout. We surface both
// with a multi-line JSON editor (validated on change so a malformed blob is
// flagged rather than silently persisted) and a timeout field. Without this
// the node fell through to the "No property editor" fallback (dispatcher
// completeness).
part of '../node_properties_panel.dart';

class _PluginInstructionProperties extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final PluginInstructionNode node;

  const _PluginInstructionProperties({
    required this.colors,
    required this.node,
  });

  @override
  ConsumerState<_PluginInstructionProperties> createState() =>
      _PluginInstructionPropertiesState();
}

class _PluginInstructionPropertiesState
    extends ConsumerState<_PluginInstructionProperties> {
  late TextEditingController _configController;
  String? _jsonError;

  @override
  void initState() {
    super.initState();
    _configController = TextEditingController(text: widget.node.configJson);
  }

  @override
  void didUpdateWidget(_PluginInstructionProperties oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.node.id != widget.node.id ||
            oldWidget.node.configJson != widget.node.configJson) &&
        widget.node.configJson != _configController.text) {
      _configController.text = widget.node.configJson;
      _jsonError = null;
    }
  }

  @override
  void dispose() {
    _configController.dispose();
    super.dispose();
  }

  void _onConfigChanged(String value) {
    // Validate before persisting: a plugin config that fails jsonDecode would
    // throw at execution time, so surface the error inline instead of
    // silently storing garbage.
    try {
      final decoded = json.decode(value);
      if (decoded is! Map) {
        throw const FormatException('Configuration must be a JSON object');
      }
      setState(() => _jsonError = null);
      ref.read(currentSequenceProvider.notifier).updateNode(
            widget.node.copyWith(configJson: value),
          );
    } catch (e) {
      setState(() => _jsonError = 'Invalid JSON: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final node = widget.node;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Plugin Settings',
          style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.puzzle, size: 14, color: colors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      node.pluginName.isEmpty ? node.pluginId : node.pluginName,
                      style: SkotiqTypography.h6
                          .copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                node.nodeTypeId,
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        NodePropertyField(
          colors: colors,
          label: 'Configuration (JSON)',
          child: NodeTextInput(
            colors: colors,
            value: node.configJson,
            hint: '{}',
            maxLines: 6,
            hasError: _jsonError != null,
            onChanged: _onConfigChanged,
          ),
        ),
        if (_jsonError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _jsonError!,
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.error),
                  ),
                ),
              ],
            ),
          ),
        NodePropertyField(
          colors: colors,
          label: 'Timeout',
          child: NodeNumberInput(
            colors: colors,
            value: (node.timeoutSecs ?? 600).toDouble(),
            suffix: 's',
            min: 0,
            max: 7200,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(timeoutSecs: value.toInt()),
                  );
            },
          ),
        ),
      ],
    );
  }
}
