import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../backend/network_backend.dart';
import '../database/daos/stacked_results_dao.dart';
import '../models/imaging/stack_and_share_models.dart';
import '../services/logging_service.dart';
import '../services/stack_and_share_service.dart';
import '../services/stack_share_export_service.dart';
import 'backend_provider.dart';

/// UI-facing state for the **Stack-and-Share Loop** orchestrator (component C7).
///
/// Wraps the live [StackAndShareProgress] emitted by [StackAndShareService.run]
/// together with the terminal artifacts of the most recent run: the persisted
/// [StackAndShareResult] provenance record (with its DB id), the auto-stretched
/// RGBA display buffer, and the integrated raw u16 mono buffer. A failed run
/// surfaces its cause in [errorMessage] and leaves the buffers null.
///
/// This is a plain immutable value class (const constructor + [copyWith]),
/// matching the style of [LiveStackingState] in `live_stacking_provider.dart`.
class StackAndShareState {
  /// Live progress of the current (or most recent) run. Starts at
  /// [StackAndSharePhase.idle].
  final StackAndShareProgress progress;

  /// The persisted result of the most recent successful run, or null when no
  /// run has completed (idle, in-flight, or failed).
  final StackAndShareResult? result;

  /// The auto-stretched RGBA display buffer of the most recent successful run,
  /// or null when the last run did not stretch (mono / `autoStretch` off) or has
  /// not completed. Length is `resultWidth * resultHeight * 4` when present.
  final Uint8List? resultRgba;

  /// Width of [resultRgba] / [resultMono] in pixels (0 when no result).
  final int resultWidth;

  /// Height of [resultRgba] / [resultMono] in pixels (0 when no result).
  final int resultHeight;

  /// The integrated, calibrated raw u16 buffer of the most recent successful
  /// run, or null when no run has completed.
  ///
  /// The buffer's layout is described by [resultChannels]: when
  /// `resultChannels == 1` this is a single mono luminance plane of length
  /// `resultWidth * resultHeight`; when `resultChannels == 3` this same buffer
  /// holds an OSC integration stored as **interleaved RGB16** (R,G,B per pixel)
  /// of length `resultWidth * resultHeight * 3`. The field name is kept (rather
  /// than introducing a parallel `resultColor` field) so the colour path does
  /// not leave a dead duplicate buffer — the viewer interprets the bytes via
  /// [resultChannels].
  final Uint16List? resultMono;

  /// Channel layout of [resultMono]: `1` for a single mono luminance plane,
  /// `3` for an interleaved RGB16 (OSC) integration. Sourced from
  /// [StackedRawResult.channels] on the most recent successful run; `1` when no
  /// run has completed so existing mono consumers are unaffected.
  final int resultChannels;

  /// Human-readable failure message when the last run ended in
  /// [StackAndSharePhase.error], else null.
  final String? errorMessage;

  const StackAndShareState({
    this.progress = const StackAndShareProgress(),
    this.result,
    this.resultRgba,
    this.resultWidth = 0,
    this.resultHeight = 0,
    this.resultMono,
    this.resultChannels = 1,
    this.errorMessage,
  });

  /// Whether [resultMono] holds an interleaved RGB16 (OSC) integration rather
  /// than a single mono plane.
  bool get isColorResult => resultChannels == 3;

  /// Whether a run is currently in flight (past idle, not yet terminal).
  bool get isRunning =>
      progress.phase != StackAndSharePhase.idle &&
      progress.phase != StackAndSharePhase.complete &&
      progress.phase != StackAndSharePhase.error;

  /// Whether the most recent run completed successfully and produced a result.
  bool get isComplete =>
      progress.phase == StackAndSharePhase.complete && result != null;

  /// Whether the most recent run ended in failure.
  bool get hasError => progress.phase == StackAndSharePhase.error;

  StackAndShareState copyWith({
    StackAndShareProgress? progress,
    StackAndShareResult? result,
    Uint8List? resultRgba,
    int? resultWidth,
    int? resultHeight,
    Uint16List? resultMono,
    int? resultChannels,
    String? errorMessage,
  }) {
    return StackAndShareState(
      progress: progress ?? this.progress,
      result: result ?? this.result,
      resultRgba: resultRgba ?? this.resultRgba,
      resultWidth: resultWidth ?? this.resultWidth,
      resultHeight: resultHeight ?? this.resultHeight,
      resultMono: resultMono ?? this.resultMono,
      resultChannels: resultChannels ?? this.resultChannels,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Orchestrator [StateNotifier] that drives the Stack-and-Share pipeline and
/// exposes its progress + result to the UI.
///
/// [runForSession] calls [StackAndShareService.run] with an `onProgress`
/// callback that publishes each phase transition into [state], guarded by the
/// `mounted` check required here so a disposed notifier never mutates
/// state. On success it captures the persisted result plus the retained RGBA /
/// mono buffers from the service; on failure it records the error message and
/// leaves a terminal [StackAndSharePhase.error] progress so the UI can render a
/// banner. Errors are rethrow-free at this layer (the notifier owns the failure
/// presentation), but they are never silently dropped — the message is always
/// surfaced into [state].
class StackAndShareNotifier extends StateNotifier<StackAndShareState> {
  StackAndShareNotifier(this._ref) : super(const StackAndShareState());

  final Ref _ref;
  Future<void>? _runInFlight;

  StackAndShareService get _service => _ref.read(stackAndShareServiceProvider);
  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Run the full Stack-and-Share pipeline for [sessionId].
  ///
  /// Resets to a fresh in-flight state, streams progress into [state] (with a
  /// `mounted` guard on every update), and on completion captures the persisted
  /// [StackAndShareResult] together with the integrated mono buffer and the
  /// auto-stretched RGBA buffer the service retained. Any thrown error is caught
  /// and recorded in [StackAndShareState.errorMessage]; it is not rethrown so
  /// the calling widget does not need a try/catch around `ref.read(...).run`.
  Future<void> runForSession(
    int sessionId, {
    StackAndShareConfig? config,
  }) async {
    final active = _runInFlight;
    if (active != null) {
      await active;
      return;
    }
    final operation = _runForSession(sessionId, config: config);
    _runInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_runInFlight, operation)) _runInFlight = null;
    }
  }

  Future<void> _runForSession(
    int sessionId, {
    StackAndShareConfig? config,
  }) async {
    if (_ref.read(backendProvider) is NetworkBackend) {
      state = const StackAndShareState(
        progress: StackAndShareProgress(phase: StackAndSharePhase.error),
        errorMessage:
            'Stack & Share runs on the imaging host. Open Skotiq '
            'on that computer to stack a completed session.',
      );
      return;
    }

    final effectiveConfig = config ?? StackAndShareConfig.defaults;

    // Begin a fresh run: clear any prior result/buffers/error and start at the
    // first real phase the service emits.
    state = const StackAndShareState(
      progress: StackAndShareProgress(
        phase: StackAndSharePhase.selectingLights,
      ),
    );

    final service = _service;
    try {
      final result = await service.run(
        sessionId: sessionId,
        config: effectiveConfig,
        onProgress: (p) {
          if (!mounted) return;
          state = state.copyWith(progress: p);
        },
      );

      if (!mounted) return;

      // Capture the terminal artifacts from the service's retained buffers. The
      // service guarantees [lastRawResult] is set on success; the RGBA buffer is
      // present only when the run auto-stretched.
      final raw = service.lastRawResult;
      final rgba = service.lastRgbaResult;

      state = StackAndShareState(
        // The service emits the terminal `complete` phase via onProgress, so
        // `state.progress` is already complete here; reuse it to keep the frame
        // counts the service reported.
        progress: state.progress,
        result: result,
        resultWidth: raw?.width ?? result.width,
        resultHeight: raw?.height ?? result.height,
        resultMono: raw?.data,
        // Carry the integration's channel layout (1=mono, 3=interleaved RGB16)
        // so the viewer renders an OSC result as colour rather than
        // misinterpreting interleaved bytes as a mono plane. Mono runs (and the
        // missing-buffer fallback) keep the default of 1.
        resultChannels: raw?.channels ?? 1,
        resultRgba: rgba?.rgba,
      );
    } catch (e, st) {
      if (!mounted) return;
      // Ensure the terminal error phase is reflected even if the failure
      // happened before the service emitted its own error progress event.
      state = state.copyWith(
        progress: state.progress.phase == StackAndSharePhase.error
            ? state.progress
            : state.progress.copyWith(phase: StackAndSharePhase.error),
        errorMessage: e.toString(),
      );
      _logger.error(
        'Stack-and-Share run failed for session $sessionId: $e',
        source: 'StackAndShareNotifier',
        fields: {'stackTrace': st.toString()},
      );
    }
  }

  /// Reset back to the idle state, discarding the current progress, result, and
  /// retained buffers so the UI returns to its initial empty surface.
  void reset() {
    if (!mounted) return;
    state = const StackAndShareState();
  }
}

/// Orchestrator provider for the Stack-and-Share Loop.
///
/// `autoDispose` so the in-memory RGBA / mono buffers (which can be tens of
/// megabytes for a full-frame integration) are released as soon as the last
/// listener — the Stack-and-Share screen — is torn down.
final stackAndShareProvider =
    StateNotifierProvider.autoDispose<
      StackAndShareNotifier,
      StackAndShareState
    >((ref) {
      ref.watch(backendProvider);
      return StackAndShareNotifier(ref);
    });

/// Loads a single persisted [StackAndShareResult] by its database id for the
/// result viewer.
///
/// Throws [StateError] when no row matches [id] rather than returning an empty
/// result: a stale or deleted id must surface as an error, not render as a
/// blank stack.
final stackResultViewerProvider =
    FutureProvider.family<StackAndShareResult, int>((ref, id) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return (await ref.watch(remoteStackResultProvider(id).future)).result;
      }
      final dao = ref.watch(stackedResultsDaoProvider);
      final result = await dao.getResultById(id);
      if (result == null) {
        throw StateError('No stacked result found for id $id');
      }
      return result;
    });

/// The most recent stacked results across all sessions, newest first, for any
/// history / gallery surface. Caps at the DAO's default limit.
final recentStackedResultsProvider = FutureProvider<List<StackAndShareResult>>((
  ref,
) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final remote = await backend.stackingGetSavedResults();
    return [for (final record in remote) record.result];
  }
  final dao = ref.watch(stackedResultsDaoProvider);
  return dao.getRecentResults();
});

/// Strict remote metadata record, shared by the result and preview providers so
/// a screen load performs only one metadata request. Watching [backendProvider]
/// ties the request to the concrete host identity; switching hosts invalidates
/// the old future rather than letting its response populate the new session.
final remoteStackResultProvider =
    FutureProvider.family<RemoteStackedResult, int>((ref, id) async {
      final backend = ref.watch(backendProvider);
      if (backend is! NetworkBackend) {
        throw StateError('Remote stack metadata requires a network backend.');
      }
      return backend.stackingGetSavedResult(id);
    });

/// Loads and strictly decodes the durable display preview for a saved result.
///
/// Local mode reads the path owned by the persisted row; remote mode downloads
/// bytes from the authenticated host endpoint and never receives the host
/// path. Both branches validate the decoded dimensions against the metadata so
/// a stale or mismatched artifact cannot be displayed under the wrong stats.
final stackResultPreviewProvider = FutureProvider.autoDispose
    .family<Uint8List?, int>((ref, id) async {
      final backend = ref.watch(backendProvider);
      final result = await ref.watch(stackResultViewerProvider(id).future);

      late final Uint8List encoded;
      late final String source;
      if (backend is NetworkBackend) {
        final remote = await ref.watch(remoteStackResultProvider(id).future);
        if (!remote.previewAvailable) return null;
        encoded = await backend.stackingGetSavedResultPreview(id);
        source = 'remote stacked-result preview $id';
      } else {
        final recordedPath = result.exportedImagePath;
        if (recordedPath == null || recordedPath.trim().isEmpty) return null;
        final resultId = result.id;
        final canonicalPath = resultId == null
            ? null
            : await ref
                  .read(stackShareExportServiceProvider)
                  .viewerPreviewPath(resultId);
        final canonicalFile = canonicalPath == null
            ? null
            : File(canonicalPath);
        final file = canonicalFile != null && await canonicalFile.exists()
            ? canonicalFile
            : File(recordedPath);
        if (!await file.exists()) {
          throw StateError('The saved stacked-result preview is missing.');
        }
        final length = await file.length();
        if (length <= 0) {
          throw StateError('The saved stacked-result preview is empty.');
        }
        const maxPreviewBytes = 256 * 1024 * 1024;
        if (length > maxPreviewBytes) {
          throw StateError(
            'The saved stacked-result preview is too large to open '
            '($length bytes).',
          );
        }
        encoded = await file.readAsBytes();
        source = 'saved stacked-result preview';
      }

      final decoded = img.decodeImage(encoded);
      if (decoded == null) {
        throw FormatException('$source is not a supported PNG or JPEG image.');
      }
      if (decoded.width != result.width || decoded.height != result.height) {
        throw FormatException(
          '$source is ${decoded.width}x${decoded.height}, but result $id is '
          '${result.width}x${result.height}.',
        );
      }
      return decoded.getBytes(order: img.ChannelOrder.rgba);
    });
