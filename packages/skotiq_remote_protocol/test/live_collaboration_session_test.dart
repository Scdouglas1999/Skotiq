import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('LiveCollaborationSessionManager', () {
    late LiveCollaborationSessionManager manager;

    setUp(() {
      manager = LiveCollaborationSessionManager();
    });

    tearDown(() {
      manager.dispose();
    });

    test('tracks viewers chat annotations preview and handoff', () {
      manager.upsertViewer('viewer-1', 'Alice');
      manager.upsertViewer('viewer-2', 'Bob');
      manager.addChat(
        viewerId: 'viewer-1',
        viewerName: 'Alice',
        message: 'Ready to image',
      );
      manager.addAnnotation(
        annotationId: 'ann-1',
        viewerId: 'viewer-2',
        kind: 'circle',
        payload: const {'x': 11, 'y': 22},
      );
      manager.updatePreview(const {'imageId': 'frame-42', 'stretch': 'auto'});
      manager.setSessionHandoff(const {'sessionId': 7, 'targetName': 'M31'});

      final state = manager.state;
      expect(state.viewers, hasLength(2));
      expect(state.chat.single.message, 'Ready to image');
      expect(state.annotations.single.kind, 'circle');
      expect(state.preview?['imageId'], 'frame-42');
      expect(state.sessionHandoff?['targetName'], 'M31');

      manager.removeViewer('viewer-1');
      expect(manager.state.viewers.map((viewer) => viewer.viewerId), [
        'viewer-2',
      ]);
    });
  });
}
