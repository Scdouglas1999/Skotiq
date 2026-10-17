/// A truthful snapshot of whether a critical alert can actually be pushed to a
/// phone right now.
///
/// Exists because the "Push critical alerts to mobile" setting used to render
/// as a plain ON switch regardless of whether ANY device could receive a push.
/// On Android that was never true in a stock build: the FCM client is a dormant
/// scaffold pending Firebase provisioning (`google-services.json` is absent),
/// so the phone logs
/// `FCM not configured (no google-services.json); push registration dormant`
/// and never registers a token. The switch therefore asserted a capability the
/// system did not have.
///
/// Two independent things must both hold for a push to land:
///   * at least one paired device has registered a push token
///     ([registeredDeviceCount] > 0), and
///   * the host's delivery channel actually reaches phones
///     ([PushDeliveryChannel.cloud]) — a recording mock is a separate state,
///     not a flavour of configured.
///
/// [canDeliver] is the single question the UI should ask.
library;

/// What a host's push delivery does with an alert.
enum PushDeliveryChannel {
  /// Nothing is wired: a registered token has nowhere to receive from.
  none('none'),

  /// A recording test double is wired. It stores the (frame, token) pairs it
  /// would have sent and nothing leaves the host.
  mock('mock'),

  /// A real FCM/APNs credential is wired.
  cloud('cloud');

  const PushDeliveryChannel(this.wire);

  /// Value carried on the `/api/push/targets` wire.
  final String wire;

  /// Whether an alert handed to this channel can reach a phone.
  bool get deliversToDevices => this == PushDeliveryChannel.cloud;

  static PushDeliveryChannel fromWire(String? wire) => switch (wire) {
    'cloud' => PushDeliveryChannel.cloud,
    'mock' => PushDeliveryChannel.mock,
    _ => PushDeliveryChannel.none,
  };
}

class PushDeliveryTargets {
  /// Paired devices with at least one registered push token.
  final int registeredDeviceCount;

  /// Registered Android (FCM) tokens.
  final int fcmTokenCount;

  /// Registered iOS (APNs) tokens.
  final int apnsTokenCount;

  /// What the host's wired delivery does with an alert.
  final PushDeliveryChannel channel;

  /// [channel] is authoritative. [cloudDeliveryConfigured] stands in for hosts
  /// that only report the two-state answer: true reads as
  /// [PushDeliveryChannel.cloud], false as [PushDeliveryChannel.none].
  const PushDeliveryTargets({
    required this.registeredDeviceCount,
    required this.fcmTokenCount,
    required this.apnsTokenCount,
    bool cloudDeliveryConfigured = false,
    PushDeliveryChannel? channel,
  }) : channel =
           channel ??
           (cloudDeliveryConfigured
               ? PushDeliveryChannel.cloud
               : PushDeliveryChannel.none);

  /// Nothing registered, nothing configured — the honest default before a
  /// host has answered.
  static const PushDeliveryTargets none = PushDeliveryTargets(
    registeredDeviceCount: 0,
    fcmTokenCount: 0,
    apnsTokenCount: 0,
    channel: PushDeliveryChannel.none,
  );

  /// Whether the host's channel reaches phones. A recording mock does not.
  bool get cloudDeliveryConfigured => channel.deliversToDevices;

  /// Whether a critical alert could actually reach a phone right now.
  bool get canDeliver => registeredDeviceCount > 0 && channel.deliversToDevices;

  /// Why delivery is impossible, or `null` when it is possible. Phrased for
  /// direct display to an operator.
  String? get blockedReason {
    final channelReason = switch (channel) {
      PushDeliveryChannel.cloud => null,
      PushDeliveryChannel.mock =>
        'This host records pushes to a local mock instead of sending them',
      PushDeliveryChannel.none => 'This host has no push delivery configured',
    };
    if (registeredDeviceCount == 0 && channelReason != null) {
      return 'No device has registered for push, and '
          '${channelReason[0].toLowerCase()}${channelReason.substring(1)}';
    }
    if (registeredDeviceCount == 0) {
      return 'No paired device has registered for push';
    }
    return channelReason;
  }

  Map<String, dynamic> toJson() => {
    'registeredDeviceCount': registeredDeviceCount,
    'fcmTokenCount': fcmTokenCount,
    'apnsTokenCount': apnsTokenCount,
    'deliveryChannel': channel.wire,
    // Kept for clients that only read the two-state answer.
    'cloudDeliveryConfigured': cloudDeliveryConfigured,
    // Derived, but sent so a client cannot drift from the host's own verdict.
    'canDeliver': canDeliver,
  };

  /// A payload carrying `deliveryChannel` is taken at its word; one carrying
  /// only `cloudDeliveryConfigured` collapses to cloud/none.
  factory PushDeliveryTargets.fromJson(Map<String, dynamic> json) {
    final wire = json['deliveryChannel'] as String?;
    return PushDeliveryTargets(
      registeredDeviceCount:
          (json['registeredDeviceCount'] as num?)?.toInt() ?? 0,
      fcmTokenCount: (json['fcmTokenCount'] as num?)?.toInt() ?? 0,
      apnsTokenCount: (json['apnsTokenCount'] as num?)?.toInt() ?? 0,
      channel: wire != null
          ? PushDeliveryChannel.fromWire(wire)
          : ((json['cloudDeliveryConfigured'] as bool? ?? false)
                ? PushDeliveryChannel.cloud
                : PushDeliveryChannel.none),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PushDeliveryTargets &&
          other.registeredDeviceCount == registeredDeviceCount &&
          other.fcmTokenCount == fcmTokenCount &&
          other.apnsTokenCount == apnsTokenCount &&
          other.channel == channel;

  @override
  int get hashCode => Object.hash(
    registeredDeviceCount,
    fcmTokenCount,
    apnsTokenCount,
    channel,
  );

  @override
  String toString() =>
      'PushDeliveryTargets(devices: $registeredDeviceCount, '
      'fcm: $fcmTokenCount, apns: $apnsTokenCount, '
      'channel: ${channel.wire})';
}
