/// TCP port the headless API server (and the web dashboard on it) binds when
/// neither the settings nor `SKOTIQ_PORT` say otherwise.
const int kDefaultHeadlessPort = 8080;

/// Signaling port a discovered host is assumed to use when its advert names
/// none (QR codes and beacons older than the signaling key).
const int kDefaultSignalingPort = 45678;

/// UDP port hosts listen on for discovery probes and update-push probes.
const int kDiscoveryPort = 45679;

/// TCP port of a host's LAN update-push receiver. `skotiq_updater` declares
/// the same number as `LanPushReceiver.pushPort`; it cannot import this
/// package, and a desktop test keeps the two equal.
const int kLanUpdatePushPort = 45680;
