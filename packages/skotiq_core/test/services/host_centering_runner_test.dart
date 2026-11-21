import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/src/services/centering_service.dart';
import 'package:skotiq_remote_protocol/wire_models.dart' show RemoteJob;

class _FakeHostPointing implements HostPointing {
  _FakeHostPointing(this._startGate);

  final Completer<String> _startGate;
  final cancelledJobs = <String>[];

  @override
  Future<String> startCentering({
    required double raHours,
    required double decDegrees,
    int maxAttempts = 5,
    double accuracyArcsec = 30,
    double exposureSecs = 3,
    bool syncMount = true,
  }) => _startGate.future;

  @override
  Future<void> cancelJob(String jobId) async {
    cancelledJobs.add(jobId);
  }

  @override
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 1),
  }) async => RemoteJob(
    jobId: jobId,
    operation: 'centering',
    state: 'cancelled',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _request = bridge.ApiCenteringRequest(
  mountId: 'm1',
  cameraId: 'c1',
  raHours: 10,
  decDegrees: 20,
  accuracyArcsec: 30,
  maxAttempts: 3,
  exposureSecs: 2,
  syncMount: true,
);

void main() {
  test(
    'cancel during startCentering cancels the job once the id resolves',
    () async {
      final startGate = Completer<String>();
      final host = _FakeHostPointing(startGate);
      final runner = HostCenteringRunner(host);

      final steps = runner.center(_request).toList();
      await Future<void>.delayed(Duration.zero);
      await runner.cancel();
      expect(host.cancelledJobs, isEmpty);

      startGate.complete('job-42');
      await steps;

      expect(host.cancelledJobs, ['job-42']);
    },
  );

  test(
    'cancel after center() and before the first listen still cancels the job',
    () async {
      final startGate = Completer<String>();
      final host = _FakeHostPointing(startGate);
      final runner = HostCenteringRunner(host);

      final stream = runner.center(_request);
      await runner.cancel();
      final steps = stream.toList();
      await Future<void>.delayed(Duration.zero);
      startGate.complete('job-7');
      await steps;

      expect(host.cancelledJobs, ['job-7']);
    },
  );
}
