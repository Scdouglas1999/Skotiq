import 'package:skotiq_core/skotiq_core.dart';

/// [HostFocusData] on a linked host.
final class RemoteHostFocusData implements HostFocusData {
  RemoteHostFocusData(this._host);

  final NetworkBackend _host;

  @override
  Future<Map<String, dynamic>> getFilterFocusOffsets() =>
      _host.getFilterFocusOffsets();

  @override
  Future<void> setFilterFocusOffsets({
    required String referenceFilter,
    required Map<String, int> offsets,
  }) => _host.setFilterFocusOffsets(
    referenceFilter: referenceFilter,
    offsets: offsets,
  );

  @override
  Future<void> clearFocusModelData() => _host.clearFocusModelData();

  @override
  Future<Map<String, dynamic>> getFocusModel() => _host.getFocusModel();

  @override
  Future<Map<String, dynamic>> getFocusModelData() => _host.getFocusModelData();
}
