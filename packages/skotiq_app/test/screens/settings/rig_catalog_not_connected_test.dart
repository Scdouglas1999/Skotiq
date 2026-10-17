// With no appliance connected, Settings › Appliance Catalogs must still offer a
// way in. A single sentence — "Connect to a remote appliance to manage its
// catalogs. This is separate from the phone's own planetarium catalogs." — and
// nothing else leaves the leaf inert on a Linux/Windows desktop where there is
// no phone and no button, picker or link to the connection flow it names.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/rig_catalog_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A local (non-network) backend: exactly the desktop-with-no-appliance case.
class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Future<GoRouter> _pump(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (_, __) =>
            const Scaffold(body: RigCatalogSettings(isMobile: true)),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, _MockLocalBackend()),
        ),
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the not-connected page never calls this machine a phone',
      (tester) async {
    await _pump(tester);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');
    expect(texts.toLowerCase(), isNot(contains('phone')));
    expect(texts, contains("this device's own planetarium catalogs"));
  });

  testWidgets('the not-connected page offers a way to reach the connect flow',
      (tester) async {
    final router = await _pump(tester);

    final connect = find.widgetWithText(SkotiqButton, 'Connect an appliance');
    expect(connect, findsOneWidget);
    expect(tester.widget<SkotiqButton>(connect).onPressed, isNotNull);

    await tester.tap(connect);
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/settings?section=remote-access',
    );
  });
}
