import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/discover/constellation/constellation_ui_providers.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

bool _enabledFor(SkotiqBackend backend) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container.read(isConstellationHostActionEnabledProvider);
}

void main() {
  test('only a live local host enables atlas contribution writes', () {
    expect(_enabledFor(_MockFfiBackend()), isTrue);
    expect(_enabledFor(_MockNetworkBackend()), isFalse);
    expect(_enabledFor(DisconnectedBackend()), isFalse);
  });
}
