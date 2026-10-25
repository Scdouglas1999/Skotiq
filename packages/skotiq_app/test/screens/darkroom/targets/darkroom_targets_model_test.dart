import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/targets/darkroom_targets_model.dart';
import 'package:skotiq_app/screens/darkroom/targets/darkroom_targets_providers.dart';
import 'package:skotiq_app/screens/darkroom/targets/nights_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'owner_nights_fixture.dart';

void main() {
  late OwnerNights owner;
  late ProviderContainer container;

  setUp(() async {
    owner = await seedOwnerNights();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(owner.db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await owner.db.close();
  });

  Future<DarkroomTarget> ngc891() async =>
      (await container.read(darkroomTargetsProvider.future)).single;

  test('nights run noon to noon, newest first, past midnight included',
      () async {
    final t = await ngc891();
    expect([
      for (final n in t.nights) n.key
    ], [
      '2026-10-23',
      '2026-10-22',
      '2026-10-21',
      '2026-10-20',
    ]);
    // Subs after midnight belong to the evening they started.
    final oct21 = t.nights.firstWhere((n) => n.key == '2026-10-21');
    expect(oct21.last.day, 22);
    expect(darkroomNightLabel(oct21.evening), 'Oct 21 to 22');
    expect(darkroomWeekday(oct21.evening), 'Wednesday');
  });

  test('a gap many cadences long is a pause, and a pier change is a flip',
      () async {
    final oct21 = (await ngc891()).nights.firstWhere(
          (n) => n.key == '2026-10-21',
        );
    expect(oct21.pauses, hasLength(1));
    expect(hhmm(oct21.pauses.single.end), '01:36');
    expect([
      for (final m in oct21.marks) (m.label, hhmm(m.at))
    ], [
      ('flip', '01:36'),
    ]);
    expect(oct21.note, 'Flip at 01:36');
  });

  test('lost stars are marked once per run, and far pointing is off target',
      () async {
    final oct23 = (await ngc891()).nights.first;
    expect([
      for (final m in oct23.marks) (m.label, hhmm(m.at))
    ], [
      ('flip', '01:36'),
      ('no stars', '03:28'),
    ]);
    expect(oct23.rejected, 10);
    expect(oct23.offTarget, 5);
    expect(
      oct23.subs.where((s) => s.offTarget).every((s) => !s.kept),
      isTrue,
    );
    expect(oct23.subs.where((s) => s.kept).any((s) => s.offTarget), isFalse);
  });

  test('the nights the current masters hold are not new', () async {
    final t = await ngc891();
    final oct20 = t.nights.last;
    expect(oct20.use, DarkroomNightUse.all);
    expect(oct20.isNew, isFalse);
    expect(t.newNights, 3);
    expect(t.newSubsInBuiltNights, 0);
    expect(t.hasNewLight, isTrue);
  });

  test('a sub a build was given but skipped is not new, and not used',
      () async {
    final dao = IntegratedMastersDao(owner.db);
    final old = await dao.getFramesForMaster(owner.masters['L']!);
    final rebuilt = await dao.insertMaster(
      targetId: owner.target,
      name: 'NGC0891 · L',
      filter: 'L',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      createdAt: DateTime(2026, 10, 22, 9),
      updatedAt: DateTime(2026, 10, 22, 9),
    );
    for (final (i, f) in old.indexed) {
      await dao.recordFoldedFrame(
        masterId: rebuilt,
        imageId: f.imageId,
        accepted: i != 0,
        rejectionReason: i == 0 ? 'Eccentric stars' : null,
      );
    }
    final oct20 = (await ngc891()).nights.last;
    expect(oct20.use, DarkroomNightUse.all);
    expect(oct20.isNew, isFalse);
    expect(oct20.used, oct20.kept - 1);
  });

  test(
      'channels pair each filter with its newest master; the color image '
      'leads the hero', () async {
    final t = await ngc891();
    expect(t.filters, ['L', 'R', 'G', 'B']);
    for (final ch in t.channels) {
      expect(ch.master?.id, owner.masters[ch.filter]);
      expect(ch.keptSubs, greaterThan(0));
    }
    expect(t.color?.id, owner.masters['RGB']);
    expect(t.heroMaster?.id, owner.masters['RGB']);
    expect(t.latestMasters.map((m) => m.id), [
      owner.masters['L'],
      owner.masters['R'],
      owner.masters['G'],
      owner.masters['B'],
      owner.masters['RGB'],
    ]);
  });

  test('a master is matched by target row, else plan, else name', () async {
    final masters = await IntegratedMastersDao(owner.db).getAll();
    final l = masters.firstWhere((m) => m.id == owner.masters['L']);
    final rows = await owner.db.targetsDao.getAllTargets();
    expect(
      darkroomMasterBelongsTo(l, 'NGC 891', row: rows.single),
      isTrue,
    );
    expect(darkroomMasterBelongsTo(l, 'M 81', row: null), isFalse);

    final dao = IntegratedMastersDao(owner.db);
    final planned = await dao.getById(
      await dao.insertMaster(
        name: 'Something else R',
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        settingsJson: jsonEncode({'version': 1, 'target': 'NGC 891'}),
      ),
    );
    expect(darkroomMasterBelongsTo(planned!, 'NGC 891'), isTrue);
    expect(darkroomMasterBelongsTo(planned, 'NGC 1'), isFalse);

    final named = await dao.getById(
      await dao.insertMaster(
        name: 'NGC0891 · Ha',
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
      ),
    );
    expect(darkroomMasterBelongsTo(named!, 'NGC0891'), isTrue);
    expect(normalizeDarkroomTargetName('ngc 0891'), 'NGC0891');
  });

  test('the shared axis covers every night on even hours', () async {
    final t = await ngc891();
    final (lo, hi) = darkroomNightAxis(t.nights);
    expect(lo, 20);
    expect(hi, 28);
  });

  test('filters keep the Darkroom order', () {
    final list = ['Ha', 'B', 'SII', 'L', 'Custom', 'G', 'R', 'OIII']
      ..sort(compareDarkroomFilters);
    expect(list, ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII', 'Custom']);
  });
}
