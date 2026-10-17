// Cloud backup/sync — "Backup & Sync" settings card.
//
// UI surface for the bundle-based cloud sync in
// skotiq_core/src/services/sync/. Configures the WebDAV target
// (server URL + username in app settings, password in the OS keyring),
// the machine name, opt-in auto-push, and exposes manual actions:
// "Push now" and "Browse remote backups → restore".
//
// CONFLICT STANCE shown to the user: sync is bundle-based, no merging —
// restoring a remote bundle replaces local configuration.

import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../accessible_dropdown.dart';

part 'cloud_sync_settings_parts/_remote_sync.dart';

class CloudSyncCard extends ConsumerStatefulWidget {
  const CloudSyncCard({super.key});

  @override
  ConsumerState<CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends ConsumerState<CloudSyncCard> {
  // WebDAV provider fields.
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  // S3-compatible provider fields. The secret key controller is the only
  // one carrying a credential — its text is routed to the keyring via the
  // SyncService.saveConfig `password` param, never echoed into settings.
  final _s3EndpointController = TextEditingController();
  final _s3RegionController = TextEditingController();
  final _s3BucketController = TextEditingController();
  final _s3AccessKeyController = TextEditingController();
  final _s3SecretController = TextEditingController();

  // Shared.
  final _machineNameController = TextEditingController();

  SyncProvider _provider = SyncProvider.webdav;

  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _pushing = false;
  bool _browsing = false;
  bool _autoPushEnabled = false;
  bool _s3PathStyle = false;
  // Tracked per provider so the "•••••••• (stored in OS keyring)" placeholder
  // is correct no matter which provider the dropdown shows.
  bool _hasStoredPassword = false;
  bool _hasStoredSecret = false;
  DateTime? _lastPushAt;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _s3EndpointController.dispose();
    _s3RegionController.dispose();
    _s3BucketController.dispose();
    _s3AccessKeyController.dispose();
    _s3SecretController.dispose();
    _machineNameController.dispose();
    super.dispose();
  }

  SyncService get _service => ref.read(syncServiceProvider);
  bool get _busy => _saving || _testing || _pushing || _browsing;

  Future<void> _load() async {
    try {
      final service = _service;
      final config = await service.loadConfig();
      // Read both providers' stored-secret flags so the keyring placeholder
      // renders correctly even after switching the dropdown.
      final hasPassword = await service.hasStoredSecret(SyncProvider.webdav);
      final hasSecret = await service.hasStoredSecret(SyncProvider.s3);
      final status = await service.status();
      if (!mounted) return;
      setState(() {
        _provider = config.provider;
        _serverUrlController.text = config.serverUrl;
        _usernameController.text = config.username;
        _s3EndpointController.text = config.s3Endpoint;
        _s3RegionController.text = config.s3Region;
        _s3BucketController.text = config.s3Bucket;
        _s3AccessKeyController.text = config.s3AccessKey;
        _s3PathStyle = config.s3PathStyle;
        _machineNameController.text = config.machineName;
        _autoPushEnabled = config.autoPushEnabled;
        _hasStoredPassword = hasPassword;
        _hasStoredSecret = hasSecret;
        _lastPushAt = status.lastPushAt;
        _lastError = status.lastError;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      context.showErrorSnackBar('Failed to load sync settings: $e');
    }
  }

  /// Inline validation mirroring [SyncConfig.isConfigured] for the active
  /// provider, plus an http/https URL check. Returns the first problem as a
  /// user-facing message, or null when the active provider is well-formed.
  /// The S3 secret key is intentionally NOT required here — a blank secret
  /// means "keep the one already in the keyring".
  String? _validationError() {
    if (_machineNameController.text.trim().isEmpty) {
      return 'Machine name is required.';
    }
    switch (_provider) {
      case SyncProvider.webdav:
        final url = _serverUrlController.text.trim();
        if (url.isEmpty) return 'Server URL is required.';
        final uri = Uri.tryParse(url);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return 'Server URL must start with http:// or https://.';
        }
      case SyncProvider.s3:
        final endpoint = _s3EndpointController.text.trim();
        if (endpoint.isEmpty) return 'S3 endpoint is required.';
        final uri = Uri.tryParse(endpoint);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return 'S3 endpoint must be a valid http:// or https:// URL.';
        }
        if (_s3RegionController.text.trim().isEmpty) {
          return 'S3 region is required.';
        }
        if (_s3BucketController.text.trim().isEmpty) {
          return 'S3 bucket is required.';
        }
        if (_s3AccessKeyController.text.trim().isEmpty) {
          return 'S3 access key is required.';
        }
    }
    return null;
  }

  Future<bool> _save({
    bool manageBusy = true,
    bool showSuccess = true,
    SyncService? through,
  }) async {
    if (manageBusy && _busy) return false;
    final validationError = _validationError();
    if (validationError != null) {
      context.showErrorSnackBar(validationError);
      return false;
    }
    if (manageBusy) setState(() => _saving = true);
    final service = through ?? _service;
    try {
      // The active provider's secret controller is the only credential.
      // Leaving it blank keeps the stored secret (password: null); typing a
      // value routes it to the keyring via SyncService, never settings.
      final secret = _provider == SyncProvider.s3
          ? _s3SecretController.text
          : _passwordController.text;
      await service.saveConfig(
        SyncConfig(
          provider: _provider,
          serverUrl: _serverUrlController.text.trim(),
          username: _usernameController.text.trim(),
          s3Endpoint: _s3EndpointController.text.trim(),
          s3Region: _s3RegionController.text.trim(),
          s3Bucket: _s3BucketController.text.trim(),
          s3AccessKey: _s3AccessKeyController.text.trim(),
          s3PathStyle: _s3PathStyle,
          machineName: _machineNameController.text.trim(),
          autoPushEnabled: _autoPushEnabled,
        ),
        password: secret.isEmpty ? null : secret,
      );
      if (!mounted || !identical(service, _service)) return false;
      setState(() {
        if (secret.isNotEmpty) {
          if (_provider == SyncProvider.s3) {
            if (_s3SecretController.text == secret) {
              _s3SecretController.clear();
            }
            _hasStoredSecret = true;
          } else {
            if (_passwordController.text == secret) {
              _passwordController.clear();
            }
            _hasStoredPassword = true;
          }
        }
      });
      if (showSuccess) context.showSuccessSnackBar('Sync settings saved');
      return true;
    } catch (e) {
      if (!mounted || !identical(service, _service)) return false;
      context.showErrorSnackBar('Failed to save sync settings: $e');
      return false;
    } finally {
      if (manageBusy && mounted && identical(service, _service)) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    final service = _service;
    setState(() => _testing = true);
    try {
      if (!await _save(
        manageBusy: false,
        showSuccess: false,
        through: service,
      )) {
        return;
      }
      await service.testConnection();
      if (!mounted || !identical(service, _service)) return;
      context.showSuccessSnackBar('Connection successful');
    } catch (e) {
      if (!mounted || !identical(service, _service)) return;
      context.showErrorSnackBar(
          'Connection failed: ${e is SyncTargetException ? e.message : e}');
    } finally {
      if (mounted && identical(service, _service)) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _pushNow() async {
    if (_busy) return;
    final service = _service;
    setState(() => _pushing = true);
    try {
      if (!await _save(
        manageBusy: false,
        showSuccess: false,
        through: service,
      )) {
        return;
      }
      final result = await service.pushNow();
      if (!mounted || !identical(service, _service)) return;
      if (result.success) {
        setState(() {
          _lastPushAt = result.timestamp;
          _lastError = null;
        });
        context.showSuccessSnackBar(
            'Pushed backup to ${result.remotePath ?? 'remote'}');
      } else {
        setState(() => _lastError = result.errorMessage);
        context.showErrorSnackBar('Push failed: ${result.errorMessage ?? '?'}');
      }
    } catch (e) {
      if (!mounted || !identical(service, _service)) return;
      setState(() => _lastError = '$e');
      context.showErrorSnackBar('Push failed: $e');
    } finally {
      if (mounted && identical(service, _service)) {
        setState(() => _pushing = false);
      }
    }
  }

  Future<void> _browseRemote() async {
    if (_busy) return;
    final service = _service;
    setState(() => _browsing = true);
    try {
      if (!await _save(
        manageBusy: false,
        showSuccess: false,
        through: service,
      )) {
        return;
      }
      if (!mounted || !identical(service, _service)) return;
      final selection = await showDialog<(String, SyncBundleInfo)>(
        context: context,
        builder: (_) => _RemoteBrowserDialog(service: service),
      );
      if (selection == null || !mounted || !identical(service, _service)) {
        return;
      }
      final (machine, bundle) = selection;

      // Same confirmation flow a local backup restore uses; copy makes the
      // bundle-based (replace, never merge) semantics explicit.
      final confirmed = await ConfirmDialog.show(
        context: context,
        title: 'Restore remote backup?',
        message: 'This restores "${bundle.file}" from machine "$machine". '
            'Sync is bundle-based: restoring replaces local configuration '
            'with the contents of this backup — nothing is merged. '
            'This action cannot be undone.',
        confirmLabel: 'Restore',
        isDestructive: true,
      );
      if (!confirmed || !mounted || !identical(service, _service)) return;

      final result = await service.pullAndRestore(
        machine: machine,
        bundleFile: bundle.file,
        replaceExisting: true,
      );
      if (!mounted || !identical(service, _service)) return;
      if (result.success) {
        context.showSuccessSnackBar(
            'Restored ${result.itemsRestored} items from $machine');
      } else {
        context.showErrorSnackBar(
            'Restore failed: ${result.errorMessage ?? 'unknown error'}');
      }
    } catch (e) {
      if (!mounted || !identical(service, _service)) return;
      context.showErrorSnackBar('Restore failed: $e');
    } finally {
      if (mounted && identical(service, _service)) {
        setState(() => _browsing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Card(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.cloud, size: 20, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Backup & Sync',
                        style: SkotiqTypography.sectionTitle
                            .copyWith(color: colors.textPrimary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Push configuration backups to a WebDAV server (Nextcloud, '
                    'ownCloud, generic WebDAV) or an S3-compatible object '
                    'store (AWS S3, MinIO, Backblaze B2) and restore them on '
                    'another machine. Sync is bundle-based: restoring replaces '
                    'local configuration — nothing is merged.',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  AccessibleDropdownFormField<SyncProvider>(
                    initialValue: _provider,
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: SyncProvider.webdav,
                        child: Text('WebDAV (Nextcloud, ownCloud)'),
                      ),
                      DropdownMenuItem(
                        value: SyncProvider.s3,
                        child: Text('S3-compatible (AWS, MinIO, Backblaze B2)'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _provider = value);
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  if (_provider == SyncProvider.webdav)
                    ..._webdavFields()
                  else
                    ..._s3Fields(),
                  const SizedBox(height: 12),
                  _field(
                    controller: _machineNameController,
                    label: 'Machine name',
                    hint: 'Identifies this machine on the server',
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Auto-push after the daily backup',
                      style: SkotiqTypography.body.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      'Uploads a fresh bundle whenever the scheduled '
                      'auto-backup completes. The newest '
                      '$kSyncDefaultRetainCount bundles are kept per machine.',
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    value: _autoPushEnabled,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _autoPushEnabled = v),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SkotiqButton(
                        label: _saving ? 'Saving...' : 'Save',
                        icon: LucideIcons.save,
                        variant: ButtonVariant.primary,
                        isLoading: _saving,
                        onPressed: _busy ? null : _save,
                      ),
                      SkotiqButton(
                        label: _testing ? 'Testing...' : 'Test Connection',
                        icon: LucideIcons.plugZap,
                        variant: ButtonVariant.secondary,
                        isLoading: _testing,
                        onPressed: _busy ? null : _testConnection,
                      ),
                      SkotiqButton(
                        label: _pushing ? 'Working...' : 'Push Now',
                        icon: LucideIcons.uploadCloud,
                        variant: ButtonVariant.secondary,
                        isLoading: _pushing,
                        onPressed: _busy ? null : _pushNow,
                      ),
                      SkotiqButton(
                        label:
                            _browsing ? 'Browsing...' : 'Browse Remote Backups',
                        icon: LucideIcons.folderSearch,
                        variant: ButtonVariant.secondary,
                        isLoading: _browsing,
                        onPressed: _busy ? null : _browseRemote,
                      ),
                    ],
                  ),
                  if (_lastPushAt != null || _lastError != null) ...[
                    const SizedBox(height: 12),
                    if (_lastPushAt != null)
                      Text(
                        'Last push: '
                        '${DateFormat('MMM d, yyyy HH:mm').format(_lastPushAt!.toLocal())}',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    if (_lastError != null)
                      Text(
                        'Last sync error: $_lastError',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.error,
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }

  /// WebDAV-specific fields: server URL + username/password. Machine name is
  /// rendered once by the shared block below the provider switch.
  List<Widget> _webdavFields() {
    return [
      _field(
        controller: _serverUrlController,
        label: 'Server URL',
        hint: 'https://cloud.example.com/remote.php/dav/files/user/',
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _field(
              controller: _usernameController,
              label: 'Username',
              hint: 'WebDAV username',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _field(
              controller: _passwordController,
              label: 'Password',
              hint: _hasStoredPassword
                  ? '•••••••• (stored in OS keyring)'
                  : 'WebDAV password / app token',
              obscure: true,
            ),
          ),
        ],
      ),
    ];
  }

  /// S3-compatible fields: endpoint, region + bucket, access key + secret
  /// key, and the path-style toggle MinIO requires. The secret key is
  /// obscured and only ever flows to the keyring via [_save].
  List<Widget> _s3Fields() {
    final colors = SkotiqColors.of(context);
    return [
      _field(
        controller: _s3EndpointController,
        label: 'Endpoint',
        hint: 'https://s3.us-east-1.amazonaws.com',
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _field(
              controller: _s3RegionController,
              label: 'Region',
              hint: 'us-east-1',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _field(
              controller: _s3BucketController,
              label: 'Bucket',
              hint: 'my-skotiq-backups',
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _field(
              controller: _s3AccessKeyController,
              label: 'Access key',
              hint: 'AKIA… / MinIO access key',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _field(
              controller: _s3SecretController,
              label: 'Secret key',
              hint: _hasStoredSecret
                  ? '•••••••• (stored in OS keyring)'
                  : 'S3 secret key',
              obscure: true,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          'Path-style addressing (required for MinIO)',
          style: SkotiqTypography.body.copyWith(
            color: colors.textPrimary,
          ),
        ),
        subtitle: Text(
          'Use <endpoint>/<bucket>/<key> instead of virtual-host style. '
          'Leave off for AWS S3; turn on for MinIO.',
          style: SkotiqTypography.caption.copyWith(
            color: colors.textSecondary,
          ),
        ),
        value: _s3PathStyle,
        onChanged: _busy ? null : (v) => setState(() => _s3PathStyle = v),
      ),
    ];
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: !_busy,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
