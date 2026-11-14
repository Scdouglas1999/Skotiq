import 'dart:async';
import 'dart:typed_data';

import 'skotiq_backend.dart';
import 'skotiq_exception.dart' show ConnectionException;
import '../models/backend/backend_types.dart';

const _notConnected = ConnectionException(
  message:
      'Not connected to server. Please connect to a Skotiq Headless Server first.',
  userMessage: 'Not connected to a Skotiq Headless Server',
);

/// The backend of an app that is not linked to any host: the default state of
/// the mobile app, so no local logic (like FFI) runs while it should be acting
/// as a thin client.
///
/// Every backend operation fails with the same [ConnectionException]. The
/// operations all return futures, so they are answered in one place by
/// [noSuchMethod]; the few members that are not futures are spelled out
/// below, and `disconnected_backend_contract_test.dart` fails when a new
/// non-future member is added to a role without an override here.
class DisconnectedBackend implements SkotiqBackend {
  final _eventController = StreamController<SkotiqEvent>.broadcast();
  final _polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get dispatchPluginNodesLocally => true;

  @override
  Stream<SkotiqEvent> get eventStream => _eventController.stream;

  @override
  Set<DeviceType> get nativeReconnectedDeviceTypes => const {};

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents =>
      _polarAlignController.stream;

  @override
  Uint8List autoStretchImage({
    required int width,
    required int height,
    required List<int> data,
  }) {
    throw _notConnected;
  }

  @override
  void dispose() {
    _eventController.close();
    _polarAlignController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(_notConnected, StackTrace.current);
}
