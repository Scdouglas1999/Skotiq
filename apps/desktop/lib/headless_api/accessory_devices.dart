import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';

/// The accessories (domes, switches, cover/calibrators) this host drives.
AccessoryDeviceBackend accessoriesOf(ProviderContainer container) {
  final backend = container.read(deviceBackendProvider);
  if (backend is AccessoryDeviceBackend) {
    return backend as AccessoryDeviceBackend;
  }
  throw StateError('${backend.runtimeType} does not drive accessories');
}
