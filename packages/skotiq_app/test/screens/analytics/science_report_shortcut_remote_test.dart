import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/analytics/analytics_exports.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/services.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

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
    when(
      () => backend.generateObservationReport(12),
    ).thenAnswer((_) async => Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));

    final file = await saveHostScienceReport(
      backend,
      12,
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
  });

  test('local shortcut preserves the Markdown exporter path', () async {
    final temp = await Directory.systemTemp.createTemp(
      'skotiq-science-report-local-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final expected = File('${temp.path}/report.md');
    final exporter = _MockScienceReportExporter();
    when(() => exporter.exportToDisk(4)).thenAnswer((_) async => expected);
    final container = ProviderContainer(
      overrides: [
        remoteHostProvider.overrideWithValue(null),
        scienceReportExporterProvider.overrideWithValue(exporter),
      ],
    );
    addTearDown(container.dispose);

    final file = await container.read(analyticsExportsProvider).scienceReport(4);

    expect(file.path, expected.path);
    verify(() => exporter.exportToDisk(4)).called(1);
  });
}
