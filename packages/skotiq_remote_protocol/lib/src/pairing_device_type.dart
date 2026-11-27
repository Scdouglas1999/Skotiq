/// The kind of device a client names when it pairs (`deviceType` on
/// `/api/pairing/verify` and `/api/pairing/lan-claim`). The host stores the
/// string as sent; [parse] reads every value a release has written.
enum PairingDeviceType {
  /// A phone that did not say which OS it runs.
  mobile('mobile'),
  android('android'),
  ios('iOS'),
  tablet('tablet'),

  /// A computer that did not say which OS it runs.
  desktop('desktop'),
  windows('windows'),
  macos('macOS'),
  linux('linux'),
  browser('browser'),
  web('web');

  const PairingDeviceType(this.wireName);

  final String wireName;

  /// The type a stored or received `deviceType` names, ignoring case; null
  /// for a value no release sends.
  static PairingDeviceType? parse(String? raw) {
    final key = raw?.trim().toLowerCase();
    if (key == null || key.isEmpty) return null;
    for (final type in values) {
      if (type.wireName.toLowerCase() == key) return type;
    }
    return null;
  }

  bool get isPhone => this == mobile || this == android || this == ios;
}
