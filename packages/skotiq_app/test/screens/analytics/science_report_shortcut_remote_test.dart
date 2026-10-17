import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _MockScienceReportExporter extends Mock
    implements ScienceReportExporter {}

void main() {
  test('remote shortcut downloads the host PDF into controller exports',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'skotiq-science-report-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final backend = _MockNetworkBackend();
    final localExporter = _MockScienceReportExporter();
    when(
      () => backend.generateObservationReport(12),
    ).thenAnswer((_) async => Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));

    final file = await exportScienceShortcutReport(
      backend: backend,
      sessionId: 12,
      localExporter: localExporter,
      documentsDirectoryProvider: () async => temp,
      generatedAt: DateTime.utc(2026, 7, 13, 1, 2, 3),
    );

    expect(
      file.path,
      endsWith(
        'Skotiq/exports/'
        'science_report_session_12_2026-07-13T01-02-03.pdf',
      ),
    );
    expect(await file.readAsBytes(), [0x25, 0x50, 0x44, 0x46]);
    verify(() => backend.generateObservationReport(12)).called(1);
    verifyNever(() => localExporter.exportToDisk(any()));
  });

  test('local shortcut preserves the Markdown exporter path', () async {
    final temp = await Directory.systemTemp.createTemp(
      'skotiq-science-report-local-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final expected = File('${temp.path}/report.md');
    final backend = _MockLocalBackend();
    final exporter = _MockScienceReportExporter();
    when(() => exporter.exportToDisk(4)).thenAnswer((_) async => expected);

    final file = await exportScienceShortcutReport(
      backend: backend,
      sessionId: 4,
      localExporter: exporter,
    );

    expect(file.path, expected.path);
    verify(() => exporter.exportToDisk(4)).called(1);
  });
}
