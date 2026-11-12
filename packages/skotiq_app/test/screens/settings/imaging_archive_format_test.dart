import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/imaging_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

Future<_StubAppSettingsNotifier> _pump(
  WidgetTester tester,
  AppSettingsState settings,
) async {
  final notifier = _StubAppSettingsNotifier(settings);
  await pumpAppScreen(
    tester,
    const Material(child: ImagingSettings()),
    size: const Size(1280, 800),
    extraOverrides: [appSettingsProvider.overrideWith(() => notifier)],
  );
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'FITS is the archive format a fresh install shows, with no XISF '
      'options', (tester) async {
    await _pump(tester, const AppSettingsState());

    expect(find.byKey(const Key('imaging.archiveFormat')), findsOneWidget);
    expect(find.text('FITS'), findsOneWidget);
    expect(find.byKey(const Key('imaging.xisfCompression')), findsNothing);
    expect(find.byKey(const Key('imaging.xisfChecksums')), findsNothing);
  });

  testWidgets('XISF shows its compression and checksum choices',
      (tester) async {
    await _pump(
      tester,
      const AppSettingsState(imageFormat: 'XISF', xisfCompression: 'zstd+sh'),
    );

    expect(find.text('XISF'), findsOneWidget);
    expect(find.text('Zstandard, byte-shuffled (smallest)'), findsOneWidget);
    expect(find.byKey(const Key('imaging.xisfChecksums')), findsOneWidget);
  });

  testWidgets('choosing XISF stores it and reveals the XISF options',
      (tester) async {
    final notifier = await _pump(tester, const AppSettingsState());

    await tester.tap(find.byKey(const Key('imaging.archiveFormat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('XISF').last);
    await tester.pumpAndSettle();

    expect(notifier.state.value?.imageFormat, 'XISF');
    expect(find.byKey(const Key('imaging.xisfCompression')), findsOneWidget);
  });

  test('only FITS and XISF are capture formats; anything else reads as FITS',
      () {
    expect(normalizeCaptureImageFormat('xisf'), 'XISF');
    expect(normalizeCaptureImageFormat('TIFF'), 'FITS');
    expect(normalizeXisfCompression('LZ4HC+SH'), 'lz4hc+sh');
    expect(normalizeXisfCompression('brotli'), kXisfCompressionNone);
  });
}
