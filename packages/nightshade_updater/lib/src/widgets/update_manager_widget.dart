// ignore_for_file: unused_local_variable

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_core/nightshade_core.dart'
    show SequenceExecutionState, sequenceExecutionStateProvider;
import 'package:nightshade_ui/nightshade_ui.dart';

import '../../nightshade_updater.dart';

/// Widget that manages the update UI flow.
///
/// This widget should be placed inside MaterialApp's builder. It uses
/// a Stack-based approach to show update banners (no Overlay required).
///
/// The builder sits above the app's Navigator, so the dialogs (update
/// available, download progress, ready to install) need [navigatorKey] to
/// reach it. Without one they cannot open: every call threw "Navigator
/// operation requested with a context that does not include a Navigator",
/// and the offer the whole prompt gate exists to time was never seen.
class UpdateManagerWidget extends ConsumerStatefulWidget {
  final Widget child;

  /// The app's root Navigator, used when this widget is mounted above it.
  final GlobalKey<NavigatorState>? navigatorKey;

  const UpdateManagerWidget({
    super.key,
    required this.child,
    this.navigatorKey,
  });

  @override
  ConsumerState<UpdateManagerWidget> createState() =>
      _UpdateManagerWidgetState();
}

class _UpdateManagerWidgetState extends ConsumerState<UpdateManagerWidget> {
  bool _hasShownUpdateDialog = false;
  bool _showingBanner = false;
  String _bannerVersion = '';
  String? _errorMessage;
  int _bannerGeneration = 0;
  late final Stream<LanPushEvent> _lanPushStream;
  StreamSubscription<LanPushEvent>? _lanPushSubscription;
  static const _disabledUpdatesLog =
      '[UpdateManager] No update source configured, skipping update checks';

  /// Reads `sourceConfigured` rather than the server URL: a build reading
  /// GitHub Releases has no server URL, and testing the URL here was what
  /// kept the whole update flow switched off in every shipped build.
  bool _isUpdateConfigured() => ref.read(updateProvider).sourceConfigured;

  @override
  void initState() {
    super.initState();
    // Check for staged updates immediately (from previous LAN push)
    Future.delayed(const Duration(seconds: 1), _checkForStagedUpdate);

    // Check for updates on startup after a short delay
    Future.delayed(const Duration(seconds: 3), _checkForUpdates);

    // Listen to LAN push events
    _lanPushStream = LanPushNotifier.stream;
    _lanPushSubscription = _lanPushStream.listen(_onLanPushEvent);
  }

  Future<void> _checkForStagedUpdate() async {
    if (!mounted) return;

    developer.log('Checking for staged updates...', name: 'UpdateManager');
    final updateNotifier = ref.read(updateProvider.notifier);
    await updateNotifier.checkStagedUpdate();

    final notice = updateNotifier.takePendingNotice();
    if (notice != null) {
      _showErrorBanner(notice.message);
    }

    final state = ref.read(updateProvider);
    if (state.status == UpdateStatus.staged) {
      developer.log(
        'Found staged update: ${state.availableUpdate?.version}',
        name: 'UpdateManager',
        level: 800,
      );
      _showLanPushBannerDirect(state.availableUpdate?.version ?? 'Unknown');
    } else {
      developer.log('No staged update found', name: 'UpdateManager');
    }
  }

  void _onLanPushEvent(LanPushEvent event) {
    if (!mounted) return;

    switch (event) {
      case LanPushReceivedEvent(:final manifest, :final stagingPath):
        developer.log(
          'LAN push received: ${manifest.version}',
          name: 'UpdateManager',
          level: 800,
        );
        // Update provider state so applyUpdate() works
        ref
            .read(updateProvider.notifier)
            .setStagedFromLanPush(manifest, stagingPath);
        _showLanPushBannerDirect(manifest.version);
        break;
      case LanPushProgressEvent(:final progress, :final message):
        // Could show progress indicator if desired
        break;
      case LanPushErrorEvent(:final error):
        developer.log(
          'LAN push error: $error',
          name: 'UpdateManager',
          level: 1000,
        );
        _showErrorBanner('LAN push error: $error');
        break;
    }
  }

  void _showLanPushBannerDirect(String version, {bool autoDismiss = true}) {
    if (!mounted) return;
    final generation = ++_bannerGeneration;

    developer.log(
      'Showing banner for version: $version',
      name: 'UpdateManager',
    );
    setState(() {
      _showingBanner = true;
      _bannerVersion = version;
      _errorMessage = null;
    });

    if (autoDismiss) {
      Future.delayed(const Duration(seconds: 60), () {
        if (mounted && _showingBanner && generation == _bannerGeneration) {
          setState(() => _showingBanner = false);
        }
      });
    }
  }

  void _hideBanner() {
    if (mounted) {
      _bannerGeneration++;
      setState(() {
        _showingBanner = false;
        _errorMessage = null;
      });
    }
  }

  void _showErrorBanner(String error) {
    if (!mounted) return;
    final generation = ++_bannerGeneration;
    setState(() {
      _showingBanner = true;
      _errorMessage = error;
    });

    // Auto-dismiss after 10 seconds
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && generation == _bannerGeneration) {
        _hideBanner();
      }
    });
  }

  Future<void> _checkForUpdates() async {
    if (!mounted) return;
    if (!_isUpdateConfigured()) {
      developer.log(_disabledUpdatesLog, name: 'UpdateManager');
      return;
    }

    // Throttled: startup happens every launch, and a rig can be restarted
    // many times in one session while wiring equipment. The button in
    // Settings still runs an unthrottled check.
    final updateNotifier = ref.read(updateProvider.notifier);
    await updateNotifier.checkForUpdatesIfDue();
  }

  /// A context below the app's Navigator, or null when there is none yet.
  BuildContext? _dialogContext() {
    if (Navigator.maybeOf(context) != null) return context;
    final key = widget.navigatorKey;
    return key?.currentState?.overlay?.context ?? key?.currentContext;
  }

  void _showUpdateAvailableDialog(UpdateState state) {
    if (_hasShownUpdateDialog) return;

    final notifier = ref.read(updateProvider.notifier);

    // Was this version already answered — skipped, or waved off within the
    // reminder window? Found updates stay in state either way, so Settings
    // still shows it; this only decides whether to interrupt.
    if (!notifier.shouldPrompt()) {
      developer.log(
        'Update ${state.availableUpdate?.version} is available but was '
        'already skipped or deferred; not prompting.',
        name: 'UpdateManager',
      );
      return;
    }

    // Never talk over a running rig. Unlike the apply gate this does not
    // require a parked mount — it only refuses to interrupt an exposure, a
    // slew, or a sequence in flight. The dialog is re-offered on the next
    // check once the rig is idle.
    final heldBack = updatePromptHeldBackReason(ref.read);
    if (heldBack != null) {
      developer.log(
        'Holding back the update prompt: $heldBack.',
        name: 'UpdateManager',
      );
      return;
    }

    final dialogContext = _dialogContext();
    if (dialogContext == null) {
      developer.log(
        'No Navigator to show the update offer on; it stays in Settings.',
        name: 'UpdateManager',
        level: 900,
      );
      return;
    }

    _hasShownUpdateDialog = true;

    final manifest = state.availableUpdate!;
    UpdateAvailableDialog.show(
      dialogContext,
      currentVersion: state.currentVersion,
      newVersion: manifest.version,
      // Prefer the notes the source carried (the GitHub release body) over
      // the terse line baked into the signed manifest.
      releaseNotes: state.releaseNotes ?? manifest.releaseNotes,
      downloadSizeMb: (manifest.compressedSize / 1024 / 1024).round(),
      requiresManualUpgrade: state.requiresManualUpgrade,
      onUpdate: () {
        ref.read(updateProvider.notifier).downloadUpdate();
      },
      onSkip: () {
        ref.read(updateProvider.notifier).skipUpdate();
      },
      onLater: () {
        // "Not now" is remembered across restarts, so dismissing on the way
        // out to the scope does not mean being asked again at the next
        // launch. A newer release still asks straight away.
        unawaited(ref.read(updateProvider.notifier).deferUpdate());
        // Reset so a manual re-check can reopen the dialog this session.
        _hasShownUpdateDialog = false;
      },
    );
  }

  void _showDownloadProgressDialog(UpdateState state) {
    final hostContext = _dialogContext();
    if (hostContext == null) return;
    var dialogClosed = false;
    showDialog(
      context: hostContext,
      barrierDismissible: false,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          final currentState = ref.watch(updateProvider);
          if (currentState.status == UpdateStatus.staged) {
            // Download complete, close this dialog and show ready dialog
            if (!dialogClosed) {
              dialogClosed = true;
              Future.microtask(() {
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (mounted) _showUpdateReadyDialog(currentState);
              });
            }
            return const SizedBox.shrink();
          }

          // Terminal non-download states leave nothing to show; close the
          // dialog so a failed/cancelled download is not trapped behind it.
          if (currentState.status == UpdateStatus.error ||
              currentState.status == UpdateStatus.available ||
              currentState.status == UpdateStatus.upToDate ||
              currentState.status == UpdateStatus.idle) {
            if (!dialogClosed) {
              dialogClosed = true;
              Future.microtask(() {
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              });
            }
            return const SizedBox.shrink();
          }

          return UpdateDownloadDialog(
            version: currentState.availableUpdate?.version ?? '',
            progress: currentState.downloadProgress,
            downloadedMb: (currentState.downloadedBytes / 1024 / 1024).round(),
            totalMb: (currentState.totalBytes / 1024 / 1024).round(),
            status: 'Downloading...',
            onCancel: () {
              ref.read(updateProvider.notifier).cancelDownload();
              Navigator.of(context).pop();
            },
          );
        },
      ),
    );
  }

  void _showUpdateReadyDialog(UpdateState state) {
    final sequencerState = ref.read(sequenceExecutionStateProvider);
    final isSessionActive =
        sequencerState == SequenceExecutionState.running ||
        sequencerState == SequenceExecutionState.paused ||
        sequencerState == SequenceExecutionState.stopping ||
        sequencerState == SequenceExecutionState.recovering;

    final dialogContext = _dialogContext();
    if (dialogContext == null) {
      _showLanPushBannerDirect(
        state.availableUpdate?.version ?? '',
        autoDismiss: false,
      );
      return;
    }

    UpdateReadyDialog.show(
      dialogContext,
      version: state.availableUpdate?.version ?? '',
      isSessionActive: isSessionActive,
      // Android installs through the OS, which does not restart the app for
      // us; the dialog must not promise that it will.
      installsViaSystemInstaller: !kIsWeb && Platform.isAndroid,
      onRestartNow: () {
        ref.read(updateProvider.notifier).applyUpdate();
      },
      onRestartLater: () {
        // Keep a persistent apply banner so the staged update stays reachable.
        _showLanPushBannerDirect(
          state.availableUpdate?.version ?? '',
          autoDismiss: false,
        );
      },
    );
  }

  @override
  void dispose() {
    _lanPushSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // An update found mid-run is held back rather than dropped. Watch the
    // hold so the offer arrives the moment the rig goes idle, instead of
    // waiting for the next scheduled check up to twelve hours later — quite
    // possibly while nobody is at the screen.
    ref.listen<String?>(updatePromptHoldProvider, (previous, next) {
      if (previous == null || next != null) return;
      final state = ref.read(updateProvider);
      if (state.status != UpdateStatus.available) return;
      // Deferred to a post-frame callback: this fires during a provider
      // rebuild, and showing a dialog inside one throws.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUpdateAvailableDialog(ref.read(updateProvider));
      });
    });

    ref.listen<UpdateState>(updateProvider, (previous, next) {
      // Handle state transitions
      if (previous?.status != next.status) {
        switch (next.status) {
          case UpdateStatus.available:
            _showUpdateAvailableDialog(next);
            break;
          case UpdateStatus.downloading:
            if (previous?.status != UpdateStatus.downloading) {
              _showDownloadProgressDialog(next);
            }
            break;
          case UpdateStatus.staged:
            // Back to staged with a message: the install was refused for a
            // reason the operator has to act on (Android's install
            // permission), and the update is still ready once they have.
            if (next.errorMessage != null) {
              _showErrorBanner(next.errorMessage!);
              break;
            }
            // If banner is already showing (from LAN push), don't show dialog
            if (_showingBanner) {
              developer.log(
                'Banner already showing, skipping dialog',
                name: 'UpdateManager',
              );
              break;
            }
            // If came from downloading, dialog handles it
            if (previous?.status == UpdateStatus.downloading) {
              // Will be handled by download dialog
            } else {
              // For non-LAN push staged updates, show banner instead of dialog
              // (dialogs don't work in MaterialApp.builder context)
              _showLanPushBannerDirect(
                next.availableUpdate?.version ?? 'Unknown',
              );
            }
            break;
          case UpdateStatus.error:
            if (next.errorMessage != null) {
              developer.log(
                'Error: ${next.errorMessage}',
                name: 'UpdateManager',
                level: 1000,
              );
              // Show error in banner instead of snackbar (more reliable in builder context)
              _showErrorBanner(next.errorMessage!);
            }
            break;
          default:
            break;
        }
      }
    });

    // Use Stack to show banner without needing Overlay
    return Stack(
      children: [
        widget.child,
        // Show error banner
        if (_errorMessage != null)
          Positioned(
            top: 80,
            right: 16,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 350),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: _hideBanner,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Show update banner
        if (_showingBanner && _errorMessage == null)
          Positioned(
            top: 80,
            right: 16,
            width: 320, // Fixed width to avoid unbounded constraints
            child: Material(
              color: Colors.transparent,
              child: UpdateReceivedBanner(
                version: _bannerVersion,
                source: 'LAN Push',
                onRestart: () {
                  _hideBanner();
                  ref.read(updateProvider.notifier).applyUpdate();
                },
                onDismiss: _hideBanner,
              ),
            ),
          ),
      ],
    );
  }
}
