import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import 'settings_widgets.dart';

/// Remote appliance update management (OTA).
///
/// Drives the headless server's `/api/system/update/*` surface so a tablet /
/// desktop operator can check for, stage, apply, and roll back appliance
/// updates without SSHing into the Pi. Only meaningful on a remote
/// (NetworkBackend) session, so the page degrades to an explanatory note
/// off-network. The local copy's own update check lives in Settings > About
/// (`_SoftwareUpdateCard`); this page has never had anything to do with it.
class UpdateSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const UpdateSettings({super.key, this.isMobile = false});

  @override
  ConsumerState<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends ConsumerState<UpdateSettings> {
  RemoteVersionInfo? _version;
  RemoteUpdateStatus? _status;
  bool _loading = false;
  bool _busy = false;
  String? _loadError;
  String? _pollError;
  Timer? _poll;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _loadGeneration = 0;
  int _backendGeneration = 0;
  int _nextStatusRequest = 0;
  int _lastAppliedStatusRequest = 0;
  int? _statusRefreshInFlightGeneration;

  NetworkBackend? get _backend {
    final b = ref.read(backendProvider);
    return b is NetworkBackend ? b : null;
  }

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _backendGeneration++;
        _loadGeneration++;
        _lastAppliedStatusRequest = 0;
        _poll?.cancel();
        _poll = null;
        setState(() {
          _version = null;
          _status = null;
          _loadError = null;
          _pollError = null;
          _loading = next is NetworkBackend;
          _busy = false;
        });
        if (next is NetworkBackend) unawaited(_refresh());
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _poll?.cancel();
    super.dispose();
  }

  bool _isInProgress(String? state) =>
      state == 'checking' ||
      state == 'downloading' ||
      state == 'verifying' ||
      state == 'cancelling' ||
      state == 'installing' ||
      state == 'applying';

  bool _isAbortable(String? state) =>
      state == 'checking' || state == 'downloading';

  Future<void> _refresh() async {
    final backend = _backend;
    final generation = ++_loadGeneration;
    if (backend == null) {
      if (!mounted) return;
      _poll?.cancel();
      _poll = null;
      setState(() {
        _version = null;
        _status = null;
        _loading = false;
        _loadError = null;
        _pollError = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      // Reserve this status request before fetching the version. Any older
      // poll that completes while this full refresh is in flight may render
      // briefly, but can never overwrite the final snapshot.
      final statusRequest = ++_nextStatusRequest;
      final version = await backend.getSystemVersion();
      final status = await backend.getUpdateStatus();
      if (!_isCurrentLoad(backend, generation)) return;
      if (statusRequest < _lastAppliedStatusRequest) return;
      _lastAppliedStatusRequest = statusRequest;
      setState(() {
        _version = version;
        _status = status;
        _loading = false;
        _pollError = null;
      });
      // Keep polling status while an operation is mid-flight so progress
      // updates without the user manually refreshing.
      if (_isInProgress(status.state)) {
        _poll ??= Timer.periodic(
          const Duration(seconds: 2),
          (_) => _refreshStatusOnly(),
        );
      } else {
        _poll?.cancel();
        _poll = null;
      }
    } catch (e) {
      if (!_isCurrentLoad(backend, generation)) return;
      // The `/api/system/update/*` + version routes are only registered when
      // the appliance has an update server configured; otherwise they 404.
      // Surface that as a clear "not enabled" note rather than a raw error.
      final msg = '$e';
      final notEnabled = (e is ServerError && e.httpStatus == 404) ||
          RegExp(r'\bHTTP 404\b').hasMatch(msg);
      setState(() {
        _loading = false;
        _loadError = notEnabled
            ? 'This rig is running a build from before over-the-air updates '
                'were wired up, so there is nothing to manage from here. '
                'Update it once by hand and these controls appear.'
            : msg;
      });
    }
  }

  bool _isCurrentLoad(NetworkBackend backend, int generation) =>
      mounted &&
      generation == _loadGeneration &&
      identical(ref.read(backendProvider), backend);

  Future<void> _refreshStatusOnly() async {
    final backend = _backend;
    if (backend == null) return;
    final backendGeneration = _backendGeneration;
    // Timer.periodic does not await its callback. Keep at most one status GET
    // in flight per connected host so a slow appliance cannot accumulate a
    // queue of overlapping requests every two seconds. A host switch advances
    // the generation, allowing the new rig to refresh immediately without the
    // old rig's late finally block clearing its gate.
    if (_statusRefreshInFlightGeneration == backendGeneration) return;
    _statusRefreshInFlightGeneration = backendGeneration;
    final request = ++_nextStatusRequest;
    try {
      final status = await backend.getUpdateStatus();
      if (!mounted ||
          backendGeneration != _backendGeneration ||
          request < _lastAppliedStatusRequest ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      _lastAppliedStatusRequest = request;
      setState(() {
        _status = status;
        _pollError = null;
      });
      if (!_isInProgress(status.state)) {
        _poll?.cancel();
        _poll = null;
      }
    } catch (e) {
      if (!mounted ||
          backendGeneration != _backendGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      // Keep the last valid snapshot, but never hide a broken monitoring
      // link: the operator needs to know progress may now be stale.
      setState(() {
        _pollError = 'Could not refresh update progress: $e';
      });
    } finally {
      if (_statusRefreshInFlightGeneration == backendGeneration) {
        _statusRefreshInFlightGeneration = null;
      }
    }
  }

  void _ensurePolling() {
    _poll ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshStatusOnly(),
    );
  }

  Future<void> _run(
    String label,
    Future<Object?> Function(NetworkBackend backend) action, {
    NetworkBackend? expectedBackend,
    String? acceptedMessage,
    String Function(Object? result)? describeResult,
  }) async {
    if (_busy) return;
    final backend = expectedBackend ?? _backend;
    if (backend == null || !identical(_backend, backend)) {
      if (mounted && expectedBackend != null) {
        context.showErrorSnackBar(
          '$label cancelled because the connected rig changed.',
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      // Keep the whole command on the backend captured at admission. A host
      // switch between tap and dispatch must never update the newly-selected
      // rig.
      final result = await action(backend);
      if (mounted && identical(ref.read(backendProvider), backend)) {
        context.showSuccessSnackBar(
          describeResult?.call(result) ??
              acceptedMessage ??
              '$label request accepted',
        );
        // The job is queued asynchronously on the host. Poll even if the
        // first snapshot still says idle so a fast admission race cannot
        // leave the page frozen until a manual refresh.
        _ensurePolling();
        unawaited(_refreshStatusOnly());
      }
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        context.showErrorSnackBar('$label failed: $e');
      }
    } finally {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmApply() async {
    final backend = _backend;
    final stagedVersion = _status?.stagedVersion ?? 'the staged update';
    if (backend == null) return;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Apply $stagedVersion?',
      message: 'The connected rig will stop accepting work and restart. '
          'Do not begin an imaging run until it reconnects on the new build.',
      confirmLabel: 'Apply and Restart',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final current = await _revalidateCommand(
      backend,
      'Apply',
      (status) =>
          !_isInProgress(status.state) &&
          (status.stagedVersion?.isNotEmpty ?? false),
      invalidMessage: 'The selected update is no longer staged.',
    );
    if (current == null) return;
    await _run('Apply', _doApply, expectedBackend: backend);
  }

  Future<void> _confirmRollback() async {
    final backend = _backend;
    if (backend == null) return;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Roll back this rig?',
      message: 'The connected rig will restart into its retained previous '
          'build. Any active imaging work must already be stopped.',
      confirmLabel: 'Roll Back and Restart',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final current = await _revalidateCommand(
      backend,
      'Rollback',
      (status) => !_isInProgress(status.state) && status.rollbackAvailable,
      invalidMessage: 'A rollback restore point is no longer available.',
    );
    if (current == null) return;
    await _run('Rollback', _doRollback, expectedBackend: backend);
  }

  Future<void> _confirmDiscard() async {
    final backend = _backend;
    final stagedVersion = _status?.stagedVersion ?? 'the staged update';
    if (backend == null) return;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Discard $stagedVersion?',
      message: 'The downloaded update will be removed from the connected '
          'rig. It must be downloaded again before it can be applied.',
      confirmLabel: 'Discard Update',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final current = await _revalidateCommand(
      backend,
      'Discard',
      (status) =>
          !_isInProgress(status.state) &&
          (status.stagedVersion?.isNotEmpty ?? false),
      invalidMessage: 'There is no longer a staged update to discard.',
    );
    if (current == null) return;
    await _run(
      'Discard',
      _doDiscard,
      expectedBackend: backend,
      acceptedMessage: 'Staged update discarded',
    );
  }

  Future<RemoteUpdateStatus?> _revalidateCommand(
    NetworkBackend backend,
    String label,
    bool Function(RemoteUpdateStatus status) isStillValid, {
    required String invalidMessage,
  }) async {
    final backendGeneration = _backendGeneration;
    final request = ++_nextStatusRequest;
    try {
      final status = await backend.getUpdateStatus();
      if (!mounted ||
          backendGeneration != _backendGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        if (mounted) {
          context.showErrorSnackBar(
            '$label cancelled because the connected rig changed.',
          );
        }
        return null;
      }
      if (request >= _lastAppliedStatusRequest) {
        _lastAppliedStatusRequest = request;
        setState(() {
          _status = status;
          _pollError = null;
        });
      }
      if (!isStillValid(status)) {
        context.showErrorSnackBar('$invalidMessage Refresh and try again.');
        return null;
      }
      return status;
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        context.showErrorSnackBar(
          '$label cancelled because the rig state could not be verified: $e',
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backend = _backend;

    return SettingsPage(
      title: 'Appliance updates',
      description: 'Check for, stage, and apply updates to the connected rig',
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile,
      children: [
        if (backend == null)
          _InfoCard(
            colors: colors,
            icon: LucideIcons.info,
            // Point at the check that actually exists: nothing configures the
            // desktop updater's server URL, and the Linux build is a tarball
            // with no installer at all.
            text: 'This page manages updates on a REMOTE appliance; connect to '
                'a rig to use it. For this copy of Skotiq, use Settings > '
                'About > Check for updates.',
          )
        else ...[
          _buildVersionCard(colors),
          const SizedBox(height: 12),
          _buildStatusCard(colors),
          const SizedBox(height: 12),
          _buildActions(colors),
          if (_loadError != null) ...[
            const SizedBox(height: 12),
            _InfoCard(
              colors: colors,
              icon: LucideIcons.alertTriangle,
              text: 'Could not read update state: $_loadError',
            ),
          ],
          if (_pollError != null) ...[
            const SizedBox(height: 12),
            _InfoCard(
              colors: colors,
              icon: LucideIcons.wifiOff,
              text: '$_pollError The status shown above may be stale; '
                  'Skotiq will keep retrying.',
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildVersionCard(SkotiqColors colors) {
    final v = _version;
    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current Build',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              )),
          const SizedBox(height: 6),
          Text(
            v == null
                ? (_loading ? 'Loading…' : '—')
                : '${v.currentVersion} (build ${v.buildNumber})',
            style: SkotiqTypography.pageTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
          if (v != null) ...[
            const SizedBox(height: 4),
            Text(
                v.channel == null
                    ? 'Platform: ${v.platform}'
                    : 'Channel: ${v.channel} · ${v.platform}',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                )),
            // A rig with no update server is no longer a rig that cannot
            // update: with none set it reads the project's GitHub releases.
            // Warning about a missing server there would report a fault that
            // is not one.
            if (v.updateSource == 'github-releases')
              Text('Updates come from the published GitHub releases',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ))
            else if (v.updateSource != null && v.updateSource!.isNotEmpty)
              Text('Update server: ${v.updateSource}',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ))
            else
              Text('This rig reports no update source',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.warning,
                  )),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusCard(SkotiqColors colors) {
    final s = _status;
    final pct = s?.progressPct;
    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Update Status',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              )),
          const SizedBox(height: 6),
          Text(_statusLabel(s?.state),
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              )),
          if (s?.stagedVersion != null) ...[
            const SizedBox(height: 4),
            Text('Staged: ${s!.stagedVersion}',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                )),
          ],
          if (s?.availableVersion != null) ...[
            const SizedBox(height: 4),
            Text(
              'Available: ${s!.availableVersion}'
              '${s.availableBuildNumber == null ? '' : ' (build ${s.availableBuildNumber})'}',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.success,
              ),
            ),
          ],
          if (pct != null && _isInProgress(s?.state)) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: colors.border,
                color: colors.primary,
              ),
            ),
          ],
          if (s?.message != null && s!.message!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(s.message!,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                )),
          ],
          if (s?.lastError != null && s!.lastError!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Last error: ${s.lastError}',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.error,
                )),
          ],
          if (s?.requiresManualUpgrade ?? false) ...[
            const SizedBox(height: 6),
            Text(
              'This release requires a manual upgrade and cannot be staged '
              'from Skotiq.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.warning,
              ),
            ),
          ] else if (s != null && !s.canAuthenticateUpdates) ...[
            const SizedBox(height: 6),
            Text(
              'This host can check for releases but cannot authenticate '
              'update packages. Install a build with a trusted update key.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.warning,
              ),
            ),
          ],
          if (s != null && !_knownStates.contains(s.state)) ...[
            const SizedBox(height: 6),
            Text(
              'This host reports an update state this app does not recognize. '
              'Actions are disabled until the state returns to a supported '
              'value or the client is updated.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// True when the appliance has somewhere to check for releases.
  ///
  /// Unknown (the version card has not loaded yet) counts as "yes" so the
  /// button is not disabled by a slow first poll.
  bool get _hasUpdateSource {
    final version = _version;
    if (version == null) return true;
    // A rig with no update server is not a rig with no updates: with none
    // configured it reads the project's GitHub releases. Gating on the server
    // URL alone would gray out Check on every rig that updates that way.
    return (version.updateSource ?? version.updateServerUrl ?? '')
        .trim()
        .isNotEmpty;
  }

  Widget _buildActions(SkotiqColors colors) {
    final status = _status;
    final state = status?.state;
    final inProgress = _isInProgress(state);
    final hasStaged =
        state == 'staged' || (status?.stagedVersion?.isNotEmpty ?? false);
    // Compatibility for hosts from before the explicit `available` state:
    // their status returned idle with this message immediately after a check.
    final legacyAvailable = state == 'idle' &&
        (status?.message?.toLowerCase().contains('update') ?? false) &&
        (status?.message?.toLowerCase().contains('available') ?? false);
    final hasAvailable =
        (status?.hasAvailableUpdate ?? false) || legacyAvailable;
    final stateAllowsCommands = state == 'idle' ||
        state == 'available' ||
        state == 'staged' ||
        state == 'failed';
    final canAct = status != null &&
        !_loading &&
        !_busy &&
        !inProgress &&
        stateAllowsCommands;
    final canDownload = canAct &&
        hasAvailable &&
        !status.requiresManualUpgrade &&
        status.canAuthenticateUpdates;
    final canRollback = canAct && status.rollbackAvailable;
    // A check against an appliance with no update source at all can only end
    // one way: the job is accepted (green "Check request accepted") and the
    // status then flips to "Update failed" with a raw UpdateException.
    // Offering the button there was an invitation to manufacture a scary
    // failure state; the version card immediately above already says so.
    final canCheck = canAct && _hasUpdateSource;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        SkotiqButton(
          onPressed: canCheck ? () => _run('Check', _doCheck) : null,
          label: 'Check for Updates',
          icon: LucideIcons.refreshCw,
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: canDownload ? () => _run('Download', _doDownload) : null,
          label: 'Download',
          icon: LucideIcons.download,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: canAct && hasStaged ? _confirmApply : null,
          label: 'Apply staged',
          icon: LucideIcons.checkCircle,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
        ),
        if (hasStaged)
          SkotiqButton(
            onPressed: canAct ? _confirmDiscard : null,
            label: 'Discard staged',
            icon: LucideIcons.trash2,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
        SkotiqButton(
          onPressed: canRollback ? _confirmRollback : null,
          label: 'Rollback',
          icon: LucideIcons.undo2,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        if (_isAbortable(state))
          SkotiqButton(
            onPressed: _busy
                ? null
                : () => _run(
                      'Abort',
                      _doAbort,
                      // The host reports which jobs it actually cancelled, and
                      // an empty list is its answer rather than a failure — so
                      // say which happened instead of "request accepted" over
                      // a no-op.
                      describeResult: (result) {
                        final cancelled = result is List ? result.length : 0;
                        return cancelled == 0
                            ? 'Nothing was in flight to abort'
                            : 'Abort accepted: '
                                '$cancelled job${cancelled == 1 ? '' : 's'} '
                                'cancelled';
                      },
                    ),
            label: 'Abort',
            icon: LucideIcons.x,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
        SkotiqButton(
          onPressed: _loading ? null : _refresh,
          label: 'Refresh',
          icon: LucideIcons.rotateCw,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
      ],
    );
  }

  static const _knownStates = {
    'idle',
    'available',
    'checking',
    'downloading',
    'verifying',
    'cancelling',
    'staged',
    'installing',
    'applying',
    'failed',
  };

  String _statusLabel(String? state) {
    if (_loading && state == null) return 'Loading…';
    return switch (state) {
      null => 'Unavailable',
      'idle' => 'Ready to check',
      'available' => 'Update available',
      'checking' => 'Checking for updates…',
      'downloading' => 'Downloading update…',
      'verifying' => 'Verifying update…',
      'cancelling' => 'Cancelling update…',
      'staged' => 'Ready to apply',
      'installing' || 'applying' => 'Restarting into update…',
      'failed' => 'Update failed',
      _ => 'Host state: $state',
    };
  }

  Future<RemoteJob> _doCheck(NetworkBackend backend) {
    return backend.checkForUpdate();
  }

  Future<RemoteJob> _doDownload(NetworkBackend backend) {
    return backend.downloadUpdate();
  }

  Future<RemoteJob> _doApply(NetworkBackend backend) {
    return backend.applyUpdate();
  }

  Future<RemoteJob> _doRollback(NetworkBackend backend) {
    return backend.rollbackUpdate();
  }

  /// The ids of the jobs the host cancelled; empty when nothing was in flight.
  Future<List<String>> _doAbort(NetworkBackend backend) {
    return backend.abortUpdate();
  }

  Future<void> _doDiscard(NetworkBackend backend) {
    return backend.discardStagedUpdate();
  }
}

class _InfoCard extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String text;

  const _InfoCard({
    required this.colors,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                )),
          ),
        ],
      ),
    );
  }
}
