part of '../delivery_settings.dart';

/// Add or edit one delivery destination.
///
/// The dialog owns three things the list row does not: the transport fields,
/// the content selection written to `content_json`, and — for SFTP — the
/// private key, which goes to the keyring and never to `config_json`.
///
/// A peer destination opens here read-only for everything pairing owns (its
/// name and peer id). Only what delivery owns is editable: whether it is on
/// and which artifact classes it receives.
class _DestinationEditorDialog extends ConsumerStatefulWidget {
  const _DestinationEditorDialog({required this.kind, this.view});

  final ArtifactDestinationKind kind;

  /// The destination being edited, or null when creating one.
  final DeliveryDestinationView? view;

  /// Open the editor for a new destination of [kind].
  static Future<void> create(
    BuildContext context,
    WidgetRef ref, {
    required ArtifactDestinationKind kind,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _DestinationEditorDialog(kind: kind),
    );
    ref.invalidate(deliveryDestinationsProvider);
  }

  /// Open the editor for an existing destination.
  static Future<void> edit(
    BuildContext context,
    WidgetRef ref, {
    required DeliveryDestinationView view,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _DestinationEditorDialog(kind: view.destination.kind, view: view),
    );
    ref.invalidate(deliveryDestinationsProvider);
  }

  @override
  ConsumerState<_DestinationEditorDialog> createState() =>
      _DestinationEditorDialogState();
}

class _DestinationEditorDialogState
    extends ConsumerState<_DestinationEditorDialog> {
  final _nameController = TextEditingController();
  final _pathController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _userController = TextEditingController();
  final _remoteDirController = TextEditingController();
  final _keyController = TextEditingController();
  final _rigIdController = TextEditingController();

  /// True once the row carries an explicit `rigId`. Kept apart from the
  /// controller's text because an empty stored value ("deliver under the bare
  /// file names") and no stored value at all ("use this host's name") are
  /// different instructions that both render as an empty field.
  bool _rigIdIsSet = false;

  /// Every key the stored config carried, so an edit here cannot drop the
  /// pinned host key or a configured free-space floor.
  Map<String, Object?> _config = <String, Object?>{};

  final Set<ArtifactContent> _content = <ArtifactContent>{};
  bool _enabled = true;
  bool _saving = false;
  bool _probing = false;
  String? _validationError;
  WatchedFolderProbe? _probe;

  /// True once a save was refused because the Name field was empty.
  ///
  /// Held apart from [_validationError] because this assertion is about ONE
  /// field, and a field-level assertion has to answer to that field: it renders
  /// as the Name field's own `errorText` — beside the box it is about rather
  /// than in the footer ~470px below it — and it clears the moment the field
  /// gains text. As a footer string it survived the typing that answered it,
  /// so the form asserted "This destination needs a name." over a Name field
  /// holding `nas`, and the next Save succeeded — proving the sentence had been
  /// stale since the first keystroke.
  bool _nameMissing = false;

  /// True once the operator asks for the stored key to be removed. Applied on
  /// save so a cancelled dialog leaves the keyring alone.
  bool _clearStoredKey = false;

  /// The row id a partially-successful create left behind, so a retry updates
  /// that row rather than creating a duplicate destination.
  int? _createdId;

  bool get _isEditing => widget.view != null;
  bool get _isPeer => widget.kind == ArtifactDestinationKind.peer;

  @override
  void initState() {
    super.initState();
    final view = widget.view;
    if (view == null) {
      _portController.text = '22';
      return;
    }
    final destination = view.destination;
    _config = decodeDestinationConfig(destination.configJson);
    _nameController.text = destination.name;
    _pathController.text = configString(_config, 'path');
    _hostController.text = configString(_config, 'host');
    final port = configInt(_config, 'port');
    _portController.text = port == null ? '22' : '$port';
    _userController.text = configString(_config, 'user');
    _remoteDirController.text = configString(_config, 'remoteDir');
    _rigIdIsSet = _config.containsKey(kDeliveryRigIdKey);
    _rigIdController.text = configString(_config, kDeliveryRigIdKey);
    _content.addAll(destination.content);
    _enabled = destination.enabled;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _remoteDirController.dispose();
    _keyController.dispose();
    _rigIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // `deliveryKindLabel` is the one place a transport is named, and it already
    // spells the acronyms the way the buttons that open this dialog do.
    // Lowercasing its answer here turned "SFTP" into "sftp", so the header read
    // "Add sftp" directly under a button labelled "Add SFTP destination".
    final title = _isEditing
        ? 'Edit ${widget.view!.destination.name}'
        : 'Add ${deliveryKindLabel(widget.kind)}';

    return SkotiqDialog(
      title: title,
      icon: deliveryKindIcon(widget.kind),
      width: 560,
      closeEnabled: !_saving,
      actions: [
        if (_isEditing && !_isPeer)
          SkotiqButton(
            label: 'Delete',
            icon: LucideIcons.trash2,
            variant: ButtonVariant.destructive,
            onPressed: _saving ? null : _delete,
          ),
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: 'Save',
          icon: LucideIcons.save,
          isLoading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkotiqTextField(
            label: 'Name',
            hint: 'nas',
            controller: _nameController,
            enabled: !_isPeer,
            errorText: _nameMissing ? 'This destination needs a name.' : null,
            onChanged: (value) {
              if (_nameMissing && value.trim().isNotEmpty) {
                setState(() => _nameMissing = false);
              }
            },
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'What the morning report calls this destination.',
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          ..._transportFields(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          ..._rigIdField(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _ContentSelector(
            selected: _content,
            onToggle: (content, selected) => setState(() {
              if (selected) {
                _content.add(content);
              } else {
                _content.remove(content);
              }
            }),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Deliver to this destination',
                    style: SkotiqTypography.label.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                SkotiqSwitch(
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ],
            ),
          ),
          if (_validationError != null) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            SkotiqInlineBanner(
              message: _validationError!,
              severity: SkotiqAlertSeverity.error,
            ),
          ],
        ],
      ),
    );
  }

  /// The rig-identity component every file delivered here is named with.
  ///
  /// Offered on all three transports because all three name what the other
  /// machine ends up holding: a watched folder and an SFTP host write the
  /// name, and a peer manifest tells the paired desktop what to write.
  List<Widget> _rigIdField(SkotiqColors colors) {
    return [
      SkotiqTextField(
        label: 'Rig name in delivered files',
        hint: _rigIdIsSet
            ? 'no prefix — the rig\'s own file names'
            : 'this computer\'s name',
        controller: _rigIdController,
        onChanged: (_) => setState(() => _rigIdIsSet = true),
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
      Text(
        'Files arrive here named "<rig>-<the file the rig wrote>". Two rigs '
        'that deliver into one folder write the same file names — job_1_'
        'report.json on both — and the second one is refused, because '
        'delivery never overwrites. Leave this empty to use this computer\'s '
        'name. Files already delivered keep the names they have.',
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textMuted,
        ),
      ),
      if (_rigIdIsSet && _rigIdController.text.trim().isEmpty) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        const SkotiqInlineBanner(
          message: 'Saving with this empty delivers under the rig\'s own file '
              'names, with nothing saying which rig wrote them. That is the '
              'setting a single-rig folder wants and the one that collides '
              'when a second rig is pointed at the same place.',
          severity: SkotiqAlertSeverity.warning,
        ),
      ],
    ];
  }

  List<Widget> _transportFields(SkotiqColors colors) {
    switch (widget.kind) {
      case ArtifactDestinationKind.watchedFolder:
        return _watchedFolderFields(colors);
      case ArtifactDestinationKind.sftp:
        return _sftpFields(colors);
      case ArtifactDestinationKind.peer:
        return _peerFields(colors);
    }
  }

  List<Widget> _watchedFolderFields(SkotiqColors colors) {
    final probe = _probe;
    return [
      SkotiqTextField(
        label: 'Folder',
        hint: '/mnt/nas/skotiq',
        controller: _pathController,
        onChanged: (_) => setState(() => _probe = null),
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
      Text(
        'Any local or already-mounted path. Delivery never creates this '
        'folder: a network share that is not mounted looks exactly like a '
        'missing one, and creating it would fill the local drive instead.',
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textMuted,
        ),
      ),
      const SizedBox(height: SkotiqTokens.spaceSm),
      Wrap(
        spacing: SkotiqTokens.spaceSm,
        runSpacing: SkotiqTokens.spaceSm,
        children: [
          SkotiqButton(
            label: 'Browse',
            icon: LucideIcons.folderOpen,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: _saving ? null : _browse,
          ),
          SkotiqButton(
            label: 'Test write access',
            icon: LucideIcons.filePlus,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: _probing,
            onPressed: _saving || _probing ? null : _runProbe,
          ),
        ],
      ),
      if (probe != null) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqInlineBanner(
          message: probe.message,
          severity: probe.writable
              ? SkotiqAlertSeverity.success
              : SkotiqAlertSeverity.warning,
        ),
      ],
    ];
  }

  List<Widget> _sftpFields(SkotiqColors colors) {
    final pinned = configString(_config, 'hostKeyFingerprint').trim();
    return [
      SkotiqTextField(
        label: 'Host',
        hint: 'office.local',
        controller: _hostController,
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      SkotiqTextField(
        label: 'Port',
        hint: '22',
        controller: _portController,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      SkotiqTextField(
        label: 'User',
        hint: 'sean',
        controller: _userController,
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      SkotiqTextField(
        label: 'Remote directory',
        hint: '/srv/astro/incoming',
        controller: _remoteDirController,
      ),
      const SizedBox(height: SkotiqTokens.spaceLg),
      SkotiqTextField(
        label: 'Private key',
        hint: _keyHint(),
        controller: _keyController,
        obscureText: true,
        maxLines: 1,
        onChanged: (_) => setState(() => _clearStoredKey = false),
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
      Text(
        'The key goes to the OS keyring, never into the profile database — '
        'that column rides export and backup. Paste a new key to replace the '
        'stored one; leave this empty to keep it. Password authentication is '
        'not offered: OpenSSH refuses to read one from a pipe, so a password '
        'destination would hang on a prompt instead of delivering.',
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textMuted,
        ),
      ),
      if (_isEditing &&
          widget.view!.secret == StoredSecretState.present &&
          !_clearStoredKey) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqButton(
          label: 'Remove stored key',
          icon: LucideIcons.keyRound,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: _saving
              ? null
              : () => setState(() {
                    _clearStoredKey = true;
                    _keyController.clear();
                  }),
        ),
      ],
      if (_clearStoredKey) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        const SkotiqInlineBanner(
          message:
              'Saving removes this destination\'s key from the keyring. SSH '
              'then has nothing to authenticate with, so nothing is sent here '
              'until a new key is pasted.',
          severity: SkotiqAlertSeverity.warning,
        ),
      ],
      if (pinned.isNotEmpty) ...[
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'Pinned host key: $pinned. Changing the host or port clears the pin, '
          'and the next delivery pins whatever the new server presents.',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    ];
  }

  List<Widget> _peerFields(SkotiqColors colors) {
    return [
      SkotiqTextField(
        label: 'Peer id',
        initialValue: configString(_config, 'peerId'),
        enabled: false,
      ),
      const SizedBox(height: SkotiqTokens.spaceXs),
      Text(
        'The rig does not upload to a peer. It publishes a manifest and the '
        'paired desktop pulls it, so the identity comes from pairing and is '
        'not editable here.',
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textMuted,
        ),
      ),
    ];
  }

  String _keyHint() {
    final view = widget.view;
    if (view == null) return 'paste the private key';
    switch (view.secret) {
      case StoredSecretState.present:
        return kDeliverySecretPlaceholder;
      case StoredSecretState.absent:
        return 'paste the private key';
      case StoredSecretState.unreadable:
        return 'the keyring could not be read';
    }
  }

  Future<void> _browse() async {
    final chosen = await getDirectoryPath(
      confirmButtonText: 'Deliver here',
      initialDirectory: _pathController.text.trim().isEmpty
          ? null
          : _pathController.text.trim(),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _pathController.text = chosen;
      _probe = null;
    });
  }

  Future<void> _runProbe() async {
    setState(() {
      _probing = true;
      _probe = null;
    });
    try {
      final result = await ref
          .read(deliverySettingsStoreProvider)
          .probeWatchedFolder(_pathController.text);
      if (!mounted) return;
      setState(() => _probe = result);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _probe = WatchedFolderProbe(
          writable: false,
          message: 'The write probe could not run: ${userFacingError(error)}',
        ),
      );
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// The transport config to store, built on top of the keys the row already
  /// carried so nothing this dialog does not render is lost.
  ({Map<String, Object?> config, String? error}) _buildConfig() {
    final config = Map<String, Object?>.from(_config);
    // Written only once the operator has touched the field. An untouched field
    // leaves the key absent, which is the instruction "name the files after
    // this computer" rather than the instruction "name them after nothing".
    if (_rigIdIsSet) {
      config[kDeliveryRigIdKey] = sanitizeRigId(_rigIdController.text);
    }
    switch (widget.kind) {
      case ArtifactDestinationKind.watchedFolder:
        final path = _pathController.text.trim();
        if (path.isEmpty) {
          return (config: config, error: 'A watched folder needs a path.');
        }
        config['path'] = path;
      case ArtifactDestinationKind.sftp:
        final host = _hostController.text.trim();
        final user = _userController.text.trim();
        final remoteDir = _remoteDirController.text.trim();
        final port = int.tryParse(_portController.text.trim());
        if (host.isEmpty) {
          return (config: config, error: 'An SFTP destination needs a host.');
        }
        if (user.isEmpty) {
          return (
            config: config,
            error: 'An SFTP destination needs the user to connect as.',
          );
        }
        if (remoteDir.isEmpty) {
          return (
            config: config,
            error: 'An SFTP destination needs a remote directory.',
          );
        }
        if (port == null || port < 1 || port > 65535) {
          return (
            config: config,
            error: 'The port must be a number between 1 and 65535.',
          );
        }
        final movedHost = configString(_config, 'host').trim() != host ||
            configInt(_config, 'port') != port;
        if (movedHost) {
          // The pin identifies one server. Carrying it to a different
          // host/port would refuse the new server's key forever, or — worse —
          // accept a different machine under the old machine's trust. Both
          // halves go: the fingerprint the operator reads, and the key itself,
          // which is what OpenSSH is handed to enforce the pin.
          config.remove('hostKeyFingerprint');
          config.remove('hostKey');
        }
        config['host'] = host;
        config['port'] = port;
        config['user'] = user;
        config['remoteDir'] = remoteDir;
      case ArtifactDestinationKind.peer:
        // Pairing owns every transport field of a peer destination.
        break;
    }
    return (config: config, error: null);
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _nameMissing = true;
        _validationError = null;
      });
      return;
    }
    final built = _buildConfig();
    final configError = built.error;
    if (configError != null) {
      setState(() {
        _nameMissing = false;
        _validationError = configError;
      });
      return;
    }

    setState(() {
      _saving = true;
      _nameMissing = false;
      _validationError = null;
    });

    final store = ref.read(deliverySettingsStoreProvider);
    final key = _keyController.text.trim();
    try {
      // The row this save writes to. On a first save of a new destination
      // there is none until `createDestination` answers; a save that got that
      // far and then failed (a locked keyring is the realistic case) leaves
      // [_createdId] set, so pressing Save again UPDATES that row instead of
      // creating a second destination pointing at the same folder.
      var id = widget.view?.destination.id ?? _createdId;
      if (id == null) {
        id = await store.createDestination(
          name: name,
          kind: widget.kind,
          configJson: jsonEncode(built.config),
          content: _content,
          enabled: _enabled,
        );
        _createdId = id;
      } else {
        await store.updateDestination(
          id,
          name: name,
          configJson: jsonEncode(built.config),
          content: _content,
          enabled: _enabled,
        );
        // Editing a destination is how an operator answers the failure that
        // is on screen — the wrong folder, a stale key, a name that collided.
        // The spent rows would otherwise stay spent, because the sweep reads
        // only `retrying` rows, and the fix would deliver nothing. They go
        // back on the queue with a fresh budget; the sweep picks them up.
        await store.requeueTerminalRows(id);
      }
      if (_clearStoredKey && key.isEmpty) {
        await store.clearSecret(id);
      } else if (key.isNotEmpty) {
        await store.storeSecret(id, key);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _validationError = 'Could not save: ${userFacingError(error)}';
      });
    }
  }

  Future<void> _delete() async {
    final view = widget.view;
    final id = view?.destination.id;
    if (view == null || id == null) return;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Delete ${view.destination.name}?',
      message:
          'The destination and its delivery journal are removed. Files already '
          'delivered there are left alone — delivery copies, it never moves.',
      confirmLabel: 'Delete',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _saving = true;
      _validationError = null;
    });
    try {
      await ref.read(deliverySettingsStoreProvider).deleteDestination(id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _validationError = 'Could not delete: ${userFacingError(error)}';
      });
    }
  }
}

/// The four artifact classes a destination can receive, mapped to the v58
/// `content_json` selection.
class _ContentSelector extends StatelessWidget {
  const _ContentSelector({required this.selected, required this.onToggle});

  final Set<ArtifactContent> selected;
  final void Function(ArtifactContent content, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What this destination receives',
          style: SkotiqTypography.label.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Nothing selected means nothing is sent here.',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        for (final entry in kArtifactContentLabels.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
            child: MergeSemantics(
              child: Row(
                children: [
                  SkotiqCheckbox(
                    value: selected.contains(entry.key),
                    onChanged: (value) => onToggle(entry.key, value == true),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
