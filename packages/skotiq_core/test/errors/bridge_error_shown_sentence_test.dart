// The sentence this app shows for a native failure whose payload is only the
// driver's token ("set_simulation_mode(true)", "slew", "gain") names what
// failed, as it did before the GUI took the published remote wording; the
// host's reply to a remote client keeps the published sentence.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/errors.dart';

typedef _Row = ({bridge.SkotiqError error, String shown, String published});

final _rows = <String, _Row>{
  'notSupported': (
    error: const bridge.SkotiqError.notSupported(
      deviceId: 'native:sim:0',
      operation: 'set_simulation_mode(true)',
    ),
    shown: "'native:sim:0' does not support: set_simulation_mode(true)",
    published: 'set_simulation_mode(true) (device native:sim:0)',
  ),
  'timeout': (
    error: const bridge.SkotiqError.timeout('slew'),
    shown: 'Operation timed out: slew',
    published: 'slew',
  ),
  'invalidParameter': (
    error: const bridge.SkotiqError.invalidParameter('gain'),
    shown: 'Invalid parameter: gain',
    published: 'gain',
  ),
  'invalidInput': (
    error: const bridge.SkotiqError.invalidInput('nope'),
    shown: 'Invalid input: nope',
    published: 'nope',
  ),
  'imageError': (
    error: const bridge.SkotiqError.imageError('bad stride'),
    shown: 'Image error: bad stride',
    published: 'bad stride',
  ),
  'cameraError': (
    error: const bridge.SkotiqError.cameraError('no sensor'),
    shown: 'Camera error: no sensor',
    published: 'no sensor',
  ),
  'ioError': (
    error: const bridge.SkotiqError.ioError('disk gone'),
    shown: 'I/O error: disk gone',
    published: 'disk gone',
  ),
  'serializationError': (
    error: const bridge.SkotiqError.serializationError('bad json'),
    shown: 'Serialization error: bad json',
    published: 'bad json',
  ),
  'plateSolveError': (
    error: const bridge.SkotiqError.plateSolveError('no match'),
    shown: 'Plate solve failed: no match',
    published: 'no match',
  ),
  'sequenceError': (
    error: const bridge.SkotiqError.sequenceError('node missing'),
    shown: 'Sequence error: node missing',
    published: 'node missing',
  ),
  'internal': (
    error: const bridge.SkotiqError.internal('bug'),
    shown: 'Internal error: bug',
    published: 'bug',
  ),
  'runtimeInitFailed': (
    error: const bridge.SkotiqError.runtimeInitFailed('no tokio'),
    shown: 'Runtime initialization failed: no tokio',
    published: 'no tokio',
  ),
  'exposureFailed with no reason': (
    error: const bridge.SkotiqError.exposureFailed(
      cameraId: 'native:zwo:0',
      reason: '',
    ),
    shown: "Exposure failed on 'native:zwo:0'",
    published: '',
  ),
  'operationFailed with no message': (
    error: const bridge.SkotiqError.operationFailed('  '),
    shown: 'Operation failed:   ',
    published: '  ',
  ),
  // A payload that is the driver's own sentence is shown as published.
  'exposureFailed with a reason': (
    error: const bridge.SkotiqError.exposureFailed(
      cameraId: 'native:zwo:0',
      reason: 'Image is completely saturated',
    ),
    shown: 'Image is completely saturated',
    published: 'Image is completely saturated',
  ),
  'operationFailed with a message': (
    error: const bridge.SkotiqError.operationFailed(
      'Failed to get lock position: no lock',
    ),
    shown: 'Failed to get lock position: no lock',
    published: 'Failed to get lock position: no lock',
  ),
  'connectionFailed': (
    error: const bridge.SkotiqError.connectionFailed(
      deviceId: 'native:zwo:0',
      reason: 'USB device busy',
    ),
    shown: 'Could not connect to native:zwo:0: USB device busy',
    published: 'Could not connect to native:zwo:0: USB device busy',
  ),
};

void main() {
  for (final MapEntry(key: name, value: row) in _rows.entries) {
    test('$name: shown and published sentences', () {
      expect(skotiqErrorFromBridge(row.error).userMessage, row.shown);
      expect(bridgeErrorSentence(row.error), row.published);
    });
  }
}
