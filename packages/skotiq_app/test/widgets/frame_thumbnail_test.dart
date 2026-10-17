// One preview ladder for every frame surface.
//
// Six surfaces each carried their own copy of "backend thumbnail → local file →
// placeholder", and they had already drifted: the shared loader decided a path
// was previewable with a DENYLIST (anything not .fits/.fit/.fts/.xisf), while
// the run-dashboard, cockpit and sequencer strips used an ALLOWLIST
// (.png/.jpg/.jpeg/.tif/.tiff). The two disagree about every other extension
// and about extension-less paths, so the same frame previewed on one surface
// and showed a placeholder icon on another.
//
// The allowlist is the adjudicated survivor: an unknown extension is not
// evidence that Flutter can decode the file.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/frame_thumbnail_loader.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

/// Backend that hands back a thumbnail for one image id and nothing for any
/// other, and counts how often it was asked.
class _CountingBackend extends DisconnectedBackend {
  _CountingBackend({this.bytesFor});

  final int? bytesFor;
  final requested = <int>[];

  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    requested.add(imageId);
    if (imageId == bytesFor) return Uint8List.fromList(_onePixelPng);
    return Uint8List(0);
  }
}

class _FailingBackend extends DisconnectedBackend {
  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    throw StateError('thumbnail service unavailable');
  }
}

/// The smallest thing `Image.memory` will decode.
const _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

Widget _harness(SkotiqBackend backend, Widget child) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith((ref) => _StubBackendNotifier(ref, backend)),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: SizedBox(width: 80, height: 80, child: child)),
    ),
  );
}

void main() {
  group('isDisplayableImagePath', () {
    test('accepts only the rasters Image.file can decode', () {
      for (final path in [
        '/frames/light.png',
        '/frames/LIGHT.JPG',
        '/frames/light.jpeg',
        '/frames/light.tif',
        '/frames/light.tiff',
      ]) {
        expect(isDisplayableImagePath(path), isTrue, reason: path);
      }
    });

    test('rejects the science containers Flutter cannot open', () {
      for (final path in [
        '/frames/light.fits',
        '/frames/light.fit',
        '/frames/light.fts',
        '/frames/light.xisf',
      ]) {
        expect(isDisplayableImagePath(path), isFalse, reason: path);
        expect(isFitsLikePath(path), isTrue, reason: path);
      }
    });

    test('rejects what the denylist used to wave through', () {
      // These are exactly the paths the two rules disagreed on, and the reason
      // one surface drew a broken-image glyph where another drew a placeholder.
      for (final path in [
        '/frames/light.cr2',
        '/frames/light.ser',
        '/frames/light'
      ]) {
        expect(isFitsLikePath(path), isFalse, reason: path);
        expect(isDisplayableImagePath(path), isFalse, reason: path);
      }
    });
  });

  group('fetchFrameThumbnailBytes', () {
    testWidgets('returns the backend thumbnail when there is one',
        (tester) async {
      final backend = _CountingBackend(bytesFor: 7);
      late Future<Uint8List?> result;
      await tester.pumpWidget(
        _harness(
          backend,
          Consumer(
            builder: (context, ref, _) {
              result = fetchFrameThumbnailBytes(ref, 7, source: 'Test');
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(await result, isNotNull);
      expect(backend.requested, [7]);
    });

    testWidgets('a failing backend yields null instead of throwing',
        (tester) async {
      late Future<Uint8List?> result;
      await tester.pumpWidget(
        _harness(
          _FailingBackend(),
          Consumer(
            builder: (context, ref, _) {
              result = fetchFrameThumbnailBytes(ref, 7, source: 'Test');
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      // A thrown error here would take down the whole strip of tiles.
      expect(await result, isNull);
    });
  });

  group('FrameThumbnail', () {
    testWidgets('renders the backend bytes when they arrive', (tester) async {
      await tester.pumpWidget(
        _harness(
          DisconnectedBackend(),
          Builder(
            builder: (context) => FrameThumbnail(
              bytesFuture: Future.value(Uint8List.fromList(_onePixelPng)),
              fallbackFilePath: '/frames/light.fits',
              colors: SkotiqColors.of(context),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(LucideIcons.image), findsNothing);
    });

    testWidgets('falls back to the placeholder for a FITS path',
        (tester) async {
      await tester.pumpWidget(
        _harness(
          DisconnectedBackend(),
          Builder(
            builder: (context) => FrameThumbnail(
              bytesFuture: Future.value(null),
              fallbackFilePath: '/frames/light.fits',
              colors: SkotiqColors.of(context),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      // Never Image.file on a container Flutter cannot decode: that renders a
      // broken-image glyph where the operator expects the frame.
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(LucideIcons.image), findsOneWidget);
    });

    testWidgets('spins while the fetch is outstanding', (tester) async {
      final pending = Completer<Uint8List?>();
      addTearDown(() => pending.complete(null));
      await tester.pumpWidget(
        _harness(
          DisconnectedBackend(),
          Builder(
            builder: (context) => FrameThumbnail(
              bytesFuture: pending.future,
              fallbackFilePath: '/frames/light.png',
              colors: SkotiqColors.of(context),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SkotiqMark), findsOneWidget);
    });
  });
}
