import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/annotation_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _cluster = CelestialObjectAnnotation(
  id: 'dso_NGC7380',
  name: 'NGC7380',
  type: ObjectType.starCluster,
  ra: 341.8,
  dec: 58.1,
  x: 500,
  y: 500,
  magnitude: 7.2,
);

ImageAnnotation _annotation(List<CelestialObjectAnnotation> objects) =>
    ImageAnnotation(
      imagePath: '/tmp/target.fits',
      timestamp: DateTime.utc(2026, 10, 7),
      plateSolve: const PlateSolveData(
        ra: 341.8,
        dec: 58.1,
        pixelScale: 0.79,
        rotation: 0,
        fieldWidth: 1,
        fieldHeight: 1,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      objects: objects,
    );

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder get _exportButton =>
    find.byWidgetPredicate((w) => w is PopupMenuButton<AnnotationExportFormat>);

PopupMenuButton<AnnotationExportFormat> _menu(WidgetTester tester) =>
    tester.widget<PopupMenuButton<AnnotationExportFormat>>(_exportButton);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('blocker', () {
    test('names a frame without a plate solution', () {
      expect(
        annotationExportBlocker(null, const []),
        contains('until a frame is plate-solved'),
      );
    });

    test('names a solved frame with no catalog objects in it', () {
      expect(
        annotationExportBlocker(_annotation(const []), const []),
        contains('no catalog objects'),
      );
    });

    test('names filters that hide every object', () {
      expect(
        annotationExportBlocker(_annotation(const [_cluster]), const []),
        contains('filters hide'),
      );
    });

    test('is null when there are objects to export', () {
      expect(
        annotationExportBlocker(
          _annotation(const [_cluster]),
          const [_cluster],
        ),
        isNull,
      );
    });
  });

  testWidgets(
      'the Annotations tab disables Export with the reason until the frame is '
      'annotated', (tester) async {
    await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: SkotiqColors.dark),
      size: const Size(360, 1000),
      settle: false,
    );
    await _drain(tester);

    expect(_menu(tester).enabled, isFalse);
    expect(_menu(tester).tooltip, contains('until a frame is plate-solved'));
  });

  testWidgets(
      'Export > CSV on the Annotations tab saves the listed objects as CSV',
      (tester) async {
    final saved = <(AnnotationExportFormat, String, String)>[];
    final handle = await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: SkotiqColors.dark),
      size: const Size(360, 1000),
      settle: false,
      extraOverrides: [
        annotationExportSaverProvider.overrideWithValue(
          (format, name, content) async {
            saved.add((format, name, content));
            return '/exports/$name';
          },
        ),
      ],
    );
    await _drain(tester);
    handle.container.read(currentAnnotationProvider.notifier).state =
        _annotation(const [_cluster]);
    await _drain(tester);

    expect(_menu(tester).enabled, isTrue);
    expect(_menu(tester).tooltip, 'Export annotations');
    await tester.tap(_exportButton);
    await _drain(tester);
    await tester.tap(find.text('Export CSV'));
    await _drain(tester);

    expect(saved, hasLength(1));
    final (format, name, content) = saved.single;
    expect(format, AnnotationExportFormat.csv);
    expect(name, endsWith('.csv'));
    expect(content, contains('NGC7380,,,Star cluster,341.800000'));
    expect(find.textContaining('Annotation CSV saved to /exports/'),
        findsOneWidget);
  });

  testWidgets('a failed save says so in plain words', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const AnnotationTabPanel(colors: SkotiqColors.dark),
      size: const Size(360, 1000),
      settle: false,
      extraOverrides: [
        annotationExportSaverProvider.overrideWithValue(
          (format, name, content) async =>
              throw const FileSystemException('Permission denied'),
        ),
      ],
    );
    await _drain(tester);
    handle.container.read(currentAnnotationProvider.notifier).state =
        _annotation(const [_cluster]);
    await _drain(tester);

    await tester.tap(_exportButton);
    await _drain(tester);
    await tester.tap(find.text('Export DS9 regions'));
    await _drain(tester);

    expect(find.textContaining('Could not save the DS9 region file'),
        findsOneWidget);
    expect(_menu(tester).enabled, isTrue);
  });
}
