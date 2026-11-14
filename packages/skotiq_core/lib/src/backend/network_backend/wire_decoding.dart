part of '../network_backend.dart';

extension _NetworkBackendWireDecoding on _NetworkBackendTransport {
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

Future<List<int>> consolidateHttpClientResponseBytes(
  HttpClientResponse response,
) {
  final completer = Completer<List<int>>();
  final chunks = <List<int>>[];

  response.listen(
    (chunk) => chunks.add(chunk),
    onDone: () => completer.complete(chunks.expand((x) => x).toList()),
    onError: completer.completeError,
    cancelOnError: true,
  );

  return completer.future;
}
