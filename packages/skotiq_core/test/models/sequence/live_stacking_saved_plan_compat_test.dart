// A Live Stacking node used to carry a broadcast port and path that nothing
// bound or served (the broadcast is `/broadcast` on the host's API server).
// The fields are gone; plans saved while they existed must still open and
// keep everything else they hold.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  test('a plan saved with the old port and path still loads', () {
    final node = SequenceFileService().nodeFromMap(<String, dynamic>{
      'authToken': 'secret-token',
      'broadcastEnabled': false,
      'broadcastPath': '/live',
      'broadcastPort': 9090,
      'childIds': <String>[],
      'comment': 'live note',
      'id': 'n-LiveStacking',
      'isEnabled': true,
      'maxFramesToStack': 50,
      'mode': 'record_and_broadcast',
      'name': 'Stack live',
      'nodeType': 'LiveStacking',
      'orderIndex': 0,
      'parentId': null,
      'stackMethod': 'sigma',
      'thumbnailHeight': 1080,
      'thumbnailWidth': 1920,
      'watermarkText': 'Backyard',
    });

    expect(node, isA<LiveStackingNode>());
    final live = node as LiveStackingNode;
    expect(live.mode, LiveStackingMode.recordAndBroadcast);
    expect(live.stackMethod, LiveStackingMethod.sigma);
    expect(live.broadcastEnabled, isFalse);
    expect(live.authToken, 'secret-token');
    expect(live.maxFramesToStack, 50);
    expect(live.watermarkText, 'Backyard');
    expect(live.thumbnailWidth, 1920);
  });

  test('saved again, the plan no longer carries them', () {
    final map = SequenceFileService().nodeToMap(LiveStackingNode(id: 'ls'));
    expect(map.keys, isNot(contains('broadcastPort')));
    expect(map.keys, isNot(contains('broadcastPath')));
  });
}
