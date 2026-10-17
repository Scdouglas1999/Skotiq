// Live-stacking broadcast service.
//
// The complement to the Rust `skotiq_sequencer::broadcast` module:
// once a `LiveStackingNode` executes, the Dart side activates a
// session here so the headless API's `/api/broadcast/*` endpoints can
// answer with JPEGs of the building stack + telemetry. Pure Dart so
// the desktop, mobile (in companion / preview mode), and headless
// builds all share one path.
//
// Why a separate service from `LiveStackingService` (which already
// wraps the bridge stacker):
//
//   1. `LiveStackingService` only knows about the stacker's internal
//      u16 frame data. The broadcast needs a watermarked, rendered
//      JPEG suitable for serving over HTTP.
//   2. The broadcast cadence (every new accepted frame) is decoupled
//      from how often the user wants to look at the stack from the
//      UI.
//   3. Auth, public/private toggling, and viewer-count tracking are
//      first-class to broadcasting but irrelevant to the local
//      stacker.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/imaging/stack_and_share_models.dart'
    show ShareCardFontScale, ShareCardLayout, ShareCardSpec;
import '../models/sequence/interpolation_catalog.dart'
    show InterpolationVariable, InterpolationVariableGroup;
import '../models/sequence/sequence_models.dart'
    show LiveStackingMethod, LiveStackingMode, LiveStackingNode;
import '../providers/sequence/sequencer_defaults.dart'
    show sequencerDefaultsProvider;
import 'logging_service.dart';
import 'share_card_renderer.dart';

/// The watermark template's ENTIRE vocabulary.
///
/// The broadcast watermark is not the sequencer's expression language: it is
/// the flat token map built by `_watermarkTokens` below, and
/// [expandWatermarkTokens] renders anything else literally — a `${filter}`
/// picked from the sequencer catalog would be burned verbatim into the
/// broadcast JPEG. So the watermark field's insert control offers this list,
/// not `interpolationCatalog`. `live_stacking_watermark_vocabulary_test.dart`
/// asserts every entry here actually resolves through `renderWatermark()`.
const List<InterpolationVariable> watermarkVariableCatalog = [
  InterpolationVariable(
    name: 'target',
    description: 'Name of the target being stacked',
    group: InterpolationVariableGroup.target,
    example: 'M42',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'target.name',
    description: r'Name of the target being stacked (alias of ${target})',
    group: InterpolationVariableGroup.target,
    example: 'M42',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'integration.hms',
    description: 'Integration time stacked so far, as 2h12m',
    group: InterpolationVariableGroup.session,
    example: '2h12m',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'integration.secs',
    description: 'Integration time stacked so far, in whole seconds',
    group: InterpolationVariableGroup.session,
    example: '7920',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'frames',
    description: 'Number of frames accepted into the stack',
    group: InterpolationVariableGroup.session,
    example: '44',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'stack',
    description: 'Stacking method in use',
    group: InterpolationVariableGroup.session,
    example: 'Average',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'stack.method',
    description: r'Stacking method in use (alias of ${stack})',
    group: InterpolationVariableGroup.session,
    example: 'Average',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'now',
    description: 'Local wall-clock time at render',
    group: InterpolationVariableGroup.time,
    example: '2026-08-04 22:41:07',
    supportsFormat: false,
  ),
];

/// Snapshot of the broadcast state that the run dashboard renders.
///
/// `active == false` everywhere else: the service has not yet seen a
/// `LiveStackingNode` in the current sequence run.
class BroadcastSessionState {
  /// Whether a broadcast is currently armed.
  final bool active;

  /// The configured port the broadcast endpoints answer on. Mirrors
  /// the LiveStackingNode at activation time. `0` when inactive.
  final int port;

  /// HTTP path prefix the broadcast page is served at.
  final String path;

  /// Operating mode.
  final LiveStackingMode mode;

  /// Stack method selected at activation time. The mapping to the
  /// existing live-stacking engine (which only exposes sigma clip) is:
  ///   - [LiveStackingMethod.average] → sigma_clip_enabled = false
  ///   - [LiveStackingMethod.medianRej] / [LiveStackingMethod.sigma] →
  ///     sigma_clip_enabled = true
  /// The brief notes the Rust engine is the source of truth for the
  /// actual reduction; the method selector is a knob on it.
  final LiveStackingMethod stackMethod;

  /// Token required on each broadcast request. `null` or empty means
  /// the broadcast is public.
  final String? authToken;

  /// Watermark template (variable interpolation applied at
  /// render time).
  final String? watermarkText;

  /// Thumbnail width/height for the rendered JPEG.
  final int thumbnailWidth;
  final int thumbnailHeight;

  /// Frames added to the broadcast stack so far.
  final int framesStacked;

  /// `DateTime.now()` at activation.
  final DateTime? activatedAt;

  /// Current target name (lifted from the sequence progress) — used in
  /// the default watermark / `/info` JSON.
  final String? currentTarget;

  /// Total accumulated integration time in seconds across all stacked
  /// frames. Drives the dashboard "Integration" badge and the default
  /// watermark token.
  final double integrationSecs;

  /// Cached snapshot of the most recently rendered broadcast JPEG.
  /// Updated on every accepted frame, served verbatim by the HTTP
  /// endpoint. `null` when no frame has been stacked yet.
  final Uint8List? jpegBytes;

  /// Current viewer count (incremented by `/info` polls in the public
  /// outreach UI). Best-effort only; the dashboard renders it as a
  /// hint, not a guarantee.
  final int viewerCount;

  const BroadcastSessionState({
    this.active = false,
    this.port = 0,
    this.path = '/broadcast',
    this.mode = LiveStackingMode.broadcastOnly,
    this.stackMethod = LiveStackingMethod.average,
    this.authToken,
    this.watermarkText,
    this.thumbnailWidth = 1280,
    this.thumbnailHeight = 720,
    this.framesStacked = 0,
    this.activatedAt,
    this.currentTarget,
    this.integrationSecs = 0.0,
    this.jpegBytes,
    this.viewerCount = 0,
  });

  /// True when the broadcast is public (no token required).
  bool get isPublic => authToken == null || authToken!.isEmpty;

  /// Human-readable integration time, e.g. "2h12m" — matches the
  /// `${integration.hms}` interpolation token.
  String get integrationHms {
    final secs = integrationSecs.round();
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0 && m > 0) return '${h}h${m}m';
    if (h > 0) return '${h}h';
    if (m > 0 && s > 0) return '${m}m${s}s';
    if (m > 0) return '${m}m';
    return '${s}s';
  }

  BroadcastSessionState copyWith({
    bool? active,
    int? port,
    String? path,
    LiveStackingMode? mode,
    LiveStackingMethod? stackMethod,
    String? authToken,
    String? watermarkText,
    int? thumbnailWidth,
    int? thumbnailHeight,
    int? framesStacked,
    DateTime? activatedAt,
    String? currentTarget,
    double? integrationSecs,
    Uint8List? jpegBytes,
    int? viewerCount,
  }) {
    return BroadcastSessionState(
      active: active ?? this.active,
      port: port ?? this.port,
      path: path ?? this.path,
      mode: mode ?? this.mode,
      stackMethod: stackMethod ?? this.stackMethod,
      authToken: authToken ?? this.authToken,
      watermarkText: watermarkText ?? this.watermarkText,
      thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
      thumbnailHeight: thumbnailHeight ?? this.thumbnailHeight,
      framesStacked: framesStacked ?? this.framesStacked,
      activatedAt: activatedAt ?? this.activatedAt,
      currentTarget: currentTarget ?? this.currentTarget,
      integrationSecs: integrationSecs ?? this.integrationSecs,
      jpegBytes: jpegBytes ?? this.jpegBytes,
      viewerCount: viewerCount ?? this.viewerCount,
    );
  }

  /// JSON view returned by `/api/broadcast/info`.
  Map<String, dynamic> toInfoJson() => {
    'active': active,
    'port': port,
    'path': path,
    'mode': mode.storageKey,
    'stackMethod': stackMethod.storageKey,
    'isPublic': isPublic,
    'requiresAuth': !isPublic,
    'framesStacked': framesStacked,
    'integrationSecs': integrationSecs,
    'integrationHms': integrationHms,
    'currentTarget': currentTarget,
    'activatedAt': activatedAt?.toUtc().toIso8601String(),
    'thumbnailWidth': thumbnailWidth,
    'thumbnailHeight': thumbnailHeight,
    'viewerCount': viewerCount,
  };
}

/// Event the broadcast SSE handler emits to subscribers.
class BroadcastUpdate {
  /// Total frames in the current broadcast stack.
  final int framesStacked;

  /// Cumulative integration time, seconds.
  final double integrationSecs;

  /// ISO-8601 server-time the update was produced.
  final DateTime timestamp;

  BroadcastUpdate({
    required this.framesStacked,
    required this.integrationSecs,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'framesStacked': framesStacked,
    'integrationSecs': integrationSecs,
    'timestamp': timestamp.toUtc().toIso8601String(),
  };
}

/// Coordinates between the LiveStacking node, the live-stacking
/// service, and the broadcast HTTP endpoints.
class LiveStackingBroadcastService {
  final Ref _ref;
  final StreamController<BroadcastUpdate> _updates =
      StreamController<BroadcastUpdate>.broadcast();
  BroadcastSessionState _state = const BroadcastSessionState();

  /// Master kill switch mirrored from
  /// `SequencerDefaults.livestackingDisableEverywhere`. When true, every
  /// `activate()` call is a no-op and any currently-active session is
  /// forced into the deactivated state. The user's per-node settings
  /// stay intact — flipping the master switch back off lets new nodes
  /// activate normally on next entry.
  bool _killSwitch = false;
  bool get killSwitchEnabled => _killSwitch;

  /// Shared image-composition logic (stretch + watermark + stat overlay).
  /// The broadcast and the Stack-and-Share export delegate to one renderer so
  /// their overlays are byte-identical. Injectable for tests.
  final ShareCardRenderer _renderer;

  LiveStackingBroadcastService(
    this._ref, {
    ShareCardRenderer renderer = const ShareCardRenderer(),
  }) : _renderer = renderer;

  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Subscribe to broadcast updates. The handler implementation maps
  /// each event onto an SSE message; the dashboard panel can also
  /// listen for a "frame badge" counter.
  Stream<BroadcastUpdate> get updates => _updates.stream;

  /// Current snapshot of the broadcast state. Cheap; safe to call
  /// every HTTP request.
  BroadcastSessionState get state => _state;

  /// Flip the master kill switch. When [enabled] is true,
  /// any active session is force-deactivated and subsequent
  /// `activate()` calls are no-ops until the switch is cleared. The
  /// settings layer calls this whenever
  /// `SequencerDefaults.livestackingDisableEverywhere` changes.
  void setKillSwitch(bool enabled) {
    if (_killSwitch == enabled) return;
    _killSwitch = enabled;
    if (enabled && _state.active) {
      _logger.warning(
        'Broadcast force-deactivated: master kill switch engaged',
        source: 'BroadcastService',
      );
      _state = const BroadcastSessionState();
    }
  }

  /// Activate the broadcast for a given [LiveStackingNode]. Called
  /// when the sequence executor enters the node. Replacing an existing
  /// session is allowed (last-one-wins) so two nodes in the same
  /// sequence cannot lock each other out.
  void activate(LiveStackingNode node) {
    if (_killSwitch) {
      _logger.info(
        'Broadcast activation suppressed: master kill switch engaged',
        source: 'BroadcastService',
      );
      return;
    }
    _state = BroadcastSessionState(
      active: true,
      port: node.broadcastPort,
      path: node.broadcastPath,
      mode: node.mode,
      stackMethod: node.stackMethod,
      authToken: node.authToken,
      watermarkText: node.watermarkText,
      thumbnailWidth: node.thumbnailWidth,
      thumbnailHeight: node.thumbnailHeight,
      activatedAt: DateTime.now(),
    );
    _logger.info(
      'Broadcast activated on port ${node.broadcastPort} '
      '(${node.isPublic ? "public" : "private"}, '
      '${node.stackMethod.label})',
      source: 'BroadcastService',
    );
  }

  /// Tear down the active session. Called on sequence stop, or by the
  /// "Stop broadcasting" button on the dashboard.
  void deactivate() {
    if (!_state.active) return;
    _logger.info(
      'Broadcast deactivated (frames=${_state.framesStacked})',
      source: 'BroadcastService',
    );
    _state = const BroadcastSessionState();
  }

  /// Increment the viewer-count hint. Called by `/api/broadcast/info`
  /// on each request; the count decays via a 30-second idle reset in
  /// the handler so disconnected viewers eventually drop off.
  void incrementViewers() {
    if (!_state.active) return;
    _state = _state.copyWith(viewerCount: _state.viewerCount + 1);
  }

  /// Reset the viewer count. Called on a fixed cadence by the
  /// dashboard panel's refresh timer so the displayed count tracks
  /// recent activity rather than lifetime hits.
  void resetViewerCount() {
    if (!_state.active) return;
    _state = _state.copyWith(viewerCount: 0);
  }

  /// Update the broadcast's current-target metadata. Called by the
  /// dashboard's frame-accepted listener so the watermark / `/info`
  /// JSON always reflect the live target name.
  void updateCurrentTarget(String? targetName) {
    if (!_state.active) return;
    if (_state.currentTarget == targetName) return;
    _state = _state.copyWith(currentTarget: targetName);
  }

  /// Feed a newly-stacked u16 preview into the broadcast. The
  /// LiveStackingNotifier already calls into the engine and updates
  /// its own preview field; we re-encode that to a watermarked JPEG
  /// here so HTTP requests can be served without re-stretching the
  /// 16-bit data on every poll.
  ///
  /// [exposureSecs] is added to the accumulated integration counter.
  void publishFrame({
    required int width,
    required int height,
    required Uint16List previewData,
    required double exposureSecs,
  }) {
    if (!_state.active) return;
    if (width <= 0 || height <= 0 || previewData.isEmpty) return;

    // The shared renderer owns the stretch + watermark + encode; the spec
    // (see [_broadcastSpec]) pins the broadcast's own look.
    final jpeg = _renderer.renderJpegFromMono(
      width: width,
      height: height,
      data: previewData,
      spec: _broadcastSpec(),
      quality: 82,
    );

    _state = _state.copyWith(
      framesStacked: _state.framesStacked + 1,
      integrationSecs: _state.integrationSecs + exposureSecs,
      jpegBytes: jpeg,
    );

    final update = BroadcastUpdate(
      framesStacked: _state.framesStacked,
      integrationSecs: _state.integrationSecs,
      timestamp: DateTime.now(),
    );
    if (!_updates.isClosed) {
      _updates.add(update);
    }
  }

  /// Validate the `token` query parameter against the active session.
  ///
  /// Returns true when the request is allowed (public broadcast OR the
  /// supplied token matches). The caller maps `false` to HTTP 401.
  bool authorize(String? suppliedToken) {
    if (!_state.active) return false;
    if (_state.isPublic) return true;
    if (suppliedToken == null || suppliedToken.isEmpty) return false;
    // Constant-time comparison. The token is a shared secret; a
    // straight `==` would leak length / prefix information through
    // timing. The cost on a short token is negligible.
    return _constantTimeEqual(suppliedToken, _state.authToken ?? '');
  }

  /// Render the watermark template against the
  /// live session state. Exposed so callers (HTML page, tests) can
  /// preview the rendered string without forcing a JPEG re-encode.
  String renderWatermark() {
    final template = _state.watermarkText;
    if (template == null || template.trim().isEmpty) return '';
    return expandWatermarkTokens(template, _watermarkTokens(_state));
  }

  /// Dispose all resources. Called when the provider is torn down.
  void dispose() {
    _updates.close();
  }

  // Internal: share-card spec + watermark tokens

  /// Build the [ShareCardSpec] the shared [ShareCardRenderer] uses to render a
  /// broadcast frame: aspect-fit downscale to the configured thumbnail box,
  /// the rendered watermark text in the large font, and no stat panel — the
  /// broadcast page renders telemetry itself, so the JPEG stays a clean image.
  ShareCardSpec _broadcastSpec() {
    return ShareCardSpec(
      title: '',
      watermark: renderWatermark(),
      targetWidth: _state.thumbnailWidth,
      targetHeight: _state.thumbnailHeight,
      // No stats → the renderer draws only the watermark, matching the
      // pre-extraction broadcast output.
      layout: ShareCardLayout.bottomBar,
      // The pre-extraction `_drawWatermark` always used `img.arial48`. The
      // default 720px thumbnail would otherwise resolve to arial24 under the
      // height-based policy, halving the outreach overlay's glyph size — so we
      // pin the large font to preserve that look exactly.
      fontScale: ShareCardFontScale.large,
    );
  }

  /// Map the live [session] state onto the watermark token vocabulary the
  /// shared [expandWatermarkTokens] helper consumes. The broadcast owns this
  /// mapping (it knows what `${integration.hms}` etc. mean for its state);
  /// the helper owns the `${...}` string machinery.
  ///
  /// Must stay in lockstep with [watermarkVariableCatalog], which is what the
  /// watermark field's insert control offers — an offered token this map does
  /// not answer renders literally into the broadcast JPEG.
  Map<String, String> _watermarkTokens(BroadcastSessionState session) {
    return {
      'target': session.currentTarget ?? '',
      'target.name': session.currentTarget ?? '',
      'integration.hms': session.integrationHms,
      'integration.secs': session.integrationSecs.toStringAsFixed(0),
      'frames': session.framesStacked.toString(),
      'stack': session.stackMethod.label,
      'stack.method': session.stackMethod.label,
      'now': DateTime.now().toLocal().toString().substring(0, 19),
    };
  }

  /// Constant-time string compare to gate auth tokens.
  bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Provider for the broadcast service. Singleton per app — the HTTP
/// handler reads from this every request.
final liveStackingBroadcastServiceProvider =
    Provider<LiveStackingBroadcastService>((ref) {
      final svc = LiveStackingBroadcastService(ref);
      ref.onDispose(svc.dispose);
      return svc;
    });

/// Bridges the "Disable broadcast everywhere" toggle in
/// Sequencer Settings (`SequencerDefaults.livestackingDisableEverywhere`)
/// into the live broadcast service. Watched once at app start by the
/// shell so the kill switch:
///
///   * applies on cold start (a process that started with the switch on
///     comes up disabled, not in a brief "armed" window), and
///   * propagates live: flipping the toggle during an active broadcast
///     force-deactivates the session.
final liveStackingKillSwitchBridgeProvider = Provider<void>((ref) {
  final svc = ref.watch(liveStackingBroadcastServiceProvider);
  // Initial seed: read once, apply.
  final initial = ref.watch(sequencerDefaultsProvider);
  svc.setKillSwitch(initial.livestackingDisableEverywhere);
  // No explicit listener needed — `ref.watch` rebuilds this provider
  // whenever the kill-switch field changes, which re-runs the setter
  // above. The Provider re-evaluation is cheap because setKillSwitch
  // is a no-op when the value hasn't changed.
});

/// Convenience provider for whether the broadcast is currently armed.
/// The dashboard's "Broadcasting" indicator watches this.
final broadcastActiveProvider = Provider<bool>((ref) {
  return ref.watch(liveStackingBroadcastServiceProvider).state.active;
});
