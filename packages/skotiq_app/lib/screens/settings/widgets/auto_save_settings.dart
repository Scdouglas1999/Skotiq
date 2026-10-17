import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';
import '../../../utils/snackbar_helper.dart';

/// Auto-save configuration settings page.
class AutoSaveSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  /// When true, render without an own scroll view / header (embedded in a
  /// merged section's single outer scroll).
  final bool embedded;

  const AutoSaveSettings({
    super.key,
    this.isMobile = false,
    this.embedded = false,
  });

  @override
  ConsumerState<AutoSaveSettings> createState() => _AutoSaveSettingsState();
}

class _AutoSaveSettingsState extends ConsumerState<AutoSaveSettings> {
  // Left empty on purpose: the hydrated config is handed to each
  // [SettingsNumberInput] as its `authoritativeValue`, and the input seeds and
  // re-seeds the controller from that. Pre-filling here from the un-hydrated
  // service is what put the compiled-in defaults on screen.
  final _sequenceIntervalController = TextEditingController();
  final _backupIntervalController = TextEditingController();
  final _maxBackupsController = TextEditingController();
  bool _isSavingNow = false;

  @override
  void dispose() {
    _sequenceIntervalController.dispose();
    _backupIntervalController.dispose();
    _maxBackupsController.dispose();
    super.dispose();
  }

  Future<void> _updateConfig(
    AutoSaveService service, {
    Duration? sequenceInterval,
    bool? sequenceEnabled,
    Duration? backupInterval,
    bool? backupEnabled,
    int? maxBackups,
  }) async {
    // [service] is the instance `autoSaveLifecycleProvider` hydrated, so
    // `config` here is what is on disk. Taking it from the raw
    // `autoSaveServiceProvider` instead meant copyWith started from the
    // compiled-in defaults, and `_persistAutoSaveConfig` — which rewrites all
    // five `autosave.*` keys — then wrote those defaults over the operator's
    // saved values: changing the backup interval silently turned sequence
    // auto-save back off and reset the retention count.
    final newConfig = service.config.copyWith(
      sequenceInterval: sequenceInterval,
      sequenceEnabled: sequenceEnabled,
      backupInterval: backupInterval,
      backupEnabled: backupEnabled,
      maxBackups: maxBackups,
    );
    try {
      await service.updateConfig(newConfig);
      if (mounted) setState(() {});
    } catch (error) {
      // updateConfig persists before restarting timers. A timer-restart error
      // can therefore occur after the new object has become authoritative;
      // only ask the shared control to roll back when the service rejected the
      // configuration itself.
      final wasApplied = identical(service.config, newConfig);
      if (mounted) {
        setState(() {});
        context.showErrorSnackBar(
          wasApplied
              ? 'Backup schedule saved, but the auto-save service reported: '
                  '$error'
              : 'Could not save backup schedule: $error',
        );
      }
      if (!wasApplied) rethrow;
    }
  }

  Future<void> _saveNow(AutoSaveService service) async {
    setState(() => _isSavingNow = true);
    try {
      final result = await service.backupNow();
      if (!result.success) {
        throw StateError(result.errorMessage ?? 'Backup failed');
      }
      if (mounted) context.showSuccessSnackBar('Backup created successfully');
    } catch (error) {
      if (mounted) context.showErrorSnackBar('Backup failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isSavingNow = false);
      }
    }
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatNextSave(DateTime? lastSave, Duration interval) {
    if (lastSave == null) return 'Pending';
    final next = lastSave.add(interval);
    final now = DateTime.now();
    if (next.isBefore(now)) return 'Imminent';
    final diff = next.difference(now);
    if (diff.inSeconds < 60) return 'In ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'In ${diff.inMinutes}m';
    return 'In ${diff.inHours}h';
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.isMobile;
    // The client ROLE, not the live connection. `main.dart` starts
    // `autoSaveLifecycleProvider` only when `remoteTarget == null`, so a
    // desktop launched with `--remote-host` never schedules backups at all —
    // yet on the connection-shaped gate this page rendered the full editor for
    // the whole pre-handshake window and after every drop, writing `autosave.*`
    // into the client's own database and starting, from the settings screen, a
    // service the entry point deliberately declined to start for this role.
    final isRemoteClient = ref.watch(isRemoteClientProvider);

    if (isRemoteClient) {
      return SettingsPage(
        title: 'Automatic backups',
        description: 'Backups run on the imaging host',
        isMobile: isMobile,
        hideHeader: isMobile || widget.embedded,
        scrollable: !widget.embedded,
        children: [
          SettingsSection(
            title: 'Host-owned setting',
            isMobile: isMobile,
            children: [
              SettingRow(
                icon: LucideIcons.server,
                title: 'Configure on the host',
                subtitle:
                    'Automatic backup scheduling is stored and executed on '
                    'the computer connected to your equipment.',
                trailing: const SizedBox.shrink(),
                isLast: true,
                isMobile: isMobile,
              ),
            ],
          ),
        ],
      );
    }

    // Depend on the LIFECYCLE provider, not the raw service. Only the
    // lifecycle provider loads the persisted `autosave.*` keys and calls
    // `start(config, lastBackup)`; the raw `autoSaveServiceProvider` hands back
    // whatever instance the last backend swap built, whose config is the
    // compiled-in defaults and whose status says the machine has never been
    // backed up. Rendering that instance is what made this page contradict
    // Settings > Backup & Restore on the same second.
    return ref.watch(autoSaveLifecycleProvider).when(
          loading: () => SettingsLoadingState(
            isMobile: isMobile,
            scrollable: !widget.embedded,
          ),
          error: (error, stackTrace) => SettingsErrorState(
            isMobile: isMobile,
            error: error,
            onRetry: () => ref.invalidate(autoSaveLifecycleProvider),
          ),
          data: (service) => _buildConfigured(context, service),
        );
  }

  Widget _buildConfigured(BuildContext context, AutoSaveService service) {
    final colors = SkotiqColors.of(context);
    final isMobile = widget.isMobile;
    final config = service.config;
    // `autoSaveStatusProvider` backfills `lastBackup` from the persisted
    // `autosave.last_backup_at` whenever the live instance does not know it —
    // the same source Backup & Restore reads, so the two surfaces cannot
    // disagree. Until its first event arrives, the hydrated service's own
    // status is already truthful.
    final status =
        ref.watch(autoSaveStatusProvider).valueOrNull ?? service.status;

    return SettingsPage(
      title: 'Automatic backups',
      description: 'Schedule recurring backups of Skotiq data',
      isMobile: isMobile,
      hideHeader: isMobile || widget.embedded,
      scrollable: !widget.embedded,
      children: [
        SettingsSection(
          title: 'Sequence auto-save',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.fileCheck,
              title: 'Enable sequence auto-save',
              subtitle: 'Persist local sequence edits in the background',
              trailing: SettingsSwitch(
                value: config.sequenceEnabled,
                onChanged: (value) =>
                    _updateConfig(service, sequenceEnabled: value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.clock,
              title: 'Sequence save interval',
              subtitle: 'How often to save pending sequence edits',
              trailing: SettingsNumberInput(
                controller: _sequenceIntervalController,
                // The persisted config is the authority for these fields; the
                // input seeds itself from it and re-seeds when the service
                // instance changes, so the box can never show a default the
                // host is not actually running.
                authoritativeValue:
                    config.sequenceInterval.inMinutes.toDouble(),
                authorityKey: service,
                suffix: 'min',
                min: 1,
                max: 60,
                decimals: 0,
                onChanged: (value) => _updateConfig(
                  service,
                  sequenceInterval: Duration(minutes: value.round()),
                ),
                isMobile: isMobile,
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),

        // Backup section
        SettingsSection(
          title: 'Automatic backups',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.hardDrive,
              title: 'Enable automatic backups',
              subtitle: 'Periodically create full database backups',
              trailing: SettingsSwitch(
                value: config.backupEnabled,
                onChanged: (value) =>
                    _updateConfig(service, backupEnabled: value),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.clock,
              title: 'Backup interval',
              subtitle: 'How often to create backups (hours)',
              trailing: SettingsNumberInput(
                controller: _backupIntervalController,
                authoritativeValue: config.backupInterval.inHours.toDouble(),
                authorityKey: service,
                suffix: 'hrs',
                min: 1,
                max: 168,
                decimals: 0,
                onChanged: (value) => _updateConfig(
                  service,
                  backupInterval: Duration(hours: value.round()),
                ),
                isMobile: isMobile,
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.archive,
              title: 'Maximum backups',
              subtitle: 'Number of auto-save backups to retain',
              trailing: SettingsNumberInput(
                controller: _maxBackupsController,
                authoritativeValue: config.maxBackups.toDouble(),
                authorityKey: service,
                suffix: '',
                min: 1,
                max: 50,
                decimals: 0,
                onChanged: (value) => _updateConfig(
                  service,
                  maxBackups: value.round(),
                ),
                isMobile: isMobile,
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),

        // Status section
        SettingsSection(
          title: 'Status',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.checkCircle,
              title: 'Last backup',
              subtitle: _formatDateTime(status.lastBackup),
              trailing: status.isBackingUp
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    )
                  : Text(
                      _formatNextSave(
                        status.lastBackup,
                        config.backupInterval,
                      ),
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
              isMobile: isMobile,
            ),
            if (status.lastError != null)
              SettingRow(
                icon: LucideIcons.alertTriangle,
                iconColor: colors.error,
                title: 'Last error',
                subtitle: status.lastError,
                trailing: const SizedBox.shrink(),
                isMobile: isMobile,
              ),
            // Save Now button row
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 12.0 : 16.0,
                vertical: isMobile ? 12.0 : 14.0,
              ),
              child: Row(
                children: [
                  SkotiqButton(
                    label: 'Back Up Now',
                    icon: LucideIcons.save,
                    size: isMobile ? ButtonSize.small : ButtonSize.medium,
                    isLoading: _isSavingNow,
                    onPressed: _isSavingNow ? null : () => _saveNow(service),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Creates a full backup immediately',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
