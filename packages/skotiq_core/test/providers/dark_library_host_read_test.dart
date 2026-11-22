// A plan built on a linked client checks its darks against the imaging
// host's library, read whole (page by page). Before, the client answered that
// it could not read the library and reported no dark missing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart' show NetworkBackend, SkotiqBackend;
import 'package:skotiq_core/providers.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Map<String, Object?> _row(int id, {String frameType = 'dark'}) => {
  'id': id,
  'filePath': '/host/darks/dark_$id.fits',
  'frameType': frameType,
  'exposureTime': 120.0,
  'gain': 100,
  'offset': 10,
  'binX': 1,
  'binY': 1,
  'temperature': -10.0,
  'width': 6248,
  'height': 4176,
  'masterDarkPath': id == 1 ? '/host/masters/dark_120s.fits' : null,
  'masterFrameCount': id == 1 ? 30 : null,
  'createdAt': DateTime.utc(2026, 11, 1, id % 24).toIso8601String(),
};

void main() {
  late _MockNetworkBackend backend;
  late ProviderContainer container;

  setUp(() {
    backend = _MockNetworkBackend();
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('a linked client reads every page of the host library', () async {
    final rows = [for (var id = 1; id <= 2500; id++) _row(id)];
    when(
      () => backend.listDarkLibraryPage(
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((call) async {
      final limit = call.namedArguments[#limit] as int;
      final offset = call.namedArguments[#offset] as int;
      return {
        'items': rows.skip(offset).take(limit).toList(),
        'total': rows.length,
      };
    });
    expect(container.read(remoteHostProvider), isNotNull);

    final entries = await container.read(darkLibraryEntriesReadProvider)();

    expect(entries, hasLength(2500));
    final master = entries!.firstWhere((e) => e.id == 1);
    expect(master.masterDarkPath, '/host/masters/dark_120s.fits');
    expect(master.masterFrameCount, 30);
    expect(master.exposureTime, 120.0);
    expect(master.temperature, -10.0);
    expect(master.gain, 100);
    expect(master.offset, 10);
    expect(master.binX, 1);
    expect(master.frameType, 'dark');
    expect(master.createdAt.toUtc(), DateTime.utc(2026, 11, 1, 1));
  });

  test('a library the host cannot send reads as unknown, not empty', () async {
    when(
      () => backend.listDarkLibraryPage(
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenThrow(Exception('host unreachable'));

    expect(await container.read(darkLibraryEntriesReadProvider)(), isNull);
  });
}
