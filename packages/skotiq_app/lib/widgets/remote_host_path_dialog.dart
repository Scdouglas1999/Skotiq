import 'package:flutter/material.dart';

/// Prompt for a filesystem path on the connected imaging host.
///
/// Remote clients cannot use [file_selector] for host FITS/master frames;
/// this dialog collects a host path string instead.
class RemoteHostPathDialog extends StatefulWidget {
  final String title;
  final String initialPath;
  final String hintText;
  final String description;
  final String submitLabel;
  final String? clearLabel;

  const RemoteHostPathDialog({
    super.key,
    required this.title,
    required this.initialPath,
    required this.hintText,
    required this.description,
    required this.submitLabel,
    this.clearLabel,
  });

  static Future<String?> show(
    BuildContext context, {
    required String title,
    String? initialPath,
    String? hintText,
    String description = 'Enter a path on the imaging computer. Paths on this '
        'controlling device are not visible to the host.',
    String submitLabel = 'Use path',
    String? clearLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => RemoteHostPathDialog(
        title: title,
        initialPath: initialPath ?? '',
        hintText: hintText ?? r'C:\Captures\master_flat.fits',
        description: description,
        submitLabel: submitLabel,
        clearLabel: clearLabel,
      ),
    );
  }

  @override
  State<RemoteHostPathDialog> createState() => _RemoteHostPathDialogState();
}

class _RemoteHostPathDialogState extends State<RemoteHostPathDialog> {
  late final TextEditingController _controller;
  late bool _canSubmit;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPath);
    _canSubmit = widget.initialPath.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final path = _controller.text.trim();
    if (path.isNotEmpty) Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.description),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('remote_host_path_input'),
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Path on imaging host',
                hintText: widget.hintText,
              ),
              onChanged: (value) => setState(
                () => _canSubmit = value.trim().isNotEmpty,
              ),
              onSubmitted: _canSubmit ? (_) => _submit() : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.clearLabel != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: Text(widget.clearLabel!),
          ),
        FilledButton(
          key: const ValueKey('remote_host_path_submit'),
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
