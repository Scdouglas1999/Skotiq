// The ways into the Darkroom from Session Review.
//
// Two controls, two different gates. The master card's "Darkroom" button needs
// a LINEAR FITS — a master still accumulating has grown the data without
// writing one — and the header's "Process now" needs a single night, because
// the pass reads one session's frames to find the masters they were folded
// into. Both must state the reason when they are unavailable rather than
// looking broken.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/session_review_screen.dart';
import 'package:skotiq_app/screens/session_review/widgets/master_library_panel.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart';
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

/// Every non-empty name in the published semantics tree, read the way the
/// AT-SPI bridge reads it — off the nodes, not off the widgets that authored
/// them. `WidgetTester.getSemantics` walks UP from the element it is given, so
/// it answers with the enclosing card for a node a widget publishes INSIDE
/// itself; this walks the tree that is actually handed to a screen reader.
List<String> publishedNames(WidgetTester tester) {
  final names = <String>[];
  void walk(SemanticsNode node) {
    final label = node.getSemanticsData().label;
    if (label.isNotEmpty) names.add(label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return names;
}

IntegratedMaster _master({
  required int id,
  required String name,
  String? fitsPath,
  AccumulationMode mode = AccumulationMode.batch,
}) =>
    IntegratedMaster(
      id: id,
      targetId: 1,
      name: name,
      filter: 'Ha',
      masterFitsPath: fitsPath,
      previewPngPath: null,
      sidecarPath: null,
      rejectionMapPath: null,
      width: 4000,
      height: 3000,
      channels: 1,
      frameCount: 40,
      totalIntegrationSeconds: 12000,
      accumulationMode: mode,
      status: mode == AccumulationMode.batch
          ? IntegratedMasterStatus.finalized
          : IntegratedMasterStatus.accumulating,
      settingsJson: '{}',
      statsJson: '{}',
      createdAt: DateTime.utc(2026, 8, 15),
      updatedAt: DateTime.utc(2026, 8, 16),
    );

Widget _panelHarness(Widget child) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the master card opens the Darkroom', () {
    testWidgets('a finished master offers the button and reports the row', (
      tester,
    ) async {
      IntegratedMaster? opened;
      await tester.pumpWidget(
        _panelHarness(
          MasterLibraryPanel(
            masters: [
              _master(id: 7, name: 'M31 Ha', fitsPath: '/masters/m31.fits'),
            ],
            acceptedSubCount: 40,
            busy: false,
            onOpen: (_) {},
            onOpenInDarkroom: (m) => opened = m,
            onAddTonight: (_) {},
            onFinalize: (_) {},
            onDelete: (_) {},
            onCreateAccumulating: () {},
          ),
        ),
      );
      await tester.pump();

      final button = find.byKey(const ValueKey('master_open_in_darkroom'));
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pump();

      expect(opened, isNotNull);
      expect(opened!.id, 7);
    });

    testWidgets('a master with no linear FITS is disabled and says why', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _panelHarness(
          MasterLibraryPanel(
            masters: [
              _master(
                id: 8,
                name: 'M31 Ha (accumulating)',
                fitsPath: null,
                mode: AccumulationMode.runningWeightedMean,
              ),
            ],
            acceptedSubCount: 40,
            busy: false,
            onOpen: (_) {},
            onOpenInDarkroom: (_) => taps++,
            onAddTonight: (_) {},
            onFinalize: (_) {},
            onDelete: (_) {},
            onCreateAccumulating: () {},
          ),
        ),
      );
      await tester.pump();

      final button = find.byKey(const ValueKey('master_open_in_darkroom'));
      expect(button, findsOneWidget);

      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(taps, 0, reason: 'a disabled control must not fire');

      // The disabled control carries the reason, not just a grey label.
      final tooltip = tester.widget<Tooltip>(
        find.descendant(of: button, matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, contains('no linear FITS'));
    });

    testWidgets('a busy panel disables the button', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _panelHarness(
          MasterLibraryPanel(
            masters: [
              _master(id: 9, name: 'M31 Ha', fitsPath: '/masters/m31.fits'),
            ],
            acceptedSubCount: 40,
            busy: true,
            onOpen: (_) {},
            onOpenInDarkroom: (_) => taps++,
            onAddTonight: (_) {},
            onFinalize: (_) {},
            onDelete: (_) {},
            onCreateAccumulating: () {},
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('master_open_in_darkroom')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('a remote client reads the refusal ON the control', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _panelHarness(
          MasterLibraryPanel(
            masters: [
              _master(id: 11, name: 'M31 Ha', fitsPath: '/masters/m31.fits'),
            ],
            acceptedSubCount: 40,
            busy: false,
            onOpen: (_) {},
            onOpenInDarkroom: (_) => taps++,
            // The answer every Darkroom entry point used to ask for only
            // INSIDE its tap handler: on a client the button was drawn live,
            // full contrast and focusable, and explained itself after the
            // operator had already committed to the press.
            darkroomRefusal: kDarkroomHostOnlyRefusal,
            onAddTonight: (_) {},
            onFinalize: (_) {},
            onDelete: (_) {},
            onCreateAccumulating: () {},
          ),
        ),
      );
      await tester.pump();

      final handle = tester.ensureSemantics();
      final button = find.byKey(const ValueKey('master_open_in_darkroom'));
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(taps, 0, reason: 'a refused control must not fire');

      final tooltip = tester.widget<Tooltip>(
        find.descendant(of: button, matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, kDarkroomHostOnlyRefusal);

      // And in the accessible NAME, which is the part a tooltip cannot reach:
      // Flutter publishes `tooltip:` as `SemanticsProperties.tooltip` and the
      // Linux AT-SPI bridge does not fold that into the name, so a screen
      // reader was handed `Darkroom [DISABLED]` with no reason at all.
      expect(
        publishedNames(tester),
        contains(
          unavailableControlName('Darkroom', kDarkroomHostOnlyRefusal),
        ),
      );
      expect(
        publishedNames(tester),
        isNot(contains('Darkroom')),
        reason: 'the bare name would be a second, quieter answer to the same '
            'question',
      );
      handle.dispose();
    });

    testWidgets('the master\'s own gate still wins over the host gate', (
      tester,
    ) async {
      // Both reasons apply at once. The one the operator can act on from HERE
      // is the master's, so that is the one the control states.
      await tester.pumpWidget(
        _panelHarness(
          MasterLibraryPanel(
            masters: [
              _master(
                id: 12,
                name: 'M31 Ha (accumulating)',
                fitsPath: null,
                mode: AccumulationMode.runningWeightedMean,
              ),
            ],
            acceptedSubCount: 40,
            busy: false,
            onOpen: (_) {},
            onOpenInDarkroom: (_) {},
            darkroomRefusal: kDarkroomHostOnlyRefusal,
            onAddTonight: (_) {},
            onFinalize: (_) {},
            onDelete: (_) {},
            onCreateAccumulating: () {},
          ),
        ),
      );
      await tester.pump();

      final handle = tester.ensureSemantics();
      final button = find.byKey(const ValueKey('master_open_in_darkroom'));
      final tooltip = tester.widget<Tooltip>(
        find.descendant(of: button, matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, contains('no linear FITS'));
      expect(
        publishedNames(tester),
        contains(
          allOf(startsWith('Darkroom — '), contains('no linear FITS')),
        ),
        reason: 'the master\'s own gate is read the same way the host gate is',
      );
      handle.dispose();
    });
  });

  group('the session-review header processes tonight', () {
    late SkotiqDatabase db;
    late String previewPath;

    setUp(() async {
      db = mockDatabase();
      previewPath = await _writeSamplePng();
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> pumpScreen(
      WidgetTester tester,
      SessionReviewScope scope,
    ) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            debugShowCheckedModeBanner: false,
            home: SessionReviewScreen(scope: scope),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    /// Unmount before the framework's end-of-test invariant check.
    ///
    /// The seeded narrative view paints shimmer skeletons, whose one-shot
    /// animate-cap timers outlive the frame that started them. Disposing the
    /// tree and letting the clock run is what a real navigation away does.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 30));
    }

    testWidgets('a session scope offers a live control', (tester) async {
      await pumpScreen(tester, const SessionReviewScope.session(1));

      final button = find.byKey(const ValueKey('session_review_process_now'));
      expect(button, findsOneWidget);
      expect(
        tester.widget<SkotiqButton>(button).onPressed,
        isNotNull,
        reason: 'a single night is exactly what the pass reads',
      );
      await unmount(tester);
    });

    testWidgets('a target scope disables it and names the reason', (
      tester,
    ) async {
      await pumpScreen(tester, const SessionReviewScope.target(1));

      final button = find.byKey(const ValueKey('session_review_process_now'));
      expect(button, findsOneWidget);
      expect(tester.widget<SkotiqButton>(button).onPressed, isNull);

      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: button, matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, contains('spans a target'));
      await unmount(tester);
    });

    testWidgets('Refresh is still there beside it', (tester) async {
      await pumpScreen(tester, const SessionReviewScope.session(1));
      // Icon-only in the page header now (05 §6), so it is named by its
      // tooltip — which is the only name a screen reader gets either.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SkotiqIconButton &&
              widget.icon == SkotiqIcons.refresh,
        ),
        findsOneWidget,
      );
      await unmount(tester);
    });
  });

  group('the Darkroom locations', () {
    test('a recipe and a master are distinct query scopes', () {
      expect(darkroomRecipeLocation(412), '/darkroom?recipe=412');
      expect(darkroomMasterLocation(7), '/darkroom?master=7');
    });
  });
}

/// A tiny on-disk PNG for the seeded hero.
Future<String> _writeSamplePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 40, 30),
    Paint()..color = const Color(0xFF102030),
  );
  final image = await recorder.endRecording().toImage(40, 30);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = await Directory.systemTemp.createTemp('darkroom_entry');
  final file = File('${dir.path}/hero.png');
  await file.writeAsBytes(Uint8List.view(bytes!.buffer));
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return file.path;
}
