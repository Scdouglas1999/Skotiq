import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class RemoteDirectoryPickerDialog extends ConsumerStatefulWidget {
  final String title;
  final String? initialPath;

  const RemoteDirectoryPickerDialog({
    super.key,
    required this.title,
    this.initialPath,
  });

  static Future<String?> show(
    BuildContext context, {
    required String title,
    String? initialPath,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => RemoteDirectoryPickerDialog(
        title: title,
        initialPath: initialPath,
      ),
    );
  }

  @override
  ConsumerState<RemoteDirectoryPickerDialog> createState() =>
      _RemoteDirectoryPickerDialogState();
}

class _RemoteDirectoryPickerDialogState
    extends ConsumerState<RemoteDirectoryPickerDialog> {
  RemoteDirectoryListing? _listing;
  String? _selectedPath;

  /// Browse failure — replaces the folder list with an actionable Retry.
  String? _loadError;

  /// Validation failure (or exception) for "Use this folder" — surfaced as a
  /// banner *above* the still-visible list so the current selection and
  /// navigation are preserved and the user can pick another folder.
  String? _validationError;

  bool _loading = true;

  /// Single-flight guard for "Use this folder": a slow validation round-trip
  /// must not be re-entered by repeated taps (which would double-validate and
  /// double-pop).
  bool _validating = false;

  /// Monotonic token for browse requests. Overlapping navigations (rapid
  /// folder taps) each bump this; a slower earlier response whose token is
  /// stale is discarded instead of clobbering the latest path.
  int _loadGeneration = 0;

  /// Last path handed to [_load], so Retry can re-issue the same browse.
  String? _lastRequestedPath;

  @override
  void initState() {
    super.initState();
    _load(widget.initialPath);
  }

  Future<void> _load(String? path) async {
    final backend = ref.read(backendProvider);
    final generation = ++_loadGeneration;
    _lastRequestedPath = path;

    if (backend is! NetworkBackend) {
      setState(() {
        _loading = false;
        _loadError =
            'Remote directory browsing is only available while connected to a host.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _loadError = null;
      _validationError = null;
    });

    try {
      final listing = await backend.browseRemoteDirectories(path: path);
      // Silently discard if the dialog closed or a newer navigation superseded
      // this one — the fresher request owns the UI.
      if (!mounted || generation != _loadGeneration) return;
      // If the backend was swapped out from under us (reconnect/disconnect),
      // stale host data must not appear. Surface an actionable error rather
      // than applying it or leaving an endless spinner.
      if (!identical(ref.read(backendProvider), backend)) {
        setState(() {
          _loading = false;
          _loadError = 'The connection to the host changed. '
              'Reconnect and try again.';
        });
        return;
      }
      setState(() {
        _listing = listing;
        _selectedPath = listing.currentPath ?? path;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not browse host directories. '
            'Check the connection to the imaging host and try again.';
      });
    }
  }

  Future<void> _selectCurrentDirectory() async {
    if (_validating) return;
    final backend = ref.read(backendProvider);
    final selectedPath = _selectedPath;
    if (selectedPath == null) {
      return;
    }
    if (backend is! NetworkBackend) {
      setState(() {
        _validationError =
            'The imaging host is disconnected. Reconnect and try again.';
      });
      return;
    }

    setState(() {
      _validating = true;
      _validationError = null;
    });

    Map<String, dynamic> validation;
    try {
      validation = await backend.validateRemoteDirectory(
        selectedPath,
        mustExist: true,
        mustBeWritable: true,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _validating = false;
        _validationError = 'Could not verify the host directory. '
            'Check the connection to the imaging host and try again.';
      });
      return;
    }

    if (!mounted) return;
    // Do not pop a path validated against a host we are no longer talking to.
    if (!identical(ref.read(backendProvider), backend)) {
      setState(() {
        _validating = false;
        _validationError =
            'The connection to the host changed. Choose the folder again.';
      });
      return;
    }

    if (validation['valid'] == true) {
      final normalized = validation['normalizedPath'];
      Navigator.of(context).pop(
        normalized is String ? normalized : selectedPath,
      );
      return;
    }

    final error = validation['error'];
    setState(() {
      _validating = false;
      _validationError = error is String && error.trim().isNotEmpty
          ? error.trim()
          : 'The selected host directory is not writable.';
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next) || !mounted) return;
      // Invalidate both kinds of pending request and require an explicit retry
      // against the new host. Retaining host A's listing after reconnecting to
      // host B makes a perfectly valid path look as though it was browsed on B.
      _loadGeneration++;
      setState(() {
        _loading = false;
        _validating = false;
        _listing = null;
        _selectedPath = null;
        _validationError = null;
        _loadError = 'The connection to the host changed. '
            'Reconnect and try again.';
      });
    });

    final colors = SkotiqColors.of(context);
    final dialogSize = AdaptiveDialogConstraints.hybrid(
      context,
      designMaxWidth: ShellChromeMetrics.shareDialogPreferredWidth,
      designMaxHeight: ShellChromeMetrics.shareDialogPreferredWidth,
    );

    final dialog = AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: dialogSize.maxWidth,
        height: dialogSize.maxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_listing != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusLg),
                ),
                child: Text(
                  _listing?.currentPath ?? 'Host roots',
                  style: const TextStyle(fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (_validationError != null) ...[
              const SizedBox(height: 12),
              _ValidationBanner(message: _validationError!, colors: colors),
            ],
            const SizedBox(height: 12),
            Expanded(child: _buildBody(colors)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _validating ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading || _validating || _selectedPath == null
              ? null
              : _selectCurrentDirectory,
          child: _validating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Use this folder'),
        ),
      ],
    );
    return PopScope(canPop: !_validating, child: dialog);
  }

  Widget _buildBody(SkotiqColors colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.error),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _load(_lastRequestedPath),
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final listing = _listing;
    if (listing == null) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        if (listing.parentPath != null)
          ListTile(
            leading: const Icon(LucideIcons.arrowUp),
            title: const Text('Parent folder'),
            onTap: () => _load(listing.parentPath),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: listing.directories.length,
            itemBuilder: (context, index) {
              final directory = listing.directories[index];
              final isSelected = _selectedPath == directory.path;
              return ListTile(
                selected: isSelected,
                leading: const Icon(LucideIcons.folder),
                title: Text(directory.name),
                subtitle: Text(
                  directory.path,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  setState(() {
                    _selectedPath = directory.path;
                  });
                },
                onLongPress: () => _load(directory.path),
                trailing: IconButton(
                  icon: const Icon(LucideIcons.chevronRight),
                  onPressed: () => _load(directory.path),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  const _ValidationBanner({required this.message, required this.colors});

  final String message;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 16, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
