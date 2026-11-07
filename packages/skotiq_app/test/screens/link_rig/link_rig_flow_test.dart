// The desktop connect flow: one tap pairs and restarts linked, the code path
// asks for full access, the linked panel offers the way back, and a banner on
// a rejected token offers pairing again instead of a token to paste.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/link_rig/link_rig_dialog.dart';
import 'package:skotiq_app/screens/link_rig/linked_rig_panel.dart';
import 'package:skotiq_app/widgets/disconnected_backend_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Relauncher implements AppRelauncher {
  final reasons = <String>[];
  @override
  Future<bool> relaunch({required String reason}) async {
    reasons.add(reason);
    return true;
  }
}

class _FakeLinkService extends RigLinkService {
  _FakeLinkService(LinkedRigStore store) : super(store: store);

  final calls = <String>[];
  RigPairingFailure? oneTapFailure;

  @override
  Future<RigPairing> pairOneTap(
    DiscoveredServer host, {
    required String deviceName,
  }) async {
    calls.add('oneTap:${host.host}:$deviceName');
    if (oneTapFailure != null) throw oneTapFailure!;
    return const RigPairing(token: 'tok', scope: 'control');
  }

  @override
  Future<RigPairing> pairWithCode(
    DiscoveredServer host, {
    required String code,
    required String deviceName,
    required bool fullAccess,
  }) async {
    calls.add('code:$code:$fullAccess');
    return RigPairing(token: 'tok', scope: fullAccess ? 'admin' : 'control');
  }
}

class _DisconnectedNotifier extends BackendNotifier {
  _DisconnectedNotifier(super.ref) {
    state = DisconnectedBackend();
  }
}

class _FixedStatus extends RemoteLaunchStatusNotifier {
  _FixedStatus(super.ref, RemoteLaunchStatus s) {
    state = s;
  }
  @override
  Future<bool> connect() async => false;
}

final _host = DiscoveredServer(
  host: '192.168.1.32',
  webPort: 8099,
  name: 'Skotiq',
  hostName: 'DESKTOP-MMAJGAK',
  platform: 'windows',
  version: '8.2.1',
  fingerprint: 'dc2f261109b13423267823392fce64406b21767a95928a2e13eebef17fa85016',
  lanPairing: true,
);

final _rig = LinkedRig(
  host: '192.168.1.32',
  port: 8099,
  name: 'DESKTOP-MMAJGAK',
  tokenScope: 'control',
  pairedAt: DateTime.utc(2026, 11, 7),
);

void main() {
  late Directory dir;
  late LinkedRigStore store;
  late _FakeLinkService service;
  late _Relauncher relauncher;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('link_rig_flow');
    store = LinkedRigStore(
      dataDirectory: () async => dir,
      secureStore: InMemorySecureKeyValueStore(),
    );
    service = _FakeLinkService(store);
    relauncher = _Relauncher();
  });
  tearDown(() => dir.delete(recursive: true));

  Widget app(Widget child, {List<Override> extra = const []}) => ProviderScope(
    overrides: [
      linkedRigStoreProvider.overrideWithValue(store),
      rigLinkServiceProvider.overrideWithValue(service),
      appRelauncherProvider.overrideWithValue(relauncher),
      ...extra,
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );

  Future<void> setSize(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('one tap pairs, remembers the rig and restarts linked', (
    tester,
  ) async {
    await setSize(tester);
    await tester.pumpWidget(
      app(LinkRigDialog(request: LinkRigRequest.pair(_host))),
    );
    await tester.pump();

    expect(find.text('DESKTOP-MMAJGAK'), findsOneWidget);
    expect(find.text('Windows · Skotiq 8.2.1 · 192.168.1.32:8099'),
        findsOneWidget);
    expect(find.text('Identity dc2f 2611 09b1 3423'), findsOneWidget);
    // Nothing on the screen asks for a token.
    expect(find.textContaining('token'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('link.oneTap')));
      for (var i = 0; i < 20 && relauncher.reasons.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    expect(service.calls.single, startsWith('oneTap:192.168.1.32:Skotiq on'));
    expect(relauncher.reasons, ['Linked to DESKTOP-MMAJGAK']);
    final saved = await tester.runAsync(store.load);
    expect(saved!.active, isTrue);
    expect(saved.fingerprint, _host.fingerprint);
    expect(await tester.runAsync(store.readToken), 'tok');
  });

  testWidgets('a host that wants a code says so, and the code asks for admin',
      (tester) async {
    await setSize(tester);
    service.oneTapFailure = const RigPairingFailure(
      RigPairingFailureKind.oneTapUnavailable,
      'code',
    );
    await tester.pumpWidget(
      app(LinkRigDialog(request: LinkRigRequest.pair(_host))),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('link.oneTap')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump();
    expect(
      find.text('DESKTOP-MMAJGAK asks for a pairing code. Type the code it '
          'shows below.'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const ValueKey('link.code')),
        'orbit nebula 4821');
    await tester.tap(find.byType(SkotiqCheckbox));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('link.pairCode')));
      for (var i = 0; i < 20 && relauncher.reasons.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    expect(service.calls.last, 'code:orbit nebula 4821:true');
    final saved = await tester.runAsync(store.load);
    expect(saved!.tokenScope, 'admin');
  });

  testWidgets('asking for full access offers only the code', (tester) async {
    await setSize(tester);
    await tester.pumpWidget(
      app(
        LinkRigDialog(
          request: LinkRigRequest.pair(_host, fullAccess: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Allow settings changes from here'), findsOneWidget);
    expect(find.byKey(const ValueKey('link.oneTap')), findsNothing);
    expect(find.byKey(const ValueKey('link.code')), findsOneWidget);
  });

  testWidgets('a desktop that owns its rig is offered Connect', (tester) async {
    await setSize(tester);
    await tester.pumpWidget(app(const LinkedRigPanel()));
    await tester.pump();
    expect(find.text('Connect to an imaging computer'), findsOneWidget);
    expect(find.byKey(const ValueKey('linkRig.connect')), findsOneWidget);
  });

  testWidgets('a pairing kept after "use this computer" can be linked again',
      (tester) async {
    await setSize(tester);
    await tester.runAsync(() async {
      await store.save(_rig, token: 't');
      await store.setActive(false);
    });
    await tester.pumpWidget(app(const LinkedRigPanel()));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('Linked before: DESKTOP-MMAJGAK'), findsOneWidget);
    expect(find.text('Link again'), findsOneWidget);
  });

  testWidgets('a linked desktop shows its rig, access and the way back', (
    tester,
  ) async {
    await setSize(tester);
    await tester.pumpWidget(
      app(
        const LinkedRigPanel(),
        extra: [
          remoteLaunchTargetProvider.overrideWithValue(
            const RemoteLaunchTarget(
              host: '192.168.1.32',
              port: 8099,
              name: 'DESKTOP-MMAJGAK',
              remembered: true,
            ),
          ),
          launchLinkedRigProvider.overrideWithValue(_rig),
        ],
      ),
    );
    await tester.pump();
    expect(find.textContaining('Linked to DESKTOP-MMAJGAK'), findsOneWidget);
    expect(find.byKey(const ValueKey('linkRig.fullAccess')), findsOneWidget);
    expect(find.text('Pair again'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('linkRig.useThisComputer')));
    await tester.pumpAndSettle();
    expect(find.text('Use this computer instead?'), findsOneWidget);
  });

  testWidgets('a rejected token offers pairing again, never a token to paste',
      (tester) async {
    await setSize(tester);
    await tester.pumpWidget(
      app(
        const DisconnectedBackendBanner(),
        extra: [
          backendProvider.overrideWith(_DisconnectedNotifier.new),
          remoteLaunchTargetProvider.overrideWithValue(
            const RemoteLaunchTarget(
              host: '192.168.1.32',
              port: 8099,
              name: 'DESKTOP-MMAJGAK',
              remembered: true,
            ),
          ),
          launchLinkedRigProvider.overrideWithValue(_rig),
          remoteLaunchStatusProvider.overrideWith(
            (ref) => _FixedStatus(
              ref,
              const RemoteLaunchStatus.failed(
                RemoteLaunchFailure.tokenRejected,
                '401',
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('remoteBanner.pairAgain')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remoteBanner.useThisComputer')),
      findsOneWidget,
    );
    expect(find.textContaining('Copy the token'), findsNothing);
  });

  test('host descriptions and fingerprints read the way the host shows them',
      () {
    expect(
      describeDiscoveredHost(
        DiscoveredServer(
          host: '10.0.0.2',
          webPort: 8080,
          name: 'pi',
          platform: 'linux',
          hostMode: 'headless',
        ),
      ),
      'Linux · headless · 10.0.0.2:8080',
    );
    expect(formatFingerprint('ABCDEF0123456789ffff'), 'abcd ef01 2345 6789');
  });
}
