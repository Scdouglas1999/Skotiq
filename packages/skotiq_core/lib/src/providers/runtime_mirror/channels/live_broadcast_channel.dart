import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_remote_protocol/wire.dart' show BroadcastApi;

import '../../../services/live_stacking_broadcast_service.dart';
import '../../../backend/remote_host.dart';
import '../../backend_provider.dart';
import '../../web_server_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';
import '../../live_stacking_broadcast_service_providers.dart';

/// Whether the audience can open a live broadcast.
enum LiveBroadcastReach {
  /// The host's server answers on the network.
  open,

  /// The server answers on this computer only.
  thisComputerOnly,

  /// No server is running, so the page cannot be opened at all.
  serverOff,
}

/// A live-stacking broadcast as the operator sees it: what is being shared,
/// and the address the audience opens.
@immutable
class LiveBroadcast {
  const LiveBroadcast({
    required this.isPublic,
    required this.stackMethod,
    required this.frames,
    required this.integrationSecs,
    required this.viewers,
    required this.reach,
    this.target,
    this.pageUrl,
    this.token,
    this.watermark = '',
  });

  final bool isPublic;

  /// The stack method's label ("Average").
  final String stackMethod;
  final String? target;
  final int frames;
  final double integrationSecs;
  final int viewers;
  final LiveBroadcastReach reach;

  /// The page's address without its token; null while no server runs.
  final String? pageUrl;

  /// The private broadcast's token, which the audience's link carries.
  final String? token;

  /// The watermark burned into the shared frames, rendered.
  final String watermark;

  /// The link to hand out: with the token for a private broadcast.
  String? get audienceUrl {
    final page = pageUrl;
    if (page == null) return null;
    final token = this.token;
    if (isPublic || token == null || token.isEmpty) return page;
    return '$page?token=${Uri.encodeQueryComponent(token)}';
  }

  /// The address as it is shown on screen: the token is never written out.
  String? get shownUrl {
    final page = pageUrl;
    if (page == null || isPublic) return page;
    return '$page?token=…';
  }

  Map<String, dynamic> toJson() => {
    'isPublic': isPublic,
    'stackMethod': stackMethod,
    'target': target,
    'frames': frames,
    'integrationSecs': finiteOrNull(integrationSecs),
    'viewers': viewers,
    'reach': reach.name,
    'pageUrl': pageUrl,
    'token': token,
    'watermark': watermark,
  };

  static LiveBroadcast fromJson(Map<String, dynamic> json) => LiveBroadcast(
    isPublic: json['isPublic'] == true,
    stackMethod: jsonString(json['stackMethod']) ?? '',
    target: jsonString(json['target']),
    frames: requireInt(json, 'frames'),
    integrationSecs: jsonDouble(json['integrationSecs']) ?? 0,
    viewers: requireInt(json, 'viewers'),
    reach: LiveBroadcastReach.values.firstWhere(
      (r) => r.name == json['reach'],
      orElse: () => LiveBroadcastReach.serverOff,
    ),
    pageUrl: jsonString(json['pageUrl']),
    token: jsonString(json['token']),
    watermark: jsonString(json['watermark']) ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is LiveBroadcast &&
      other.isPublic == isPublic &&
      other.stackMethod == stackMethod &&
      other.target == target &&
      other.frames == frames &&
      other.integrationSecs == integrationSecs &&
      other.viewers == viewers &&
      other.reach == reach &&
      other.pageUrl == pageUrl &&
      other.token == token &&
      other.watermark == watermark;

  @override
  int get hashCode => Object.hash(
    isPublic,
    stackMethod,
    target,
    frames,
    integrationSecs,
    viewers,
    reach,
    pageUrl,
    token,
    watermark,
  );
}

/// The broadcast this process runs, rebuilt on every change of it.
final _localBroadcastStateProvider = Provider<BroadcastSessionState>((ref) {
  final service = ref.watch(liveStackingBroadcastServiceProvider);
  final subscription = service.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return service.state;
});

/// The host's broadcast as a linked client last heard it.
final _mirroredLiveBroadcastProvider = StateProvider<LiveBroadcast?>(
  (ref) => null,
);

/// The live-stacking broadcast armed on the imaging host, or null while none
/// is. A host reads its own; a linked client reads the host's through
/// [LiveBroadcastChannel].
final liveBroadcastProvider = Provider<LiveBroadcast?>((ref) {
  if (ref.watch(backendProvider).remoteHost != null) {
    return ref.watch(_mirroredLiveBroadcastProvider);
  }
  final state = ref.watch(_localBroadcastStateProvider);
  if (!state.active) return null;
  final server = ref.watch(webServerStateProvider);
  // The page is served by the API server at a fixed path; the node's own
  // port and path are not what the server binds.
  final pageUrl = server.isRunning
      ? 'http://${server.localIp.isEmpty ? 'localhost' : server.localIp}'
            ':${server.actualPort}${BroadcastApi.page.route.path}'
      : null;
  return LiveBroadcast(
    isPublic: state.isPublic,
    stackMethod: state.stackMethod.label,
    target: state.currentTarget,
    frames: state.framesStacked,
    integrationSecs: state.integrationSecs,
    viewers: state.viewerCount,
    reach: !server.isRunning
        ? LiveBroadcastReach.serverOff
        : server.bindLocalOnly
        ? LiveBroadcastReach.thisComputerOnly
        : LiveBroadcastReach.open,
    pageUrl: pageUrl,
    token: state.authToken,
    watermark: ref.read(liveStackingBroadcastServiceProvider).renderWatermark(),
  );
});

/// The live-stacking broadcast the host runs. The broadcast lives in the
/// host's run, so a linked client had no way to show its link.
class LiveBroadcastChannel extends RuntimeMirrorChannel<LiveBroadcast?> {
  const LiveBroadcastChannel();

  @override
  String get key => 'liveBroadcast';

  @override
  get source => liveBroadcastProvider;

  /// Every audience poll changes the viewer count.
  @override
  Duration get minInterval => const Duration(seconds: 2);

  @override
  Map<String, dynamic>? encode(LiveBroadcast? value) => value?.toJson();

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (context.networkBackend == null) return;
    context.read(_mirroredLiveBroadcastProvider.notifier).state = value == null
        ? null
        : LiveBroadcast.fromJson(value);
  }
}
