import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_thumbnail_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Uint8List _onePixelPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );

DbCapturedImage _image() => DbCapturedImage(
      id: 7,
      filePath: '/shared/light-7.fits',
      fileName: 'light-7.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 13),
      createdAt: DateTime.utc(2026, 7, 13),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('thumbnail reloads when the rig changes but image id is reused',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    when(() => hostA.getImageThumbnail(7))
        .thenAnswer((_) async => _onePixelPng());
    when(() => hostB.getImageThumbnail(7))
        .thenAnswer((_) async => _onePixelPng());

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(body: ImageThumbnailStrip(images: [_image()])),
        ),
      ),
    );
    await tester.pump();
    verify(() => hostA.getImageThumbnail(7)).called(1);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();

    verify(() => hostB.getImageThumbnail(7)).called(1);
  });
}
