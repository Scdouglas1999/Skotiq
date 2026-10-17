// Retry must issue a fresh candidate query and clear a stale load error when
// that query succeeds.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

TransientDetectionRow _detection() {
  return TransientDetectionRow(
    id: 1,
    sessionId: null,
    capturedImageId: null,
    tileId: 261982,
    detectedAt: DateTime.utc(2026, 7, 25, 3, 12),
    raDeg: 202.4,
    decDeg: 47.2,
    residualFlux: 3.0,
    deltaMag: null,
    snr: 12.0,
    fwhm: 2.4,
    eccentricity: 0.1,
    positionAngleDeg: 0.0,
    kind: 'newSource',
    catalogMatch: null,
    confidence: 0.9,
    reviewed: false,
    dismissed: false,
  );
}

class _CountingDao extends TransientDetectionsDao {
  _CountingDao(super.db);

  // Broadcast: each Retry rebuilds the feed, which subscribes again.
  final StreamController<List<TransientDetectionRow>> _silentChanges =
      StreamController<List<TransientDetectionRow>>.broadcast();

  int reads = 0;
  bool healed = false;

  @override
  Future<List<TransientDetectionRow>> recentDetections({
    int limit = 200,
    int offset = 0,
  }) {
    reads++;
    if (!healed) {
      return Future<List<TransientDetectionRow>>.error(
        const FormatException('Invalid radix-10 number', 'tile-042', 0),
      );
    }
    return Future<List<TransientDetectionRow>>.value([_detection()]);
  }

  @override
  Stream<List<TransientDetectionRow>> watchRecentDetections({int limit = 200}) {
    return _silentChanges.stream;
  }
}

/// Pump frames until [matches] holds, then fail loudly rather than assert
/// against a half-built frame.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() matches,
  String describe,
) async {
  for (var i = 0; i < 120; i++) {
    if (matches()) return;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('timed out waiting for $describe');
}

Future<_CountingDao> _pumpErroredSurface(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 1600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final dao = _CountingDao(database);
  addTearDown(() async {
    await dao._silentChanges.close();
    await database.close();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        transientDetectionsDaoProvider.overrideWithValue(dao),
        recentNarratorFeedProvider.overrideWith(
          (ref) => Stream.value(const <NarratorEvent>[]),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: FirstLightView(showHeader: false)),
      ),
    ),
  );

  await _pumpUntil(
    tester,
    () => find.text('Could not load candidates').evaluate().isNotEmpty,
    'the load failure to reach the screen',
  );
  return dao;
}

void main() {
  testWidgets('Retry issues a fresh read of the candidate query', (
    tester,
  ) async {
    final dao = await _pumpErroredSurface(tester);
    final before = dao.reads;
    expect(before, greaterThan(0));

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(
      dao.reads,
      greaterThan(before),
      reason: 'Retry must re-run the query; re-subscribing to the feed that '
          'already failed is the reported defect',
    );
  });

  testWidgets('a successful re-query clears the error without an app restart', (
    tester,
  ) async {
    final dao = await _pumpErroredSurface(tester);

    // The operator corrects the offending value; the read is healthy again.
    dao.healed = true;

    await tester.tap(find.text('Retry'));
    await _pumpUntil(
      tester,
      () => find.text('Possible unknown transient').evaluate().isNotEmpty,
      'the candidate the corrected query returns',
    );

    expect(
      find.text('Could not load candidates'),
      findsNothing,
      reason: 'the stale error must not survive a successful re-query',
    );
  });
}
