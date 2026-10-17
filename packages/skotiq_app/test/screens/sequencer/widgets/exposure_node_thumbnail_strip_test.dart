// Widget tests for the inline frame thumbnail strip
// rendered under each ExposureNode in the sequence tree.
//
// Pins:
//   * The strip renders one tile per ProducingNodeThumbnail it receives
//     from the provider override, with the correct border colour for
//     each runtime grade verdict.
//   * Tapping a tile opens the modal frame viewer dialog (the metadata
//     `_FullFrameDialog` is private; we assert on the file-name text it
//     uses for its title bar).
//   * When `thumbnailStripPrefsProvider` resolves to `enabled = false`,
//     the strip collapses to SizedBox.shrink so the tree row stays
//     compact even with frames in the database.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/exposure_node_thumbnail_strip.dart';
import 'package:skotiq_app/screens/sequencer/widgets/thumbnail_strip_prefs.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart' show mockBackend;
import '../../../harness/pump_app_screen.dart' show TestBackendNotifier;

ProducingNodeThumbnail _thumb({
  required int id,
  required String filter,
  required String grade,
  bool isAccepted = true,
  double? hfr,
  String? path,
}) {
  return ProducingNodeThumbnail(
    id: id,
    filePath: path ?? '/tmp/$id.fits',
    fileName: '$id.fits',
    filter: filter,
    frameType: 'light',
    hfr: hfr,
    eccentricity: 0.31,
    starCount: 120,
    exposureDuration: 60,
    capturedAt: DateTime.utc(2026, 1, 1, 22, 0, id),
    isAccepted: isAccepted,
    rejectionReason: isAccepted ? null : 'HFR too high',
    runtimeGrade: grade,
    producingNodeId: 'test-node',
    producingRunId: 'run-1',
  );
}

Future<void> _pumpStrip(
  WidgetTester tester, {
  required List<ProducingNodeThumbnail> thumbnails,
  ThumbnailStripPrefs? prefsOverride,
  String nodeId = 'test-node',
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final backend = mockBackend();
  // Without this stub the unmocked `getImageThumbnail` returns null and the
  // non-nullable `Future<Uint8List>` cast inside the tile crashes the
  // FutureBuilder. Returning an empty byte list mirrors the
  // "thumbnail not cached" path the production backend takes for newly-
  // captured frames before the FITS thumbnail cache has populated.
  when(() => backend.getImageThumbnail(any()))
      .thenAnswer((_) async => Uint8List(0));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
        exposureNodeThumbnailsProvider(nodeId)
            .overrideWith((ref) => Stream.value(thumbnails)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExposureNodeThumbnailStrip(
              nodeId: nodeId,
              prefsOverride: prefsOverride ?? ThumbnailStripPrefs.defaults,
            ),
          ),
        ),
      ),
    ),
  );
  // First pump fires the build; the StreamProvider then emits its synchronous
  // value (Stream.value) before the next frame.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('ExposureNodeThumbnailStrip', () {
    testWidgets('renders one tile per thumbnail with grade-coloured border',
        (tester) async {
      final thumbnails = [
        _thumb(id: 1, filter: 'L', grade: 'pass'),
        _thumb(id: 2, filter: 'L', grade: 'pending'),
        _thumb(
          id: 3,
          filter: 'L',
          grade: 'reject',
          isAccepted: false,
          path: '/Reject/3.fits',
        ),
      ];

      await _pumpStrip(tester, thumbnails: thumbnails);

      // Three filter labels under the tiles.
      expect(find.text('L'), findsNWidgets(3));

      // Pull the rendered Containers that have a 2-pixel coloured border —
      // there should be one per tile (plus any siblings inside, but the
      // outer-most tile container is the unique 2px-bordered one).
      final containers =
          tester.widgetList<Container>(find.byType(Container)).where((c) {
        final decoration = c.decoration;
        if (decoration is! BoxDecoration) return false;
        return decoration.border != null;
      }).toList();
      // Find the colors used by tile borders.
      final tileBorderColors = <Color>[];
      for (final c in containers) {
        final d = c.decoration as BoxDecoration;
        final border = d.border;
        if (border is Border && border.top.width == 2) {
          tileBorderColors.add(border.top.color);
        }
      }
      // 3 tiles → at least 3 border colours collected.
      expect(tileBorderColors.length, greaterThanOrEqualTo(3));

      // Resolve the theme colours so we can assert against them. Pull
      // the extension off any Scaffold child context (the MaterialApp
      // itself doesn't yet have the inherited theme below it).
      final element = tester.element(find.byType(ExposureNodeThumbnailStrip));
      final colors = SkotiqColors.of(element);
      expect(tileBorderColors, contains(colors.success));
      expect(tileBorderColors, contains(colors.warning));
      expect(tileBorderColors, contains(colors.error));
    });

    testWidgets('renders nothing when prefs.enabled is false', (tester) async {
      await _pumpStrip(
        tester,
        thumbnails: [_thumb(id: 1, filter: 'L', grade: 'pass')],
        prefsOverride: const ThumbnailStripPrefs(
          enabled: false,
          size: ThumbnailSize.medium,
        ),
      );

      // The strip should collapse to a SizedBox.shrink — no filter
      // label or border container makes it into the tree.
      expect(find.text('L'), findsNothing);
    });

    testWidgets('renders nothing when the node has no frames yet',
        (tester) async {
      await _pumpStrip(tester, thumbnails: const []);
      // No tiles, no "+N more" badge.
      expect(find.text('L'), findsNothing);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('shows pagination "+N more" badge past 10 thumbnails',
        (tester) async {
      // 12 frames → strip shows the last 10 + a leading "+2" chip.
      final thumbnails = List.generate(
        12,
        (i) => _thumb(id: i + 1, filter: 'L', grade: 'pass'),
      );
      await _pumpStrip(tester, thumbnails: thumbnails);
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('tapping a tile opens the full-frame dialog', (tester) async {
      final thumbnails = [
        _thumb(id: 42, filter: 'R', grade: 'pass'),
      ];
      await _pumpStrip(tester, thumbnails: thumbnails);

      // Drill into the tile (filter label is the only text rendered for
      // a small strip; using the GestureDetector / InkWell is more
      // robust against layout changes than rect-based positioning).
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      // The dialog's title is the file name.
      expect(find.text('42.fits'), findsOneWidget);
      // Metadata table includes the filter chip.
      expect(find.text('Filter'), findsOneWidget);
      expect(find.text('R'), findsWidgets);
    });
  });
}
