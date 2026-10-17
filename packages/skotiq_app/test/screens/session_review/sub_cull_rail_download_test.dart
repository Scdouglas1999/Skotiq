import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ReviewController extends Mock implements SessionReviewController {
  @override
  RemoveListener addListener(
    void Function(SessionReviewState) listener, {
    bool fireImmediately = true,
  }) {
    return () {};
  }

  @override
  CullRecommendationOffer get cullRecommendationOffer =>
      CullRecommendationOffer.none;
}

class _MockImagingBackend extends Mock implements ImagingBackend {}

DbCapturedImage _sub() => DbCapturedImage(
      id: 7,
      filePath: '/tmp/light-007.fits',
      fileName: 'light-007.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 15),
      createdAt: DateTime.utc(2026, 7, 15),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _MockImagingBackend backend;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ns-sub-dl-');
    backend = _MockImagingBackend();
    when(() => backend.getImageThumbnail(any()))
        .thenAnswer((_) async => Uint8List(0));

    // path_provider's temp dir: the download streams to a private temp file
    // before the destination step, so without this the flow fails before it
    // ever reaches the backend.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    // Desktop save picker: cancel, so the assertion is purely about the
    // transfer having been requested for the right frame.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/file_selector'),
      (call) async => null,
    );
  });

  tearDown(() {
    for (final name in const [
      'plugins.flutter.io/path_provider',
      'plugins.flutter.io/file_selector',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets(
      'the shipped sub grid can pull a full-resolution frame to this device',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final requested = <int>[];
    when(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      requested.add(invocation.positionalArguments[0] as int);
      final file = File(invocation.positionalArguments[1] as String);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(const [1, 2, 3], flush: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [imagingBackendProvider.overrideWithValue(backend)],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SubCullRail(
              subs: [_sub()],
              controller: _ReviewController(),
              onTapSub: (_) {},
              onSetAccepted: (_, __) {},
              onBulkCull: ({hfrThreshold, qualityThreshold}) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The per-sub download affordance is the ONLY production caller of
    // downloadImageToDevice: without it the host's byte-streaming image
    // download endpoint is unreachable from the app.
    final button = find.byTooltip('Download to this device');
    expect(button, findsOneWidget);

    await tester.tap(button);
    // Pump frames rather than pumpAndSettle: the button shows an indeterminate
    // spinner while the transfer runs, so the tree never goes quiet.
    for (var i = 0; i < 20 && requested.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      requested,
      [7],
      reason: 'the tapped sub\'s image id should have been downloaded',
    );
  });
}
