/// Client-side mirror of the headless server's session-status response.
class RemoteSessionStatus {
  final Map<String, dynamic>? owner;
  final bool isYouTheOwner;
  final String mode; // 'operator' | 'viewer' | 'unowned'
  final int heartbeatTimeoutSeconds;

  const RemoteSessionStatus({
    required this.owner,
    required this.isYouTheOwner,
    required this.mode,
    required this.heartbeatTimeoutSeconds,
  });

  factory RemoteSessionStatus.fromJson(Map<String, dynamic> json) {
    return RemoteSessionStatus(
      owner: json['owner'] is Map
          ? Map<String, dynamic>.from(json['owner'] as Map)
          : null,
      isYouTheOwner: json['isYouTheOwner'] as bool? ?? false,
      mode: json['mode'] as String? ?? 'unowned',
      heartbeatTimeoutSeconds:
          (json['heartbeatTimeoutSeconds'] as num?)?.toInt() ?? 0,
    );
  }
}

// Client-side mirrors of the headless server's /api/catalog/... shapes.
