import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/storage_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

int _gb(int n) => n * 1024 * 1024 * 1024;

Widget _wrap(List<Override> overrides) {
  return ProviderScope(
    overrides: [...overrides],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            final colors = SkotiqColors.of(context);
            return SizedBox(
              width: 320,
              child: StorageCard(colors: colors),
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders free space and projected usage bar', (tester) async {
    await tester.pumpWidget(_wrap([
      captureDirDiskSpaceProvider.overrideWith((ref) async* {
        yield DiskSpaceInfo(
          path: 'D:\\images',
          totalBytes: _gb(500),
          freeBytes: _gb(150),
          sampledAt: DateTime.now(),
        );
      }),
      sequenceDiskProjectionProvider.overrideWith((ref) async {
        return SequenceDiskProjectionSnapshot(
          projection: DiskSpaceProjection(
            freeBytes: _gb(150),
            totalBytes: _gb(500),
            projectedBytes: _gb(20),
            severity: DiskSpaceSeverity.info,
            headline: 'You have 150 GB free; this run will consume ~20 GB',
            detail: '130 GB will remain free after the sequence finishes.',
          ),
          capturePathConfigured: true,
        );
      }),
    ]));

    // Pump twice: the stream needs to deliver its first value.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);
    expect(find.text('GB free'), findsOneWidget);
    expect(find.text('of 500 GB'), findsOneWidget);
    expect(find.textContaining('D:\\images'), findsOneWidget);
    expect(
      find.textContaining('this run will consume'),
      findsOneWidget,
    );
  });

  testWidgets('shows configure-path prompt when no path is configured',
      (tester) async {
    await tester.pumpWidget(_wrap([
      captureDirDiskSpaceProvider.overrideWith((ref) async* {
        yield null;
      }),
      sequenceDiskProjectionProvider.overrideWith((ref) async {
        return const SequenceDiskProjectionSnapshot(
          projection: null,
          capturePathConfigured: false,
        );
      }),
    ]));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Storage'), findsOneWidget);
    expect(
      find.textContaining('Set a capture directory'),
      findsOneWidget,
    );
  });

  testWidgets('renders warning headline when sequence is too large',
      (tester) async {
    await tester.pumpWidget(_wrap([
      captureDirDiskSpaceProvider.overrideWith((ref) async* {
        yield DiskSpaceInfo(
          path: 'C:\\',
          totalBytes: _gb(500),
          freeBytes: _gb(20),
          sampledAt: DateTime.now(),
        );
      }),
      sequenceDiskProjectionProvider.overrideWith((ref) async {
        return SequenceDiskProjectionSnapshot(
          projection: DiskSpaceProjection(
            freeBytes: _gb(20),
            totalBytes: _gb(500),
            projectedBytes: _gb(18),
            severity: DiskSpaceSeverity.warning,
            headline: 'Run will leave 2.00 GB free',
            detail: 'Archive recent images before starting.',
          ),
          capturePathConfigured: true,
        );
      }),
    ]));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Run will leave'), findsOneWidget);
  });

  testWidgets('surfaces projection failure and offers a retry', (tester) async {
    var projectionReads = 0;
    await tester.pumpWidget(_wrap([
      captureDirDiskSpaceProvider.overrideWith((ref) async* {
        yield DiskSpaceInfo(
          path: 'D:\\images',
          totalBytes: _gb(500),
          freeBytes: _gb(150),
          sampledAt: DateTime.now(),
        );
      }),
      sequenceDiskProjectionProvider.overrideWith((ref) {
        projectionReads++;
        return Future<SequenceDiskProjectionSnapshot>.error(
          StateError('camera capabilities unavailable'),
        );
      }),
    ]));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('150'), findsOneWidget);
    expect(find.text('Sequence storage estimate unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(projectionReads, 1);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(projectionReads, 2);
  });
}
