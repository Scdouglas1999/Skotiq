import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../editors/integration_goals_editor.dart';
import '../editors/target_constraints_editor.dart';
import 'target_score_row.dart';
import '../../../router/app_routes.dart';
import '../../../router/planner_route.dart';
import '../../../utils/snackbar_helper.dart';

/// Dynamic scheduler body used by the Planner's Scheduler tab.
part 'scheduler_tab_content/decision_panel.dart';
part 'scheduler_tab_content/config_expansion.dart';
part 'scheduler_tab_content/queue_table.dart';
part 'scheduler_tab_content/target_editor_overlay.dart';
part 'scheduler_tab_content/empty_state.dart';

class SchedulerTabContent extends ConsumerStatefulWidget {
  const SchedulerTabContent({super.key});

  @override
  ConsumerState<SchedulerTabContent> createState() =>
      _SchedulerTabContentState();
}

class _SchedulerTabContentState extends ConsumerState<SchedulerTabContent>
    with WidgetsBindingObserver {
  // Rebuilds the countdown while visible and polls remote state periodically.
  Timer? _countdownTimer;
  Future<void> _configSaveTail = Future<void>.value();
  bool _configSaveErrorVisible = false;
  bool _schedulerActionBusy = false;
  int _remotePollTicks = 0;

  /// Scheduler actions and config saves sent to the host; a host change
  /// drops what the old host answers.
  late final _hostScopes = ref.backendScopes(alive: () => mounted);
  SchedulerConfig? _confirmedConfig;
  SchedulerConfig? _requestedConfig;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _editingTargetId = 0; // 0 means no editor open

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        // Do not carry command state or unsaved config across a backend
        // replacement; the next build reads the new host's config.
        _hostScopes.cancelAll();
        _configSaveErrorVisible = false;
        _confirmedConfig = null;
        _requestedConfig = null;
        _configSaveTail = Future<void>.value();
        if (mounted && _schedulerActionBusy) {
          setState(() => _schedulerActionBusy = false);
        }
      },
    );
    _startCountdownTimer();
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _remotePollTicks++;
      if (_remotePollTicks % 3 == 0 &&
          ref.read(isRemoteModeProvider)) {
        ref.invalidate(schedulerRemoteSnapshotProvider);
      }
      setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_countdownTimer == null || !_countdownTimer!.isActive) {
        _startCountdownTimer();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backendSubscription?.close();
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _onStart([bool allowWarnings = false]) async {
    await _runSchedulerAction('start', allowWarnings: allowWarnings);
  }

  Future<void> _onPause() async {
    await _runSchedulerAction('pause');
  }

  Future<void> _onResume() async {
    await _runSchedulerAction('resume');
  }

  Future<void> _onStop() async {
    await _runSchedulerAction('stop');
  }

  Future<void> _onForceReeval() async {
    await _runSchedulerAction('evaluate');
  }

  Future<void> _runSchedulerAction(
    String action, {
    bool allowWarnings = false,
  }) async {
    if (_schedulerActionBusy) return;
    final command = _hostScopes.beginLatest(#schedulerAction);
    final backend = command.value;
    setState(() => _schedulerActionBusy = true);
    try {
      if (action == 'start') {
        final readiness = backend.remoteHost != null
            ? (await ref.read(schedulerRemoteSnapshotProvider.future)).readiness
            : ref.read(schedulerStartReadinessProvider);
        if (readiness.blocked ||
            (readiness.warnings.isNotEmpty && !allowWarnings)) {
          throw StateError(
            readiness.blocked
                ? 'Scheduler readiness is blocked.'
                : 'Scheduler warnings require confirmation.',
          );
        }
      }
      if (backend.remoteHost case final linkedHost?) {
        if (action == 'start' && allowWarnings) {
          await linkedHost.planning.controlScheduler(action, confirmWarnings: true);
        } else {
          await linkedHost.planning.controlScheduler(action);
        }
      } else {
        // Pause and Stop must remain available for an already-running engine
        // even if an unrelated settings refresh is failing. Operations that
        // evaluate/dispatch wait for the cold-start authority gate.
        final engine = switch (action) {
          'pause' || 'stop' => ref.read(schedulerEngineProvider),
          _ => await ref.read(schedulerEngineReadyProvider.future),
        };
        switch (action) {
          case 'start':
            await engine.start();
          case 'pause':
            await engine.pause();
          case 'resume':
            await engine.resume();
          case 'stop':
            await engine.stop();
          case 'evaluate':
            await engine.evaluateNow(reason: 'manual force re-evaluation');
        }
      }
      if (command.isCurrent) {
        ref.invalidate(schedulerRemoteSnapshotProvider);
        ref.invalidate(schedulerPreviewDecisionProvider);
      }
    } catch (error) {
      if (!mounted) return;
      if (command.isCurrent) {
        context.showErrorSnackBar(
          'Scheduler action failed: ${userFacingError(error)}',
        );
      }
    } finally {
      if (command.isCurrent) {
        setState(() => _schedulerActionBusy = false);
      }
    }
  }

  void _onWeightsChanged(SchedulerWeights weights) {
    _applySchedulerConfig(_baseConfig.copyWith(weights: weights));
  }

  void _onMinAltitudeChanged(double minAlt) {
    _applySchedulerConfig(
      _baseConfig.copyWith(minAltitudeDegrees: minAlt),
    );
  }

  void _onHysteresisChanged(double ratio) {
    _applySchedulerConfig(_baseConfig.copyWith(hysteresisRatio: ratio));
  }

  SchedulerConfig get _baseConfig =>
      _requestedConfig ?? _confirmedConfig ?? SchedulerConfig.defaults;

  void _applySchedulerConfig(SchedulerConfig config) {
    final host = _hostScopes.begin();
    final backend = host.value;
    final localStore = backend.remoteHost != null
        ? null
        : ref.read(schedulerConfigStoreProvider);
    final localEngine =
        backend.remoteHost != null ? null : ref.read(schedulerEngineProvider);
    setState(() => _requestedConfig = config);

    // Local changes are reflected immediately while their durable writes are
    // serialized. Remote changes remain optimistic in this widget until the
    // host confirms the same full config.
    if (backend.remoteHost == null) {
      ref.read(schedulerConfigUserDirtyProvider.notifier).state = true;
      localEngine!.updateConfig(config);
    }

    _configSaveTail = _configSaveTail.then((_) async {
      try {
        SchedulerConfig confirmed;
        if (backend.remoteHost case final linkedHost?) {
          final response = await linkedHost.planning.updateSchedulerConfig(
            config.toStorageJson().cast<String, dynamic>(),
          );
          confirmed = SchedulerRemoteSnapshot.fromJson(response).config;
        } else {
          await localStore!.save(config);
          confirmed = config;
          // The durable row is what siteMinimumAltitudeDegProvider serves to
          // the sequence builder and the altitude charts, so a slider edit has
          // to reach it now — otherwise moving "Min altitude" here would only
          // take effect on the next launch and the rest of the app would keep
          // gating on the superseded number. Safe for the engine: it takes this
          // provider through ref.listen and skips the update while
          // schedulerConfigUserDirtyProvider is set (which this edit set), so
          // nothing is torn down and the live config is not overwritten.
          ref.invalidate(schedulerPersistedConfigProvider);
        }
        if (!mounted || host.isStale) return;
        setState(() {
          _confirmedConfig = confirmed;
          if (_requestedConfig == config) _requestedConfig = null;
        });
        if (backend.remoteHost != null) {
          ref.invalidate(schedulerRemoteSnapshotProvider);
        }
        _configSaveErrorVisible = false;
      } catch (error) {
        if (mounted && host.isCurrent) {
          if (_requestedConfig == config) {
            final rollback = _confirmedConfig ?? SchedulerConfig.defaults;
            if (backend.remoteHost == null) {
              localEngine!.updateConfig(rollback);
            }
            setState(() => _requestedConfig = null);
          }
          if (backend.remoteHost != null) {
            ref.invalidate(schedulerRemoteSnapshotProvider);
          }
        }
        if (mounted && host.isCurrent && !_configSaveErrorVisible) {
          _configSaveErrorVisible = true;
          context.showErrorSnackBar(
            'Could not save scheduler settings: ${userFacingError(error)}',
          );
        }
      }
    });
  }

  void _openEditor(int targetId) {
    setState(() => _editingTargetId = targetId);
  }

  void _closeEditor() {
    setState(() => _editingTargetId = 0);
  }

  @override
  Widget build(BuildContext context) {
    late final SchedulerStatus status;
    late final SchedulerDecision? decision;
    late final SchedulerConfig authoritativeConfig;
    late final SchedulerStartReadiness? remoteReadiness;

    if (ref.watch(isRemoteModeProvider)) {
      final remoteAsync = ref.watch(schedulerRemoteSnapshotProvider);
      final remote = remoteAsync.valueOrNull;
      if (remote == null) {
        return remoteAsync.when(
          loading: () => const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Could not load scheduler state: ${userFacingError(error)}'),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqButton(
                  label: 'Retry',
                  icon: LucideIcons.refreshCw,
                  onPressed: () =>
                      ref.invalidate(schedulerRemoteSnapshotProvider),
                ),
              ],
            ),
          ),
          data: (_) => const SizedBox.shrink(),
        );
      }
      status = remote.status;
      decision = remote.decision;
      authoritativeConfig = remote.config;
      remoteReadiness = remote.readiness;
    } else {
      final readyAsync = ref.watch(schedulerEngineReadyProvider);
      final readyEngine = readyAsync.valueOrNull;
      if (readyEngine == null) {
        return readyAsync.when(
          loading: () => const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Could not load scheduler configuration: ${userFacingError(error)}'),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqButton(
                  label: 'Retry',
                  icon: LucideIcons.refreshCw,
                  onPressed: () {
                    ref.invalidate(appSettingsProvider);
                    ref.invalidate(schedulerPersistedConfigProvider);
                    ref.invalidate(schedulerEngineReadyProvider);
                  },
                ),
              ],
            ),
          ),
          data: (_) => const SizedBox.shrink(),
        );
      }
      status = ref.watch(schedulerStatusProvider);
      final liveDecision = ref.watch(currentSchedulerDecisionProvider);
      final previewDecision = ref.watch(schedulerPreviewDecisionProvider);
      decision = status.state == SchedulerState.idle
          ? previewDecision.valueOrNull ?? liveDecision
          : liveDecision ?? previewDecision.valueOrNull;
      authoritativeConfig = readyEngine.config;
      remoteReadiness = null;
      // Mount local data-change listeners only on the process that owns the
      // scheduler. A remote client must never spin up a second autopilot.
      ref.watch(schedulerAutoReevalProvider);
    }

    if (_requestedConfig == null) _confirmedConfig = authoritativeConfig;
    final config = _requestedConfig ?? authoritativeConfig;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < SkotiqTokens.breakpointTablet;
        if (isMobile) {
          return _buildMobile(
            context,
            status,
            decision,
            config,
            readinessOverride: remoteReadiness,
          );
        }
        return _buildDesktop(
          context,
          status,
          decision,
          config,
          readinessOverride: remoteReadiness,
        );
      },
    );
  }

  Widget _buildDesktop(BuildContext context, SchedulerStatus status,
      SchedulerDecision? decision, SchedulerConfig config,
      {required SchedulerStartReadiness? readinessOverride}) {
    return Stack(
      children: [
        Padding(
          padding: SkotiqTokens.screenPadding,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final panelWidth = panelWidthFromFraction(
                constraints.maxWidth,
                fraction: 0.28,
                min: 280,
                max: 380,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: panelWidth,
                    child: SingleChildScrollView(
                      child: _DecisionPanel(
                        status: status,
                        decision: decision,
                        config: config,
                        readinessOverride: readinessOverride,
                        controlsBusy: _schedulerActionBusy,
                        onStart: _onStart,
                        onPause: _onPause,
                        onResume: _onResume,
                        onStop: _onStop,
                        onForceReeval: _onForceReeval,
                        onWeightsChanged: _onWeightsChanged,
                        onMinAltitudeChanged: _onMinAltitudeChanged,
                        onHysteresisChanged: _onHysteresisChanged,
                      ),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  Expanded(
                    child: _QueueTable(
                      decision: decision,
                      currentTargetId: status.currentTargetId,
                      onRowTap: _openEditor,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (_editingTargetId != 0)
          _TargetEditorOverlay(
            targetId: _editingTargetId,
            decision: decision,
            onClose: _closeEditor,
          ),
      ],
    );
  }

  Widget _buildMobile(BuildContext context, SchedulerStatus status,
      SchedulerDecision? decision, SchedulerConfig config,
      {required SchedulerStartReadiness? readinessOverride}) {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: SkotiqTokens.screenPaddingCompact,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DecisionPanel(
                status: status,
                decision: decision,
                config: config,
                readinessOverride: readinessOverride,
                controlsBusy: _schedulerActionBusy,
                onStart: _onStart,
                onPause: _onPause,
                onResume: _onResume,
                onStop: _onStop,
                onForceReeval: _onForceReeval,
                onWeightsChanged: _onWeightsChanged,
                onMinAltitudeChanged: _onMinAltitudeChanged,
                onHysteresisChanged: _onHysteresisChanged,
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              _QueueTable(
                decision: decision,
                currentTargetId: status.currentTargetId,
                onRowTap: _openEditor,
              ),
            ],
          ),
        ),
        if (_editingTargetId != 0)
          _TargetEditorOverlay(
            targetId: _editingTargetId,
            decision: decision,
            onClose: _closeEditor,
          ),
      ],
    );
  }
}
