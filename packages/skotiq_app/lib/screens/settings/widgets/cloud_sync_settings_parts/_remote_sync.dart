// Remote cloud-sync card, status row and remote browser dialog.
part of '../cloud_sync_settings.dart';

/// Read-only configuration summary plus Push Now for a remote controller.
///
/// Cloud credentials and restores stay on the imaging host. This card uses the
/// host's dedicated sync endpoints and never constructs a phone-local
/// [SyncService], which would otherwise report an empty database and upload the
/// wrong machine's configuration.
class RemoteCloudSyncCard extends ConsumerStatefulWidget {
  const RemoteCloudSyncCard({super.key});

  @override
  ConsumerState<RemoteCloudSyncCard> createState() =>
      _RemoteCloudSyncCardState();
}

class _RemoteCloudSyncCardState extends ConsumerState<RemoteCloudSyncCard> {
  SyncStatus? _status;
  bool _loading = true;
  bool _pushing = false;
  String? _error;
  int _loadGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _load(authorityChanged: true);
      },
    );
    _load();
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _load({bool authorityChanged = false}) async {
    final generation = ++_loadGeneration;
    final backend = ref.read(backendProvider);
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        if (authorityChanged) {
          _status = null;
          _pushing = false;
        }
      });
    }
    try {
      if (backend is! NetworkBackend) {
        throw StateError('The imaging host is not connected.');
      }
      final status = await backend.getCloudSyncStatus();
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (e) {
      // The banner tells the operator the status is unavailable; the cause is
      // only in the log, and cloud backup is exactly the thing that fails
      // quietly for weeks before anyone notices.
      developer.log(
        'Could not load cloud sync status from the imaging host: $e',
        name: 'CloudSyncSettings',
        level: 900,
      );
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Could not load cloud sync status from the imaging host.';
      });
    }
  }

  Future<void> _pushNow() async {
    if (_pushing) return;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      setState(() => _error = 'The imaging host is not connected.');
      return;
    }
    setState(() {
      _pushing = true;
      _error = null;
    });
    try {
      final result = await backend.pushCloudSyncNow();
      if (!mounted || !identical(ref.read(backendProvider), backend)) return;
      if (!result.success) {
        setState(() {
          _error = result.errorMessage ??
              'The imaging host reported that its cloud backup failed.';
        });
        return;
      }
      context.showSuccessSnackBar(
        'Host backup pushed to ${result.remotePath ?? 'cloud storage'}',
      );
      await _load();
    } catch (e) {
      // The panel says the push failed; without this line the reason is lost,
      // and a backup that never lands is only discovered when it is needed.
      developer.log(
        'Cloud backup push to the imaging host failed: $e',
        name: 'CloudSyncSettings',
        level: 1000,
      );
      if (!mounted || !identical(ref.read(backendProvider), backend)) return;
      setState(() {
        _error = 'The imaging host could not push its cloud backup. Check the '
            'host sync configuration and try again.';
      });
    } finally {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        setState(() => _pushing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final status = _status;
    return Card(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.cloud, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  'Backup & Sync (imaging host)',
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Pushes the imaging host’s configuration bundle. Provider and '
              'credentials are edited on the desktop host so secrets never '
              'cross to this controller.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                  child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36))
            else if (_error != null && status == null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_error!,
                      style: SkotiqTypography.body.copyWith(
                        color: colors.error,
                      )),
                  const SizedBox(height: 12),
                  SkotiqButton(
                    label: 'Retry',
                    icon: LucideIcons.refreshCw,
                    variant: ButtonVariant.secondary,
                    onPressed: _load,
                  ),
                ],
              )
            else if (status != null) ...[
              _RemoteSyncStatusRow(
                label: 'Status',
                value: status.configured ? 'Configured' : 'Not configured',
                valueColor: status.configured ? colors.success : colors.warning,
              ),
              const SizedBox(height: 10),
              _RemoteSyncStatusRow(
                label: 'Machine',
                value: status.machineName.isEmpty ? '—' : status.machineName,
              ),
              if (status.serverUrl.isNotEmpty) ...[
                const SizedBox(height: 10),
                _RemoteSyncStatusRow(
                  label: 'Destination',
                  value: status.serverUrl,
                ),
              ],
              const SizedBox(height: 10),
              _RemoteSyncStatusRow(
                label: 'Automatic push',
                value: status.autoPushEnabled ? 'Enabled' : 'Disabled',
              ),
              const SizedBox(height: 10),
              _RemoteSyncStatusRow(
                label: 'Last push',
                value: status.lastPushAt == null
                    ? 'Never'
                    : DateFormat('MMM d, yyyy HH:mm')
                        .format(status.lastPushAt!.toLocal()),
              ),
              if (status.lastError != null || _error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error ?? 'Last host error: ${status.lastError}',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
              if (!status.configured) ...[
                const SizedBox(height: 12),
                Text(
                  'Open Settings → Backup & Sync on the desktop imaging host '
                  'to choose a provider and enter its credentials.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SkotiqButton(
                    label: _pushing || status.pushInProgress
                        ? 'Pushing…'
                        : 'Push Host Backup Now',
                    icon: LucideIcons.uploadCloud,
                    variant: ButtonVariant.primary,
                    isLoading: _pushing || status.pushInProgress,
                    onPressed:
                        !status.configured || status.pushInProgress || _pushing
                            ? null
                            : _pushNow,
                  ),
                  SkotiqButton(
                    label: 'Refresh',
                    icon: LucideIcons.refreshCw,
                    variant: ButtonVariant.secondary,
                    onPressed: _pushing ? null : _load,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RemoteSyncStatusRow extends StatelessWidget {
  const _RemoteSyncStatusRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: SkotiqTypography.caption.copyWith(
              color: valueColor ?? colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Two-level browser: machines under `skotiq-sync/`, then that
/// machine's bundles (from its manifest). Returns the selected
/// `(machine, bundle)` pair; the caller runs the restore confirmation.
class _RemoteBrowserDialog extends StatefulWidget {
  const _RemoteBrowserDialog({required this.service});

  final SyncService service;

  @override
  State<_RemoteBrowserDialog> createState() => _RemoteBrowserDialogState();
}

class _RemoteBrowserDialogState extends State<_RemoteBrowserDialog> {
  bool _loading = true;
  String? _error;
  List<SyncRemoteMachine> _machines = const [];
  String? _selectedMachine;
  List<SyncBundleInfo> _bundles = const [];

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  Future<void> _loadMachines() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final machines = await widget.service.listRemoteMachines();
      if (!mounted) return;
      setState(() {
        _machines = machines;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is SyncTargetException ? e.message : e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadBundles(String machine) async {
    setState(() {
      _selectedMachine = machine;
      _loading = true;
      _error = null;
    });
    try {
      final bundles = await widget.service.listRemoteBundles(machine);
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is SyncTargetException ? e.message : e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final machine = _selectedMachine;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Row(
        children: [
          if (machine != null)
            SkotiqIconButton(
              icon: LucideIcons.arrowLeft,
              tooltip: 'Back to machines',
              onPressed: () => setState(() {
                _selectedMachine = null;
                _bundles = const [];
              }),
              size: IconButtonSize.md,
            ),
          Expanded(
            child: Text(
              machine == null ? 'Remote Backups' : 'Backups from "$machine"',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 320,
        child: _buildBody(colors),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildBody(SkotiqColors colors) {
    if (_loading) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.cloudOff, size: 40, color: colors.error),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: SkotiqTypography.body.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }
    final machine = _selectedMachine;
    if (machine == null) {
      if (_machines.isEmpty) {
        return Center(
          child: Text(
            'No machines have pushed backups yet.',
            style: SkotiqTypography.body.copyWith(
              color: colors.textSecondary,
            ),
          ),
        );
      }
      return ListView.builder(
        itemCount: _machines.length,
        itemBuilder: (context, index) {
          final m = _machines[index];
          return ListTile(
            leading: Icon(LucideIcons.monitor, color: colors.primary),
            title: Text(m.name,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textPrimary,
                )),
            trailing: const Icon(LucideIcons.chevronRight, size: 16),
            onTap: () => _loadBundles(m.name),
          );
        },
      );
    }
    if (_bundles.isEmpty) {
      return Center(
        child: Text(
          'No bundles found for "$machine".',
          style: SkotiqTypography.body.copyWith(
            color: colors.textSecondary,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _bundles.length,
      itemBuilder: (context, index) {
        final bundle = _bundles[index];
        final sizeKb = (bundle.sizeBytes / 1024).toStringAsFixed(1);
        return ListTile(
          leading: Icon(LucideIcons.archive, color: colors.primary),
          title: Text(
            bundle.file,
            style: SkotiqTypography.body.copyWith(
              color: colors.textPrimary,
            ),
          ),
          subtitle: Text(
            '$sizeKb KB | '
            '${DateFormat('MMM d, yyyy HH:mm').format(bundle.createdAt.toLocal())}'
            '${bundle.sha256.isEmpty ? ' | no integrity hash' : ''}',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          trailing: TextButton(
            onPressed: () => Navigator.of(context).pop((machine, bundle)),
            child: const Text('Restore'),
          ),
        );
      },
    );
  }
}
