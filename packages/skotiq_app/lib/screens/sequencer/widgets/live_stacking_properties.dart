// Properties editor for the LiveStacking node.
//
// Renders the configurable knobs (mode, stack method, broadcast port,
// path, auth token, watermark template, thumbnail size, frame cap)
// as a vertically-scrolling property sheet that matches the look of
// SmartExposureProperties / ExposureProperties.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/sequence/variable_picker.dart';
import '../../accessible_dropdown.dart';

class LiveStackingProperties extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final LiveStackingNode node;

  const LiveStackingProperties({
    super.key,
    required this.colors,
    required this.node,
  });

  @override
  ConsumerState<LiveStackingProperties> createState() =>
      _LiveStackingPropertiesState();
}

class _LiveStackingPropertiesState
    extends ConsumerState<LiveStackingProperties> {
  late TextEditingController _broadcastPathCtl;
  late TextEditingController _broadcastPortCtl;
  late TextEditingController _authTokenCtl;
  late TextEditingController _watermarkCtl;
  late TextEditingController _maxFramesCtl;
  late TextEditingController _thumbWCtl;
  late TextEditingController _thumbHCtl;

  @override
  void initState() {
    super.initState();
    _broadcastPathCtl = TextEditingController(text: widget.node.broadcastPath);
    _broadcastPortCtl =
        TextEditingController(text: widget.node.broadcastPort.toString());
    _authTokenCtl = TextEditingController(text: widget.node.authToken ?? '');
    _watermarkCtl =
        TextEditingController(text: widget.node.watermarkText ?? '');
    _maxFramesCtl =
        TextEditingController(text: widget.node.maxFramesToStack.toString());
    _thumbWCtl =
        TextEditingController(text: widget.node.thumbnailWidth.toString());
    _thumbHCtl =
        TextEditingController(text: widget.node.thumbnailHeight.toString());
  }

  @override
  void dispose() {
    _broadcastPathCtl.dispose();
    _broadcastPortCtl.dispose();
    _authTokenCtl.dispose();
    _watermarkCtl.dispose();
    _maxFramesCtl.dispose();
    _thumbWCtl.dispose();
    _thumbHCtl.dispose();
    super.dispose();
  }

  /// Wrap [field] so [commit] runs both on submit (already wired) AND when the
  /// field loses focus — otherwise tapping away from a field silently discards
  /// the edit, which is the data-loss bug this addresses.
  Widget _commitOnBlur(Widget field, VoidCallback commit) {
    return Focus(
      onFocusChange: (hasFocus) {
        if (!hasFocus) commit();
      },
      child: field,
    );
  }

  void _commitPort() {
    final p = int.tryParse(_broadcastPortCtl.text);
    if (p == null || p < 1 || p > 65535) return;
    _update((n) => n.copyWith(broadcastPort: p));
  }

  void _commitPath() {
    final trimmed = _broadcastPathCtl.text.trim().isEmpty
        ? '/broadcast'
        : _broadcastPathCtl.text.trim();
    _update((n) => n.copyWith(broadcastPath: trimmed));
  }

  void _commitAuthToken() {
    final t = _authTokenCtl.text.trim();
    if (t.isEmpty) {
      ref
          .read(currentSequenceProvider.notifier)
          .updateNode(_rebuildWithCleared(clearAuthToken: true));
    } else {
      _update((n) => n.copyWith(authToken: t));
    }
  }

  void _commitWatermark() {
    final w = _watermarkCtl.text.trim();
    if (w.isEmpty) {
      ref
          .read(currentSequenceProvider.notifier)
          .updateNode(_rebuildWithCleared(clearWatermark: true));
    } else {
      _update((n) => n.copyWith(watermarkText: w));
    }
  }

  void _commitThumbWidth() {
    final w = int.tryParse(_thumbWCtl.text);
    if (w == null || w < 64 || w > 7680) return;
    _update((n) => n.copyWith(thumbnailWidth: w));
  }

  void _commitThumbHeight() {
    final h = int.tryParse(_thumbHCtl.text);
    if (h == null || h < 64 || h > 4320) return;
    _update((n) => n.copyWith(thumbnailHeight: h));
  }

  void _commitMaxFrames() {
    final m = int.tryParse(_maxFramesCtl.text);
    if (m == null || m < 0) return;
    _update((n) => n.copyWith(maxFramesToStack: m));
  }

  void _update(LiveStackingNode Function(LiveStackingNode) mutate) {
    final mutator = ref.read(currentSequenceProvider.notifier);
    final updated = mutate(widget.node);
    mutator.updateNode(updated);
  }

  /// `LiveStackingNode.copyWith` uses plain `?? this.authToken` semantics, so a
  /// null arg means "keep current". Making the broadcast PUBLIC (clearing the
  /// token) therefore requires a fresh node. Same recipe for the watermark.
  LiveStackingNode _rebuildWithCleared({
    bool clearAuthToken = false,
    bool clearWatermark = false,
  }) {
    final n = widget.node;
    return LiveStackingNode(
      id: n.id,
      name: n.name,
      isEnabled: n.isEnabled,
      childIds: n.childIds,
      parentId: n.parentId,
      orderIndex: n.orderIndex,
      comment: n.comment,
      mode: n.mode,
      stackMethod: n.stackMethod,
      maxFramesToStack: n.maxFramesToStack,
      broadcastEnabled: n.broadcastEnabled,
      broadcastPort: n.broadcastPort,
      broadcastPath: n.broadcastPath,
      authToken: clearAuthToken ? null : n.authToken,
      watermarkText: clearWatermark ? null : n.watermarkText,
      thumbnailWidth: n.thumbnailWidth,
      thumbnailHeight: n.thumbnailHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.node;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(theme, 'Broadcast mode'),
        AccessibleDropdownFormField<LiveStackingMode>(
          initialValue: node.mode,
          items: LiveStackingMode.values
              .map((m) => DropdownMenuItem(
                    value: m,
                    child: Text(m.label),
                  ))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            _update((n) => n.copyWith(mode: v));
          },
          decoration: const InputDecoration(
            labelText: 'Mode',
            helperText:
                'Broadcast only keeps memory clean; Record also writes JPEG '
                'snapshots to disk.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Stack combine method'),
        AccessibleDropdownFormField<LiveStackingMethod>(
          initialValue: node.stackMethod,
          items: LiveStackingMethod.values
              .map((m) => DropdownMenuItem(
                    value: m,
                    child: Text(m.label),
                  ))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            _update((n) => n.copyWith(stackMethod: v));
          },
          decoration: const InputDecoration(
            labelText: 'Stack method',
            helperText:
                'Average is fastest; Median+Rej and Sigma reject outliers.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Broadcast endpoint'),
        SwitchListTile(
          value: node.broadcastEnabled,
          onChanged: (v) => _update((n) => n.copyWith(broadcastEnabled: v)),
          title: const Text('Broadcast enabled'),
          subtitle: const Text(
            'When off, the stack still builds but the public URL '
            'returns 404.',
          ),
          contentPadding: EdgeInsets.zero,
        ),
        Row(
          children: [
            Expanded(
              child: _commitOnBlur(
                TextField(
                  controller: _broadcastPortCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    helperText: 'Default 8081',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _commitPort(),
                ),
                _commitPort,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: _commitOnBlur(
                TextField(
                  controller: _broadcastPathCtl,
                  decoration: const InputDecoration(
                    labelText: 'Path',
                    helperText: 'URL prefix (e.g. /broadcast)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _commitPath(),
                ),
                _commitPath,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Access control'),
        _commitOnBlur(
          TextField(
            controller: _authTokenCtl,
            decoration: const InputDecoration(
              labelText: 'Auth token',
              helperText:
                  'Leave empty for public access. Add a token to require '
                  '?token=… on broadcast URLs.',
              border: OutlineInputBorder(),
            ),
            obscureText: false,
            onSubmitted: (_) => _commitAuthToken(),
          ),
          _commitAuthToken,
        ),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Watermark'),
        _commitOnBlur(
          TextField(
            controller: _watermarkCtl,
            decoration: InputDecoration(
              labelText: 'Watermark template',
              helperText:
                  'Variable interpolation: \${target}, \${integration.hms}, '
                  '\${frames}, \${stack.method}. Leave empty for no watermark.',
              border: const OutlineInputBorder(),
              // The helper text names four variables the operator otherwise has
              // to type from memory; this is the insert control the picker was
              // written for, and the only field in the app that interpolates a
              // user-authored template.
              //
              // The watermark speaks its OWN flat token vocabulary, not the
              // sequencer's expression language, and the renderer passes an
              // unknown token through literally — so offering the sequencer
              // catalog here would let the operator pick `${filter}` from a
              // menu and burn it verbatim into the broadcast JPEG.
              suffixIcon: VariablePickerButton(
                controller: _watermarkCtl,
                variables: watermarkVariableCatalog,
                onChanged: _commitWatermark,
              ),
            ),
            maxLines: 2,
            onSubmitted: (_) => _commitWatermark(),
          ),
          _commitWatermark,
        ),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Thumbnail size'),
        Row(
          children: [
            Expanded(
              child: _commitOnBlur(
                TextField(
                  controller: _thumbWCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Width (px)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _commitThumbWidth(),
                ),
                _commitThumbWidth,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _commitOnBlur(
                TextField(
                  controller: _thumbHCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Height (px)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _commitThumbHeight(),
                ),
                _commitThumbHeight,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionLabel(theme, 'Frame cap'),
        _commitOnBlur(
          TextField(
            controller: _maxFramesCtl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Max frames to stack',
              helperText: '0 = unlimited. Set a cap for long outreach events '
                  'to bound memory.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _commitMaxFrames(),
          ),
          _commitMaxFrames,
        ),
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0, top: 4.0),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
