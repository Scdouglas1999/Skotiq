// Where a path the imaging host wrote is opened as a file on this computer,
// on this computer's backend, a linked host and an unlinked client. Recorded
// on the code where each site asked whether the app is linked.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_settings_panel.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/widgets/frame_thumbnail_loader.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

/// A backend whose thumbnail cache has nothing.
class _NoThumbnails extends DisconnectedBackend {
  @override
  Future<Uint8List> getImageThumbnail(int imageId) async => Uint8List(0);
}

enum _Side { local, linked, unlinked }

SkotiqBackend _backendFor(_Side side) => switch (side) {
      _Side.local => _LocalBackend(),
      _Side.linked => _MockNetworkBackend(),
      _Side.unlinked => DisconnectedBackend(),
    };

/// This computer's backend; only its type matters here.
class _LocalBackend extends Mock implements FfiBackend {}

DbCapturedImage _frame(int id, String path) => DbCapturedImage(
      id: id,
      filePath: path,
      fileName: 'f$id.fits',
      fileFormat: 'fits',
      sessionId: 1,
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 11, 22, 1, id),
      createdAt: DateTime.utc(2026, 11, 22, 1, id),
      isAccepted: true,
      isPlateSolved: false,
    );

Override _backend(_Side side) => backendProvider.overrideWith(
      (ref) => _FixedBackendNotifier(ref, _backendFor(side)),
    );

void main() {
  late Directory dir;
  late String onDisk;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sk-host-paths-');
    onDisk = '${dir.path}/light.fits';
    File(onDisk).writeAsStringSync('x');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const strip = {
    _Side.local: '[/host/a.fits|/host/a.fits, null|null]',
    _Side.linked: '[null|/host/a.fits, null|null]',
    _Side.unlinked: '[/host/a.fits|/host/a.fits, null|null]',
  };
  for (final side in _Side.values) {
    test('frame strip paths, ${side.name}', () {
      final container = ProviderContainer(
        overrides: [
          _backend(side),
          nightSessionLightRowsProvider.overrideWithValue(
            [_frame(1, '/host/a.fits'), _frame(2, '')],
          ),
        ],
      );
      addTearDown(container.dispose);
      final frames = container.read(nightSessionFramesProvider);
      expect(
        '${[for (final f in frames) '${f.filePath}|${f.hostPath}']}',
        strip[side],
      );
    });
  }

  const thumbnail = {
    _Side.local: true,
    _Side.linked: false,
    _Side.unlinked: true,
  };
  for (final side in _Side.values) {
    testWidgets('thumbnail file found, ${side.name}', (tester) async {
      FrameThumbnailPayload? payload;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _backend(side),
            imagingBackendProvider.overrideWithValue(_NoThumbnails()),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async =>
                    payload = await loadFrameThumbnail(ref, _frame(1, onDisk)),
                child: const Text('load'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('load'));
        for (var i = 0; i < 50 && payload == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(payload!.fileExists, thumbnail[side]);
      expect(payload!.bytes, isNull);
    });
  }

  const check = {
    _Side.local: 'File found on disk',
    _Side.linked: 'Path is validated on the imaging host when calibrating',
    _Side.unlinked: 'File found on disk',
  };
  for (final side in _Side.values) {
    testWidgets('calibration master check, ${side.name}', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [_backend(side)],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(body: CalibrationFileCheck(filePath: onDisk)),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text(check[side]!), findsOneWidget);
    });
  }
}
