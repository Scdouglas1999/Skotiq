import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/analytics/analytics_exports.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _MockScienceReportExporter extends Mock
    implements ScienceReportExporter {}

void main() {
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

    final file =
        await container.read(analyticsExportsProvider).scienceReport(4);

    expect(file.path, expected.path);
    verify(() => exporter.exportToDisk(4)).called(1);
  });
}
