import 'dart:async';

class CollaborationViewer {
  final String viewerId;
  final String name;
  final DateTime joinedAt;

  const CollaborationViewer({
    required this.viewerId,
    required this.name,
    required this.joinedAt,
  });

  Map<String, dynamic> toJson() => {
    'viewerId': viewerId,
    'name': name,
    'joinedAt': joinedAt.toIso8601String(),
  };
}

class CollaborationChatMessage {
  final String viewerId;
  final String viewerName;
  final String message;
  final DateTime timestamp;

  const CollaborationChatMessage({
    required this.viewerId,
    required this.viewerName,
    required this.message,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'viewerId': viewerId,
    'viewerName': viewerName,
    'message': message,
    'timestamp': timestamp.toIso8601String(),
  };
}

class CollaborationAnnotation {
  final String annotationId;
  final String viewerId;
  final String kind;
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  const CollaborationAnnotation({
    required this.annotationId,
    required this.viewerId,
    required this.kind,
    required this.payload,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'annotationId': annotationId,
    'viewerId': viewerId,
    'kind': kind,
    'payload': payload,
    'timestamp': timestamp.toIso8601String(),
  };
}

class LiveCollaborationState {
  final Map<String, dynamic>? preview;
  final Map<String, dynamic>? sessionHandoff;
  final List<CollaborationViewer> viewers;
  final List<CollaborationChatMessage> chat;
  final List<CollaborationAnnotation> annotations;

  const LiveCollaborationState({
    required this.preview,
    required this.sessionHandoff,
    required this.viewers,
    required this.chat,
    required this.annotations,
  });

  Map<String, dynamic> toJson() => {
    'preview': preview,
    'sessionHandoff': sessionHandoff,
    'viewers': viewers.map((viewer) => viewer.toJson()).toList(growable: false),
    'chat': chat.map((entry) => entry.toJson()).toList(growable: false),
    'annotations': annotations
        .map((entry) => entry.toJson())
        .toList(growable: false),
  };
}

class LiveCollaborationSessionManager {
  LiveCollaborationState _state = const LiveCollaborationState(
    preview: null,
    sessionHandoff: null,
    viewers: [],
    chat: [],
    annotations: [],
  );

  final _controller = StreamController<LiveCollaborationState>.broadcast();

  Stream<LiveCollaborationState> get stream => _controller.stream;
  LiveCollaborationState get state => _state;

  void updatePreview(Map<String, dynamic>? preview) {
    _emit(_copyWith(preview: preview));
  }

  void upsertViewer(String viewerId, String name) {
    final viewers = [
      ..._state.viewers.where((viewer) => viewer.viewerId != viewerId),
    ];
    viewers.add(
      CollaborationViewer(
        viewerId: viewerId,
        name: name,
        joinedAt: DateTime.now(),
      ),
    );
    viewers.sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    _emit(_copyWith(viewers: viewers));
  }

  void removeViewer(String viewerId) {
    _emit(
      _copyWith(
        viewers: _state.viewers
            .where((viewer) => viewer.viewerId != viewerId)
            .toList(growable: false),
      ),
    );
  }

  void addChat({
    required String viewerId,
    required String viewerName,
    required String message,
  }) {
    final chat = [..._state.chat];
    chat.add(
      CollaborationChatMessage(
        viewerId: viewerId,
        viewerName: viewerName,
        message: message,
        timestamp: DateTime.now(),
      ),
    );
    _emit(_copyWith(chat: chat.takeLast(50).toList(growable: false)));
  }

  void addAnnotation({
    required String annotationId,
    required String viewerId,
    required String kind,
    required Map<String, dynamic> payload,
  }) {
    final annotations = [
      ..._state.annotations.where(
        (annotation) => annotation.annotationId != annotationId,
      ),
      CollaborationAnnotation(
        annotationId: annotationId,
        viewerId: viewerId,
        kind: kind,
        payload: payload,
        timestamp: DateTime.now(),
      ),
    ];
    _emit(
      _copyWith(annotations: annotations.takeLast(100).toList(growable: false)),
    );
  }

  void setSessionHandoff(Map<String, dynamic>? handoff) {
    _emit(_copyWith(sessionHandoff: handoff));
  }

  void dispose() {
    _controller.close();
  }

  LiveCollaborationState _copyWith({
    Map<String, dynamic>? preview,
    Object? sessionHandoff = _unset,
    List<CollaborationViewer>? viewers,
    List<CollaborationChatMessage>? chat,
    List<CollaborationAnnotation>? annotations,
  }) {
    return LiveCollaborationState(
      preview: preview ?? _state.preview,
      sessionHandoff: identical(sessionHandoff, _unset)
          ? _state.sessionHandoff
          : sessionHandoff as Map<String, dynamic>?,
      viewers: viewers ?? _state.viewers,
      chat: chat ?? _state.chat,
      annotations: annotations ?? _state.annotations,
    );
  }

  void _emit(LiveCollaborationState nextState) {
    _state = nextState;
    if (!_controller.isClosed) {
      _controller.add(_state);
    }
  }
}

const Object _unset = Object();

extension<T> on List<T> {
  Iterable<T> takeLast(int count) {
    if (length <= count) {
      return this;
    }
    return skip(length - count);
  }
}
