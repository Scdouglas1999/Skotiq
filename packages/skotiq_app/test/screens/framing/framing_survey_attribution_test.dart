// Survey attribution must follow the IMAGERY, not the tile layer.
//
// Only two of the eight framing surveys (DSS2 red / blue) have a live-verified
// HiPS pyramid, so `hipsFramingActiveProvider` is false for the other six. The
// attribution wiring returned `SizedBox.shrink()` on that gate BEFORE it ever
// looked at whether imagery was visible — but the other six surveys still stream
// real publisher imagery through the hips2fits cutout path and render it on the
// canvas. Selecting 2MASS J / SDSS9 / WISE / DSS2 IR therefore displayed
// publisher imagery with no credit anywhere on screen, which the CDS/2MASS/SDSS/
// WISE data licences require.
//
// The contract these pin:
//   * imagery on screen (by EITHER delivery path) => a credit is rendered;
//   * no imagery => no credit (the credit accompanies the imagery, not the app);
//   * every SurveySource carries a non-empty static credit, so the credit never
//     depends on a `properties` fetch succeeding.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_hips_layer_wiring.dart';
import 'package:skotiq_app/screens/framing/widgets/hips_attribution_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const FramingTarget _target = FramingTarget(
  name: 'M42',
  catalogId: 'M42',
  raHours: 5.588,
  decDegrees: -5.39,
);

/// Seeds [FramingNotifier] with a fixed state (subclass-and-seed), so the wiring
/// reads a known survey + imagery presence without DB or network wiring.
class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

Future<ui.Image> _solidImage() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFF203040),
  );
  return recorder.endRecording().toImage(4, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image cutout;

  setUpAll(() async {
    cutout = await _solidImage();
  });

  Future<String?> pumpCreditFor(
    WidgetTester tester,
    SurveySource source, {
    required bool withImagery,
  }) async {
    // Fully tear the tree down first. Consecutive pumpWidget calls otherwise
    // reuse the ProviderScope element, so the previous survey's badge (and its
    // credit) can survive into the next assertion.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          framingProvider.overrideWith(
            (ref) => _SeededFramingNotifier(
              ref,
              FramingState(
                target: _target,
                surveySource: source,
                previewFovDegrees: 0.5,
                surveyImage: withImagery ? cutout : null,
              ),
            ),
          ),
          // The tile layer is deliberately off, so the ONLY imagery on screen is
          // the single hips2fits cutout — the delivery path six of the eight
          // surveys always use.
          hipsFramingEnabledProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: const Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: FramingHipsLayerWiring(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final badges = tester.widgetList<HipsAttributionBadge>(
      find.byType(HipsAttributionBadge),
    );
    if (badges.isEmpty) return null;
    final texts = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(HipsAttributionBadge),
          matching: find.byType(Text),
        ))
        .map((text) => text.data ?? '')
        .where((data) => data.isNotEmpty)
        .toList();
    return texts.isEmpty ? null : texts.first;
  }

  testWidgets('every survey credits its publisher while its imagery is shown',
      (tester) async {
    for (final source in SurveySource.values) {
      final credit = await pumpCreditFor(tester, source, withImagery: true);
      expect(
        credit,
        isNotNull,
        reason: 'SurveySource.$source rendered imagery with NO credit',
      );
      expect(credit, isNotEmpty, reason: 'empty credit for $source');
    }
  });

  testWidgets('the six runtime-resolved surveys name the right publisher',
      (tester) async {
    Future<void> expectCredit(SurveySource source, String needle) async {
      final credit = await pumpCreditFor(tester, source, withImagery: true);
      expect(credit, contains(needle), reason: 'wrong credit for $source');
    }

    await expectCredit(SurveySource.dss2IR, 'Digitized Sky Survey');
    await expectCredit(SurveySource.sdss, 'Sloan Digital Sky Survey');
    await expectCredit(SurveySource.twomassJ, '2MASS');
    await expectCredit(SurveySource.twomassH, '2MASS');
    await expectCredit(SurveySource.twomassK, '2MASS');
    await expectCredit(SurveySource.wise12, 'WISE');
  });

  testWidgets('no imagery on screen => no credit (it accompanies the imagery)',
      (tester) async {
    for (final source in [
      SurveySource.dss2Red,
      SurveySource.twomassJ,
      SurveySource.wise12,
    ]) {
      final credit = await pumpCreditFor(tester, source, withImagery: false);
      expect(
        credit,
        isNull,
        reason: 'credited $source with no imagery on screen',
      );
    }
  });

  group('HipsSurveyRegistry attribution', () {
    test('every SurveySource carries a non-empty static credit', () {
      for (final source in SurveySource.values) {
        final credit = HipsSurveyRegistry.attributionCreditFor(source);
        expect(credit.trim(), isNotEmpty, reason: 'no credit for $source');
      }
    });

    test('published attribution URLs are absolute http(s) URIs', () {
      for (final source in SurveySource.values) {
        final url = HipsSurveyRegistry.attributionUrlFor(source);
        if (url == null) continue;
        final uri = Uri.tryParse(url);
        expect(uri, isNotNull,
            reason: 'unparseable attribution URL for $source');
        expect(uri!.hasScheme, isTrue, reason: 'relative URL for $source');
        expect(uri.scheme, anyOf('http', 'https'),
            reason: 'bad scheme: $source');
      }
    });
  });

  group('HipsAttributionBadge credit precedence', () {
    testWidgets('a resolved properties credit wins over the static fallback',
        (tester) async {
      final props = HipsProperties.parse('''
hips_order        = 9
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
obs_copyright     = Live properties credit
obs_copyright_url = https://example.org/live
''');
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: HipsAttributionBadge(
              properties: props,
              visible: true,
              fallbackCredit: 'Static registry credit',
              fallbackCreditUrl: 'https://example.org/static',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Live properties credit'), findsOneWidget);
      expect(find.text('Static registry credit'), findsNothing);
    });

    testWidgets('the static fallback is used when no properties resolved',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: HipsAttributionBadge(
              properties: null,
              visible: true,
              fallbackCredit: 'Static registry credit',
              fallbackCreditUrl: 'https://example.org/static',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Static registry credit'), findsOneWidget);
    });

    testWidgets(
        'nothing at all still renders nothing (never an invented '
        'credit)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: HipsAttributionBadge(properties: null, visible: true),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Text), findsNothing);
    });
  });
}
