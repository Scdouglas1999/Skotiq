// The session review's header builds masters through the Darkroom's guided
// build for the night's target, the same path as the review's own shortcut,
// and offers no per-night Darkroom pass of its own.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/session_review_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import 'seeded_review_fixture.dart';

/// Pins the backend so the screen's host-only gate resolves without the real
/// notifier's connection polling leaving a timer alive past teardown.
class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late String previewPath;

  setUp(() async {
    db = mockDatabase();
    previewPath = await _writeSamplePng();
  });

  tearDown(() async {
    await db.close();
  });

  Future<GoRouter> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const scope = SessionReviewScope.session(1);
    final router = GoRouter(
      initialLocation: '/session-review',
      routes: [
        GoRoute(
          path: '/session-review',
          builder: (context, state) => const SessionReviewScreen(scope: scope),
        ),
        GoRoute(
          path: '/darkroom',
          builder: (context, state) => const Text('Darkroom'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
          ...seededReviewOverrides(
            db: db,
            scope: scope,
            previewPath: previewPath,
          ),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    return router;
  }

  /// Unmount and let the toast overlay's timers run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('the header opens the target\'s framing check in the Darkroom', (
    tester,
  ) async {
    final router = await pumpScreen(tester);

    expect(
        find.byKey(const ValueKey('session_review_process_now')), findsNothing);
    expect(
        find.byKey(const ValueKey('session_review_stop_pass')), findsNothing);
    final header = find.byKey(const ValueKey('session_review_header_build'));
    expect(header, findsOneWidget);
    final button = tester.widget<SkotiqButton>(header);
    expect(button.label, 'Build masters in the Darkroom');

    // Pressed through its own callback: the seeded fixture's shortfall toast
    // sits across the header for its whole dwell.
    button.onPressed!();
    await tester.pump();
    await tester.pump();

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/darkroom?tab=targets&target=NGC+7000&view=framing',
    );
    await finish(tester);
  });
}

Future<String> _writeSamplePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 40, 30),
    Paint()..color = const Color(0xFF102030),
  );
  final image = await recorder.endRecording().toImage(40, 30);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = await Directory.systemTemp.createTemp('session_review_header');
  final file = File('${dir.path}/hero.png');
  await file.writeAsBytes(Uint8List.view(bytes!.buffer));
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return file.path;
}
