// The rig-identity component on a delivered file name.
//
// Two rigs write the same file names — `job_1_report.json` on both, because
// each rig's job counter starts at 1 — and delivery never overwrites, so the
// second rig into a shared folder is refused with `destinationConflict` and
// its night never lands. What is pinned here is the component that keeps those
// names apart, and the two ways a destination overrides it: a name of its own,
// and the empty string that opts a single-rig folder back out.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_naming.dart';

ArtifactDestination _destination(String configJson) => ArtifactDestination(
  id: 4,
  name: 'nas',
  kind: ArtifactDestinationKind.watchedFolder,
  configJson: configJson,
  enabled: true,
  content: const {ArtifactContent.linearMasters},
  createdAt: DateTime.utc(2026, 8, 16),
  updatedAt: DateTime.utc(2026, 8, 16),
);

void main() {
  test('with no rigId the component is this host, so a rig says who it is '
      'without anybody configuring anything', () {
    final naming = DeliveryNaming.of(const <String, Object?>{
      'path': '/mnt/nas',
    });

    expect(naming.rigId, sanitizeRigId(Platform.localHostname));
    expect(naming.rigId, isNotEmpty);
    expect(
      naming.nameFor('job_1_report.json'),
      '${naming.rigId}-job_1_report.json',
    );
  });

  test('two destinations with different rigIds name the same artifact '
      'differently, which is the whole point', () {
    final shed = DeliveryNaming.of(const <String, Object?>{'rigId': 'shed'});
    final roof = DeliveryNaming.of(const <String, Object?>{'rigId': 'roof'});

    expect(shed.nameFor('job_1_report.json'), 'shed-job_1_report.json');
    expect(roof.nameFor('job_1_report.json'), 'roof-job_1_report.json');
    expect(
      shed.nameFor('job_1_report.json'),
      isNot(roof.nameFor('job_1_report.json')),
    );
  });

  test('an empty rigId delivers under the rig\'s own names — the opt-out a '
      'single-rig folder keeps working with', () {
    final naming = DeliveryNaming.of(const <String, Object?>{'rigId': ''});

    expect(naming.rigId, isEmpty);
    expect(naming.nameFor('M31_L_master.fits'), 'M31_L_master.fits');
  });

  test('a rigId is reduced to characters every destination filesystem '
      'carries', () {
    final naming = DeliveryNaming.of(const <String, Object?>{
      'rigId': '  Shed Rig / #2  ',
    });

    expect(naming.rigId, 'Shed-Rig----2');
    expect(naming.nameFor('x.fits'), 'Shed-Rig----2-x.fits');
  });

  test('a rigId that is not a name is a typed configuration failure, never a '
      'guessed component', () {
    expect(
      () => DeliveryNaming.of(const <String, Object?>{'rigId': 7}),
      throwsA(
        isA<DeliveryFailure>()
            .having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.configurationInvalid,
            )
            .having((f) => f.retryable, 'retryable', isFalse)
            .having((f) => f.message, 'message', contains('rigId')),
      ),
    );
  });

  test('a destination whose config is not a JSON object cannot say which rig '
      'it comes from', () {
    expect(
      () => DeliveryNaming.forDestination(_destination('[]')),
      throwsA(
        isA<DeliveryFailure>().having(
          (f) => f.kind,
          'kind',
          DeliveryFailureKind.configurationInvalid,
        ),
      ),
    );
  });

  test('forDestination reads the row the manifest holds', () {
    final naming = DeliveryNaming.forDestination(
      _destination('{"peerId":"office-pc","rigId":"shed-rig"}'),
    );

    expect(naming.nameFor('draft.jpg'), 'shed-rig-draft.jpg');
  });
}
