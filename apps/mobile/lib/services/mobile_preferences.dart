import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mobile-only preferences persisted via SharedPreferences.
///
/// These settings are UI-shell concerns that don't belong in the cross-
/// platform desktop AppSettings model (which is mirrored to the headless
/// server).13 added [androidImmersiveSticky] so users who want
/// status bar / battery / clock visible can opt out of fullscreen.
class MobilePreferences {
  MobilePreferences(this._prefs);

  static const _kAndroidImmersiveSticky = 'mobile.androidImmersiveSticky';

  // WebRTC live-view transport toggle. When true (default),
  // the camera-tab subscribes via `NetworkBackend.subscribeLiveViewAuto`
  // which tries the WebRTC datachannel first and falls back to the WS
  // push protocol on explicit (logged) failure. When false, the tab
  // uses `subscribeLiveView` directly — useful for diagnostics on
  // networks where libwebrtc misbehaves (rare; bundled libwebrtc on
  // some Android skins has buggy ICE state machines).
  static const _kPreferWebRtcLiveView = 'mobile.preferWebRtcLiveView';

  // First-run setup is done on this phone. The wizard then never shows again,
  // even for a host that later loses its profiles, catalogs or capture folder
  // (a wiped data dir): it is a one-time introduction, and every step is also
  // in Settings.
  static const _kFirstRunCompleted = 'mobile.firstRunCompleted';

  // Per-category notification mute toggles. All default to true (enabled)
  // because v2.5 ships with notifications opt-out; the mobile companion is
  // useless during an unattended sequence if the operator can't be paged.
  static const _kNotifySequence = 'mobile.notify.sequence';
  static const _kNotifyMeridianFlip = 'mobile.notify.meridianFlip';
  static const _kNotifySafety = 'mobile.notify.safety';
  static const _kNotifyGuiding = 'mobile.notify.guiding';
  static const _kNotifyExposureFailed = 'mobile.notify.exposureFailed';
  static const _kNotifyAutofocusFailed = 'mobile.notify.autofocusFailed';
  static const _kNotifyEquipmentDisconnected =
      'mobile.notify.equipmentDisconnected';
  static const _kNotifyDiskLow = 'mobile.notify.diskLow';
  static const _kNotifyTargetCompleted = 'mobile.notify.targetCompleted';
  static const _kNotifyBattery = 'mobile.notify.battery';

  final SharedPreferences _prefs;

  /// When true, hide the status bar with Android immersive-sticky mode.
  /// When false, use edge-to-edge mode so the clock and battery stay visible —
  /// astrophotographers monitor those during long sequences.
  /// Default: false.
  bool get androidImmersiveSticky =>
      _prefs.getBool(_kAndroidImmersiveSticky) ?? false;

  Future<void> setAndroidImmersiveSticky(bool value) async {
    await _prefs.setBool(_kAndroidImmersiveSticky, value);
  }

  /// prefer the WebRTC datachannel for the live-view stream.
  /// Defaults to true; when false the camera tab uses the legacy WS
  /// push (`subscribeLiveView`) directly. Persisted across launches so
  /// a user that needs the WS path on a specific network does not have
  /// to re-toggle on every app start.
  bool get preferWebRtcLiveView =>
      _prefs.getBool(_kPreferWebRtcLiveView) ?? true;

  Future<void> setPreferWebRtcLiveView(bool value) =>
      _prefs.setBool(_kPreferWebRtcLiveView, value);

  // Notification category toggles
  //
  // Each toggle gates a specific notification channel emitted by the mobile-
  // direct event subscriber (`MobileEventNotifier`) or by the foreground/
  // power services. Defaults are intentionally ON: an astrophotographer who
  // installs the companion app does so to be paged during failures, so the
  // burden of proof for muting is on the user, not the app.

  bool get notifySequence => _prefs.getBool(_kNotifySequence) ?? true;
  Future<void> setNotifySequence(bool value) =>
      _prefs.setBool(_kNotifySequence, value);

  bool get notifyMeridianFlip => _prefs.getBool(_kNotifyMeridianFlip) ?? true;
  Future<void> setNotifyMeridianFlip(bool value) =>
      _prefs.setBool(_kNotifyMeridianFlip, value);

  bool get notifySafety => _prefs.getBool(_kNotifySafety) ?? true;
  Future<void> setNotifySafety(bool value) =>
      _prefs.setBool(_kNotifySafety, value);

  bool get notifyGuiding => _prefs.getBool(_kNotifyGuiding) ?? true;
  Future<void> setNotifyGuiding(bool value) =>
      _prefs.setBool(_kNotifyGuiding, value);

  bool get notifyExposureFailed =>
      _prefs.getBool(_kNotifyExposureFailed) ?? true;
  Future<void> setNotifyExposureFailed(bool value) =>
      _prefs.setBool(_kNotifyExposureFailed, value);

  bool get notifyAutofocusFailed =>
      _prefs.getBool(_kNotifyAutofocusFailed) ?? true;
  Future<void> setNotifyAutofocusFailed(bool value) =>
      _prefs.setBool(_kNotifyAutofocusFailed, value);

  bool get notifyEquipmentDisconnected =>
      _prefs.getBool(_kNotifyEquipmentDisconnected) ?? true;
  Future<void> setNotifyEquipmentDisconnected(bool value) =>
      _prefs.setBool(_kNotifyEquipmentDisconnected, value);

  bool get notifyDiskLow => _prefs.getBool(_kNotifyDiskLow) ?? true;
  Future<void> setNotifyDiskLow(bool value) =>
      _prefs.setBool(_kNotifyDiskLow, value);

  /// Per-target-completed pings are noisier than sequence-level events, so
  /// the operator may want them off independently of the sequence toggle.
  bool get notifyTargetCompleted =>
      _prefs.getBool(_kNotifyTargetCompleted) ?? true;
  Future<void> setNotifyTargetCompleted(bool value) =>
      _prefs.setBool(_kNotifyTargetCompleted, value);

  bool get notifyBattery => _prefs.getBool(_kNotifyBattery) ?? true;
  Future<void> setNotifyBattery(bool value) =>
      _prefs.setBool(_kNotifyBattery, value);

  // First-run setup latch
  //
  // Set when the user finishes or skips first-run setup, or when the first
  // host this phone links to needs nothing. Per device, not synced to the host:
  // it records that this phone has been through setup.

  bool get firstRunCompleted => _prefs.getBool(_kFirstRunCompleted) ?? false;
  Future<void> setFirstRunCompleted(bool value) =>
      _prefs.setBool(_kFirstRunCompleted, value);
}

/// Async provider that resolves once SharedPreferences is loaded.
final mobilePreferencesProvider = FutureProvider<MobilePreferences>((
  ref,
) async {
  final prefs = await SharedPreferences.getInstance();
  return MobilePreferences(prefs);
});
