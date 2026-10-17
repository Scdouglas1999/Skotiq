part of '../network_backend.dart';

extension _NetworkBackendWireDecoding on _NetworkBackendTransport {
  // Type conversion helpers

  DriverType _parseDriverType(String str) {
    switch (str.toLowerCase()) {
      case 'ascom':
        return DriverType.ascom;
      case 'alpaca':
        return DriverType.alpaca;
      case 'indi':
        return DriverType.indi;
      case 'native':
        return DriverType.native;
      case 'simulator':
        return DriverType.simulator;
      default:
        throw ValidationException(
          message: 'Unknown driver type: $str',
          userMessage: 'The server reported an unknown driver type',
        );
    }
  }

  SkotiqEvent _eventFromJson(Map<String, dynamic> json) {
    return SkotiqEvent.fromWireJson(json);
  }
}
