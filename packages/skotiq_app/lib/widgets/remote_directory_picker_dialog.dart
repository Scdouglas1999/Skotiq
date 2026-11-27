import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
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
  /// The imaging host shows its folders only to a link with admin access.
  static const String _needsAdminAccess =
      'Only a link with admin access can browse the imaging host\'s folders. '
      'Type the folder path instead, choose it on the imaging computer, or '
      'link with admin access.';

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

  /// Browses and validations against the host. A browse superseded by a newer
  /// one (rapid folder taps), and anything that finishes after the host
  /// changed or the dialog closed, is dropped.
  late final _hostScopes = ref.backendScopes(alive: () => mounted);

  /// Last path handed to [_load], so Retry can re-issue the same browse.
  String? _lastRequestedPath;

  @override
  void initState() {
    super.initState();
    _load(widget.initialPath);
  }

  Future<void> _load(String? path) async {
    final scope = _hostScopes.beginLatest();
    _lastRequestedPath = path;

    final hostFiles = ref.read(linkedHostFilesProvider);

    if (hostFiles == null) {
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
      final listing = await hostFiles.browseRemoteDirectories(path: path);
      // A host change has already said so on screen (see build).
      if (scope.isStale) return;
      setState(() {
        _listing = listing;
        // The folder on screen is the one "Use this folder" takes; the host
        // roots are a list of places, not a folder.
        _selectedPath = listing.currentPath;
        _loading = false;
      });
    } catch (error) {
      if (scope.isStale) return;
      setState(() {
        _loading = false;
        _loadError = isAccessLevelRefusal(error)
            ? _needsAdminAccess
            : 'Could not browse host directories. '
                'Check the connection to the imaging host and try again.';
      });
    }
  }

  Future<void> _selectCurrentDirectory() async {
    if (_validating) return;
    final scope = _hostScopes.begin();
    final selectedPath = _selectedPath;
    if (selectedPath == null) {
      return;
    }
    final hostFiles = ref.read(linkedHostFilesProvider);
    if (hostFiles == null) {
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

    HostDirectoryVerdict validation;
    try {
      validation = await hostFiles.validateRemoteDirectory(
        selectedPath,
        mustExist: true,
        mustBeWritable: true,
      );
    } catch (error) {
      if (scope.isStale) return;
      setState(() {
        _validating = false;
        _validationError = isAccessLevelRefusal(error)
            ? _needsAdminAccess
            : 'Could not verify the host directory. '
                'Check the connection to the imaging host and try again.';
      });
      return;
    }

    // A path validated against a host this app no longer talks to is not
    // returned; the host change has already said so on screen.
    if (scope.isStale) return;

    if (validation.valid) {
      Navigator.of(context).pop(validation.pathOr(selectedPath));
      return;
    }

    setState(() {
      _validating = false;
      _validationError =
          validation.reason ?? 'The selected host directory is not writable.';
    });
  }

  /// Asks for a name and has the host make that folder inside the one on
  /// screen, then opens it.
  Future<void> _createFolder() async {
    final parent = _listing?.currentPath;
    final hostFiles = ref.read(linkedHostFilesProvider);
    if (parent == null || hostFiles == null || _validating) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFolderNameDialog(),
    );
    if (name == null || !mounted) return;
    final scope = _hostScopes.begin();
    // The host's own separator: a Windows host is browsed from a phone too.
    final separator =
        parent.contains('\\') && !parent.contains('/') ? '\\' : '/';
    final path =
        parent.endsWith(separator) ? '$parent$name' : '$parent$separator$name';
    setState(() {
      _validating = true;
      _validationError = null;
    });
    try {
      final result = await hostFiles.validateRemoteDirectory(
        path,
        mustExist: true,
        mustBeWritable: true,
        create: true,
      );
      if (scope.isStale) return;
      setState(() => _validating = false);
      if (result.valid) {
        await _load(result.pathOr(path));
        return;
      }
      setState(() {
        _validationError =
            result.reason ?? 'The imaging host could not create that folder.';
      });
    } catch (error) {
      if (scope.isStale) return;
      setState(() {
        _validating = false;
        _validationError = isAccessLevelRefusal(error)
            ? _needsAdminAccess
            : 'Could not create the folder. '
                'Check the connection to the imaging host and try again.';
      });
    }
  }

  /// The end of a long path: the folder's own name is the part that tells
  /// folders apart, so the shared start gives way.
  static String? _tail(String? path) {
    const max = 40;
    if (path == null || path.length <= max) return path;
    return '…${path.substring(path.length - max + 1)}';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next) || !mounted) return;
      // Drop every pending request and require an explicit retry against the
      // new host. Retaining host A's listing after reconnecting to host B
      // makes a perfectly valid path look as though it was browsed on B.
      _hostScopes.cancelAll();
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
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                constraints: const BoxConstraints(minHeight: 44),
                decoration: BoxDecoration(
                  color: colors.well,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _tail(_listing?.currentPath) ??
                            'Folders on the imaging host',
                        style: const TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_listing?.currentPath != null)
                      TextButton.icon(
                        onPressed:
                            _loading || _validating ? null : _createFolder,
                        icon: const Icon(LucideIcons.folderPlus, size: 16),
                        label: const Text('New folder'),
                      ),
                  ],
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
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: SkotiqSpinner(size: 18, color: colors.primary),
                )
              : const Text('Use this folder'),
        ),
      ],
    );
    return PopScope(canPop: !_validating, child: dialog);
  }

  Widget _buildBody(SkotiqColors colors) {
    if (_loading) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
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
            // Trying again cannot change the link's access.
            if (_loadError != _needsAdminAccess) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _load(_lastRequestedPath),
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('Retry'),
              ),
            ],
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
            dense: true,
            leading: const Icon(LucideIcons.arrowUp, size: 20),
            title: const Text('Up one folder'),
            onTap: () => _load(listing.parentPath),
          ),
        // A top-level folder has no parent the host will list; go back to
        // the list of them instead.
        if (listing.parentPath == null && listing.currentPath != null)
          ListTile(
            dense: true,
            leading: const Icon(LucideIcons.arrowUp, size: 20),
            title: const Text('All folders'),
            onTap: () => _load(null),
          ),
        Expanded(
          child: listing.directories.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                    child: Text(
                      listing.currentPath == null
                          ? 'The imaging host offers no folders to this link.'
                          : 'No folders inside this one. Use it, or make a '
                              'new folder here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: listing.directories.length,
                  itemBuilder: (context, index) {
                    final directory = listing.directories[index];
                    // A tap opens the folder, as in any file browser; the
                    // folder on screen is the one used.
                    return ListTile(
                      dense: true,
                      leading: const Icon(LucideIcons.folder, size: 20),
                      title: Text(directory.name),
                      onTap: () => _load(directory.path),
                      trailing: const Icon(LucideIcons.chevronRight, size: 18),
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
              style: TextStyle(
                  color: colors.error, fontSize: SkotiqTypography.fontSize12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the new folder's name. A name, not a path: no separators and
/// nothing that climbs out of the folder on screen.
class _NewFolderNameDialog extends StatefulWidget {
  const _NewFolderNameDialog();

  @override
  State<_NewFolderNameDialog> createState() => _NewFolderNameDialogState();
}

class _NewFolderNameDialogState extends State<_NewFolderNameDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Type a name for the folder.');
      return;
    }
    if (name.contains('/') ||
        name.contains('\\') ||
        name == '.' ||
        name == '..') {
      setState(() => _error = 'A folder name cannot contain / or \\.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Folder name',
          hintText: 'Captures',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
