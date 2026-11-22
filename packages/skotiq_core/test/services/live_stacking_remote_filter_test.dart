import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

/// Records the filter key a remote stack call actually sent.
class _RecordingHost implements HostLiveStack {
  final List<String?> resets = [];
  final List<String?> stops = [];
  final List<({String? reference, String? filter})> starts = [];

  @override
  Future<void> stackingReset({String? filterKey}) async {
    resets.add(filterKey);
  }

  @override
  Future<void> stackingStop({String? filterKey}) async {
    stops.add(filterKey);
  }

  @override
  Future<LiveStackingStats> stackingStart({
    String? referencePath,
    String? filterKey,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    starts.add((reference: referencePath, filter: filterKey));
    return const LiveStackingStats();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a remote service keeps per-filter keys and whole-stack calls omit them',
    () async {
      final host = _RecordingHost();
      final container = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(LoggingService()),
          liveStackingServiceProvider.overrideWith(
            (ref) => LinkedLiveStackingService(ref, host),
          ),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(liveStackingServiceProvider);

      await service.reset(filterKey: 'Ha');
      await service.reset();
      await service.stop(filterKey: 'OIII');
      await service.stop();
      await service.start(
        referenceImagePath: '/host/sii.fits',
        filterKey: 'SII',
      );

      expect(host.resets, ['Ha', null]);
      expect(host.stops, ['OIII', null]);
      expect(host.starts, [(reference: '/host/sii.fits', filter: 'SII')]);
    },
  );
}
