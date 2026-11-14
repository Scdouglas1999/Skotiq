import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

// A live-stacking broadcast runs in the host's run. Tonight shows its link
// while one is armed, on the host and on every linked client.
class _HostBackendNotifier extends BackendNotifier {
  _HostBackendNotifier(super.ref) : super() {
    state = DisconnectedBackend();
  }
}

LiveStackingNode _node({String? token = 's3cret', bool broadcast = true}) =>
    LiveStackingNode(
      id: 'ls',
      authToken: token,
      broadcastEnabled: broadcast,
      watermarkText: r'${frames} frames',
    );

ProviderContainer _host() {
  final container = ProviderContainer(
    overrides: [backendProvider.overrideWith(_HostBackendNotifier.new)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  const channel = LiveBroadcastChannel();

  test('is in the shared list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      runtimeChannelFor(
        container.read(runtimeMirrorChannelsProvider),
        'liveBroadcast',
      ),
      isA<LiveBroadcastChannel>(),
    );
  });

  test('nothing is shown until a broadcast is armed', () {
    final container = _host();
    expect(container.read(liveBroadcastProvider), isNull);
  });

  test('a node with its broadcast switched off arms none', () {
    final container = _host();
    container
        .read(liveStackingBroadcastServiceProvider)
        .activate(_node(broadcast: false));
    expect(container.read(liveBroadcastProvider), isNull);
  });

  test('an armed broadcast follows the stack and the server', () async {
    final container = _host();
    final seen = <LiveBroadcast?>[];
    container.listen(liveBroadcastProvider, (_, next) => seen.add(next));
    final service = container.read(liveStackingBroadcastServiceProvider);

    service.activate(_node());
    await Future<void>.delayed(Duration.zero);
    var shown = container.read(liveBroadcastProvider)!;
    expect(shown.reach, LiveBroadcastReach.serverOff);
    expect(shown.audienceUrl, isNull);
    expect(seen, isNotEmpty);

    final server = container.read(webServerStateProvider.notifier);
    server.setRunning(isRunning: true, actualPort: 8080, bindLocalOnly: true);
    expect(
      container.read(liveBroadcastProvider)!.reach,
      LiveBroadcastReach.thisComputerOnly,
    );
    server.setRunning(isRunning: true, actualPort: 8080, bindLocalOnly: false);
    shown = container.read(liveBroadcastProvider)!;
    expect(shown.reach, LiveBroadcastReach.open);
    // The server serves the page at its own fixed path, whatever the node says.
    expect(shown.pageUrl, endsWith(':8080/broadcast'));
    expect(shown.audienceUrl, '${shown.pageUrl}?token=s3cret');
    expect(shown.shownUrl, '${shown.pageUrl}?token=…');
    expect(shown.watermark, '0 frames');

    service.deactivate();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(liveBroadcastProvider), isNull);
  });

  test('a public broadcast hands out the bare page', () {
    const broadcast = LiveBroadcast(
      isPublic: true,
      stackMethod: 'Average',
      frames: 3,
      integrationSecs: 90,
      viewers: 1,
      reach: LiveBroadcastReach.open,
      pageUrl: 'http://10.0.0.2:8080/broadcast',
    );
    expect(broadcast.audienceUrl, 'http://10.0.0.2:8080/broadcast');
    expect(broadcast.shownUrl, 'http://10.0.0.2:8080/broadcast');
  });

  test('round-trips through JSON', () {
    const broadcast = LiveBroadcast(
      isPublic: false,
      stackMethod: 'Sigma clip',
      target: 'M 33',
      frames: 14,
      integrationSecs: 840,
      viewers: 3,
      reach: LiveBroadcastReach.thisComputerOnly,
      pageUrl: 'http://127.0.0.1:8080/broadcast',
      token: 'a b&c',
      watermark: 'M 33 · 14 frames',
    );
    final wire =
        jsonDecode(jsonEncode(channel.encode(broadcast)))
            as Map<String, dynamic>;
    expect(LiveBroadcast.fromJson(wire), broadcast);
    expect(channel.encode(null), isNull);
    expect(broadcast.audienceUrl, endsWith('?token=a+b%26c'));
  });
}
