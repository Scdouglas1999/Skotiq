// How a session resolves to something the Darkroom can open.
//
// This is what the Analytics session dialog and the Stack Result header both
// lean on. The failure it guards against is a "Refine in Darkroom" control that
// opens an empty editor: a night that was never integrated, a master still
// accumulating with no FITS written, or a remote client with no access to the
// host's disk each has to produce a sentence, not a blank screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A resolver that answers with a scripted set instead of reading a database.
class _ScriptedResolver implements DawnMasterResolver {
  _ScriptedResolver(this.set);

  final DawnMasterSet set;

  @override
  Future<DawnMasterSet> resolve(int sessionId) async => set;
}

DawnMaster _master(int id) => DawnMaster(
      masterId: id,
      targetId: 1,
      name: 'M31 Ha',
      filter: 'Ha',
      masterFitsPath: '/masters/m31_ha.fits',
      channels: 1,
      width: 4000,
      height: 3000,
      frameCount: 40,
      totalIntegrationSeconds: 12000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Run [body] with a WidgetRef from a mounted Consumer.
  Future<T> withRef<T>(
    WidgetTester tester,
    List<Override> overrides,
    Future<T> Function(WidgetRef ref) body,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    return body(captured);
  }

  testWidgets('a night with a master resolves to that master', (tester) async {
    final target = await withRef(
      tester,
      [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, DisconnectedBackend()),
        ),
        dawnMasterResolverProvider.overrideWithValue(
          _ScriptedResolver(
            DawnMasterSet(
              sessionId: 3,
              masters: [_master(11), _master(12)],
              withoutFile: const [],
            ),
          ),
        ),
      ],
      (ref) => resolveDarkroomTargetForSession(ref, 3),
    );

    expect(target.masterId, 11);
    expect(target.unavailableReason, isNull);
  });

  testWidgets('a remote client is told where the Darkroom lives', (
    tester,
  ) async {
    final target = await withRef(
      tester,
      [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, _MockNetworkBackend()),
        ),
        dawnMasterResolverProvider.overrideWithValue(
          _ScriptedResolver(
            DawnMasterSet(
              sessionId: 3,
              masters: [_master(11)],
              withoutFile: const [],
            ),
          ),
        ),
      ],
      (ref) => resolveDarkroomTargetForSession(ref, 3),
    );

    expect(target.masterId, isNull);
    expect(target.unavailableReason, contains('imaging host'));
  });

  testWidgets(
    'a --remote-host client that has not reached its rig is told where the '
    'Darkroom lives, not handed the client\'s own masters',
    (tester) async {
      // The launch flag makes this process the rig's client; the backend is
      // still `Disconnected` because the handshake has not happened. Gating on
      // `backendProvider is NetworkBackend` read false for that whole window,
      // so this resolver went on to read the CLIENT's database and hand back a
      // master id — the editor then opened over recipes no dawn job would read.
      final target = await withRef(
        tester,
        [
          remoteClientLaunchProvider.overrideWithValue(true),
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
          dawnMasterResolverProvider.overrideWithValue(
            _ScriptedResolver(
              DawnMasterSet(
                sessionId: 3,
                masters: [_master(11)],
                withoutFile: const [],
              ),
            ),
          ),
        ],
        (ref) => resolveDarkroomTargetForSession(ref, 3),
      );

      expect(target.masterId, isNull);
      expect(target.unavailableReason, contains('imaging host'));
    },
  );

  testWidgets('a night that was never integrated says so', (tester) async {
    final target = await withRef(
      tester,
      [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, DisconnectedBackend()),
        ),
        dawnMasterResolverProvider.overrideWithValue(
          _ScriptedResolver(
            const DawnMasterSet(
              sessionId: 3,
              masters: [],
              withoutFile: [],
            ),
          ),
        ),
      ],
      (ref) => resolveDarkroomTargetForSession(ref, 3),
    );

    expect(target.masterId, isNull);
    expect(target.unavailableReason, contains('no integrated master yet'));
  });

  testWidgets('an accumulating master repeats the resolver\'s own reason', (
    tester,
  ) async {
    final target = await withRef(
      tester,
      [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, DisconnectedBackend()),
        ),
        dawnMasterResolverProvider.overrideWithValue(
          _ScriptedResolver(
            const DawnMasterSet(
              sessionId: 3,
              masters: [],
              withoutFile: [
                DawnMasterWithoutFile(
                  masterId: 4,
                  name: 'M31 Ha',
                  reason: 'this master is still accumulating',
                ),
              ],
            ),
          ),
        ),
      ],
      (ref) => resolveDarkroomTargetForSession(ref, 3),
    );

    expect(target.masterId, isNull);
    expect(
        target.unavailableReason, 'M31 Ha: this master is still accumulating.');
  });

  // A master card names its row, so it needs no session lookup — but it needs
  // the same role question, and it was not asking it. The session-level control
  // refused inline while this one navigated to the host-only Darkroom screen:
  // two controls, two answers, on the same launch.
  group('the master-row entry point', () {
    /// A two-route app whose home carries the control under test. The Darkroom
    /// route reports the master it was scoped to, so the assertion reads what
    /// the screen would have opened rather than a router internal.
    Future<GoRouter> pumpRow(
      WidgetTester tester,
      List<Override> overrides,
    ) async {
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => openDarkroomForMasterRow(context, ref, 7),
                  child: const Text('Darkroom'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/darkroom',
            builder: (context, state) => Scaffold(
              body:
                  Text('the editor on ${state.uri.queryParameters['master']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('a host opens the Darkroom on that row', (tester) async {
      final router = await pumpRow(tester, [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, DisconnectedBackend()),
        ),
      ]);

      await tester.tap(find.text('Darkroom'));
      await tester.pumpAndSettle();

      expect(find.text('the editor on 7'), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.last.matchedLocation,
        '/darkroom',
      );
    });

    testWidgets(
      'a --remote-host client refuses in the same words as every other entry '
      'point, and does not navigate',
      (tester) async {
        final router = await pumpRow(tester, [
          remoteClientLaunchProvider.overrideWithValue(true),
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
        ]);

        await tester.tap(find.text('Darkroom'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          router.routerDelegate.currentConfiguration.uri.toString(),
          '/home',
          reason: 'no Darkroom control on a client may land on a gate screen',
        );
        expect(find.textContaining('the editor'), findsNothing);
        expect(find.text(kDarkroomHostOnlyRefusal), findsOneWidget);
      },
    );

    testWidgets('a connected client refuses the same way', (tester) async {
      final router = await pumpRow(tester, [
        backendProvider.overrideWith(
          (ref) => _PinnedBackend(ref, _MockNetworkBackend()),
        ),
      ]);

      await tester.tap(find.text('Darkroom'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        '/home',
      );
      expect(find.text(kDarkroomHostOnlyRefusal), findsOneWidget);
    });

    testWidgets('the session resolver refuses in exactly those words', (
      tester,
    ) async {
      // One sentence, shared. If these ever drift apart the two entry points
      // are back to explaining the same machine two different ways.
      final target = await withRef(
        tester,
        [
          remoteClientLaunchProvider.overrideWithValue(true),
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
          dawnMasterResolverProvider.overrideWithValue(
            _ScriptedResolver(
              DawnMasterSet(
                sessionId: 3,
                masters: [_master(11)],
                withoutFile: const [],
              ),
            ),
          ),
        ],
        (ref) => resolveDarkroomTargetForSession(ref, 3),
      );

      expect(target.unavailableReason, kDarkroomHostOnlyRefusal);
    });
  });
}
