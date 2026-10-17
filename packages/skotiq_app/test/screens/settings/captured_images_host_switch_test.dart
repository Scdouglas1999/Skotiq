import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/captured_images_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpGallery(
    WidgetTester tester,
    SkotiqBackend backend,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            return _SwappableBackendNotifier(ref, backend);
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: CapturedImagesSettings(isMobile: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('host switch drops stale rows and isolates thumbnail ids',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostARows = Completer<List<Map<String, dynamic>>>();
    final hostAThumb = Completer<Uint8List>();
    when(() => hostA.getAllImageRows()).thenAnswer((_) => hostARows.future);
    when(() => hostA.getImageThumbnail(1)).thenAnswer((_) => hostAThumb.future);
    when(() => hostB.getAllImageRows()).thenAnswer(
      (_) async => [
        {'id': 1, 'targetName': 'Host B frame', 'isAccepted': true},
      ],
    );
    when(
      () => hostB.getImageThumbnail(1),
    ).thenAnswer((_) async => _onePixelPng());

    late _SwappableBackendNotifier backendNotifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: CapturedImagesSettings(isMobile: true),
          ),
        ),
      ),
    );
    await tester.pump();

    backendNotifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('Host B frame'), findsOneWidget);
    verify(() => hostB.getImageThumbnail(1)).called(1);

    hostARows.complete([
      {'id': 1, 'targetName': 'Host A stale frame', 'isAccepted': true},
    ]);
    hostAThumb.complete(_onePixelPng());
    await tester.pump();
    await tester.pump();

    expect(find.text('Host B frame'), findsOneWidget);
    expect(find.text('Host A stale frame'), findsNothing);
  });

  testWidgets('initial load failure is not presented as an empty gallery', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.getAllImageRows(),
    ).thenThrow(Exception('host unavailable'));

    await pumpGallery(tester, backend);

    expect(
        find.textContaining('Could not load captured frames'), findsOneWidget);
    expect(find.textContaining('host unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.text('No frames captured on the appliance yet.'),
      findsNothing,
    );
  });

  testWidgets('invalid ids are disabled and thumbnail failures are explicit', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.getAllImageRows()).thenAnswer(
      (_) async => [
        {'id': 1.5, 'targetName': 'Invalid ID', 'isAccepted': true},
        {'id': 2, 'targetName': 'Broken thumbnail', 'isAccepted': true},
      ],
    );
    when(
      () => backend.getImageThumbnail(2),
    ).thenThrow(Exception('thumbnail unavailable'));

    await pumpGallery(tester, backend);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains('invalid image ID'),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains('Thumbnail failed to load'),
      ),
      findsOneWidget,
    );
    verifyNever(() => backend.getImageThumbnail(1));
    verify(() => backend.getImageThumbnail(2)).called(1);
  });
}
