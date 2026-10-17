import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// One access point seen by a scan, in the shape the positioning services
/// want: a BSSID and how loud it was here.
///
/// The pair is what makes Wi-Fi positioning precise. The BSSID identifies a
/// radio whose position the service already knows; the signal strength says
/// how far from it this machine is. Three or four of those trilaterate to a
/// yard, where a public IP only ever resolves to an internet provider.
class WifiAccessPoint {
  const WifiAccessPoint({
    required this.macAddress,
    required this.signalStrengthDbm,
    this.channel,
  });

  /// Lower-case, colon-separated BSSID (`aa:bb:cc:dd:ee:ff`). Both services
  /// reject other spellings.
  final String macAddress;

  /// Received signal strength in dBm — always negative, stronger is closer to
  /// zero.
  final int signalStrengthDbm;

  /// 802.11 channel, when the scanner reported one. Optional in both request
  /// formats; it disambiguates a radio broadcasting on two bands.
  final int? channel;

  Map<String, Object?> toGeolocateJson() => <String, Object?>{
    'macAddress': macAddress,
    'signalStrength': signalStrengthDbm,
    if (channel != null) 'channel': channel,
  };
}

/// What a scan attempt actually produced.
///
/// Every non-`ok` case is a different thing to tell the operator and a
/// different thing to offer them, so they are distinct types rather than an
/// empty list plus a log line: "the radio is off" is one click from a precise
/// fix, "this machine has no Wi-Fi" never will be.
sealed class WifiScanOutcome {
  const WifiScanOutcome();

  /// One line for the confirmation or the failure message, written for an
  /// operator rather than a log reader.
  String get detail;
}

/// At least one access point was heard.
final class WifiScanOk extends WifiScanOutcome {
  const WifiScanOk(this.accessPoints);

  final List<WifiAccessPoint> accessPoints;

  @override
  String get detail => accessPoints.length == 1
      ? 'Heard 1 nearby Wi-Fi network.'
      : 'Heard ${accessPoints.length} nearby Wi-Fi networks.';
}

/// The machine has no wireless interface at all — a wired observatory PC.
final class WifiScanNoAdapter extends WifiScanOutcome {
  const WifiScanNoAdapter();

  @override
  String get detail => 'This machine has no Wi-Fi adapter.';
}

/// The interface exists but its radio is switched off. The only outcome the
/// UI can offer to fix in place.
final class WifiScanRadioOff extends WifiScanOutcome {
  const WifiScanRadioOff();

  @override
  String get detail => 'Wi-Fi is switched off on this machine.';
}

/// The radio scanned and heard nothing — genuinely no networks in range.
final class WifiScanNoNetworks extends WifiScanOutcome {
  const WifiScanNoNetworks();

  @override
  String get detail => 'No Wi-Fi networks are in range.';
}

/// No scanner is implemented for this platform.
///
/// Honest rather than silent: macOS dropped the unprivileged BSSID list in
/// Sonoma (`airport -s` is gone and `CoreWLAN` needs the Location Services
/// entitlement this desktop build does not carry), so claiming a scan there
/// would be a lie. The IP tier still answers.
final class WifiScanUnsupportedPlatform extends WifiScanOutcome {
  const WifiScanUnsupportedPlatform(this.operatingSystem);

  final String operatingSystem;

  @override
  String get detail =>
      'Skotiq cannot scan for Wi-Fi networks on $operatingSystem.';
}

/// Exit status and output of one external command.
class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// A command that could not be started at all — the binary is absent.
  static const CommandResult notFound = CommandResult(
    exitCode: 127,
    stdout: '',
    stderr: 'command not found',
  );

  bool get ok => exitCode == 0;
}

/// Runs an external command. Injected so every scanner path — including the
/// radio-power flow, which changes the machine's state — is driven in tests
/// without a wireless card.
typedef ProcessRunner =
    Future<CommandResult> Function(String executable, List<String> arguments);

Future<CommandResult> _runProcess(
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(executable, arguments);
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  } on ProcessException {
    return CommandResult.notFound;
  }
}

/// Lists the wireless access points this machine can hear, without joining
/// any of them.
///
/// A scan is a passive read of beacon frames: no association, no credentials,
/// no traffic. The BSSIDs it returns are handed straight to a positioning
/// service and then dropped — nothing here writes them to disk.
class WifiScanner {
  /// [operatingSystem] defaults to empty, meaning "ask [Platform]" — a const
  /// constructor cannot read it, and a test that names a platform must be
  /// able to drive the Windows branch from Linux.
  const WifiScanner({
    ProcessRunner runner = _runProcess,
    String operatingSystem = '',
  }) : _run = runner,
       _os = operatingSystem;

  final ProcessRunner _run;
  final String _os;

  String get _platform => _os.isEmpty ? Platform.operatingSystem : _os;

  /// Signal strengths weaker than this are noise for positioning: the service
  /// weights by distance, and a -90 dBm beacon from three streets over pulls
  /// the estimate towards a radio nowhere near this site.
  static const int minimumUsefulDbm = -90;

  /// Scan for access points on whichever platform this is.
  Future<WifiScanOutcome> scan() async {
    return switch (_platform) {
      'linux' => _scanLinux(),
      'windows' => _scanWindows(),
      final other => WifiScanUnsupportedPlatform(other),
    };
  }

  /// Whether this platform can switch the radio on from inside the app.
  ///
  /// Linux only: NetworkManager exposes `nmcli radio wifi on`. Windows has no
  /// supported command-line equivalent (the radio-management API needs a
  /// packaged app identity), so the Windows UI never offers it.
  bool get canToggleRadio => _platform == 'linux';

  /// True when a wireless interface exists but its radio is off. False on any
  /// platform that cannot answer the question.
  Future<bool> radioIsOff() async {
    if (!canToggleRadio) return false;
    final radio = await _run('nmcli', const ['radio', 'wifi']);
    return radio.ok && radio.stdout.trim().toLowerCase() == 'disabled';
  }

  /// Switch the radio on. Only ever called from an explicit click.
  Future<bool> enableRadio() async {
    if (!canToggleRadio) return false;
    final result = await _run('nmcli', const ['radio', 'wifi', 'on']);
    return result.ok;
  }

  /// Switch the radio back off, restoring the state the operator left it in.
  Future<bool> disableRadio() async {
    if (!canToggleRadio) return false;
    final result = await _run('nmcli', const ['radio', 'wifi', 'off']);
    return result.ok;
  }

  /// How many times to ask NetworkManager for the list after enabling the
  /// radio.
  ///
  /// Measured on the owner's box: `nmcli radio wifi on` returns immediately,
  /// but the interface reports `unavailable` for the next two `--rescan yes`
  /// calls and only answers with results on the third. Each call blocks until
  /// NetworkManager finishes its own scan, so this is a retry count, not a
  /// poll loop with a sleep.
  static const int _linuxScanAttempts = 5;

  Future<WifiScanOutcome> _scanLinux() async {
    final devices = await _run('nmcli', const ['-t', '-f', 'TYPE', 'dev']);
    if (!devices.ok) return _scanLinuxWithIw();
    if (!devices.stdout
        .split('\n')
        .map((line) => line.trim())
        .contains('wifi')) {
      return const WifiScanNoAdapter();
    }

    final radio = await _run('nmcli', const ['radio', 'wifi']);
    if (radio.ok && radio.stdout.trim().toLowerCase() == 'disabled') {
      return const WifiScanRadioOff();
    }

    for (var attempt = 0; attempt < _linuxScanAttempts; attempt++) {
      final list = await _run('nmcli', const [
        '-t',
        '-f',
        'BSSID,SIGNAL,CHAN,SSID',
        'dev',
        'wifi',
        'list',
        '--rescan',
        'yes',
      ]);
      if (!list.ok) break;
      final points = parseNmcliList(list.stdout);
      if (points.isNotEmpty) return WifiScanOk(points);
    }
    return const WifiScanNoNetworks();
  }

  /// Fallback for a machine with a wireless card but no NetworkManager.
  ///
  /// `iw dev <if> scan` needs CAP_NET_ADMIN, which this app does not have and
  /// must not acquire with `sudo`; `scan dump` reads the kernel's cached
  /// results unprivileged. The cache is only as fresh as whatever last
  /// triggered a scan, which is why it is the fallback and not the primary —
  /// but its signal figures are true dBm from the driver rather than a
  /// percentage, so what it does return is better than what nmcli reports.
  Future<WifiScanOutcome> _scanLinuxWithIw() async {
    final interfaces = await _run('iw', const ['dev']);
    if (!interfaces.ok) return const WifiScanNoAdapter();
    final name = parseIwInterfaceName(interfaces.stdout);
    if (name == null) return const WifiScanNoAdapter();

    final dump = await _run('iw', ['dev', name, 'scan', 'dump']);
    if (!dump.ok) return const WifiScanNoNetworks();
    final points = parseIwScanDump(dump.stdout);
    return points.isEmpty ? const WifiScanNoNetworks() : WifiScanOk(points);
  }

  Future<WifiScanOutcome> _scanWindows() async {
    final result = await _run('netsh', const [
      'wlan',
      'show',
      'networks',
      'mode=bssid',
    ]);
    final text = '${result.stdout}\n${result.stderr}'.toLowerCase();
    // netsh reports every one of these on stdout with exit code 0, so the
    // status alone cannot tell them apart. Match the phrases, not the word
    // "radio": each BSSID block carries a `Radio type : 802.11n` line, so a
    // bare `contains('radio')` calls a healthy adapter switched off.
    if (text.contains('wlansvc') ||
        text.contains('no wireless interface') ||
        text.contains('service is not running')) {
      return const WifiScanNoAdapter();
    }
    if (text.contains('powered down') ||
        text.contains('hardware radio switch')) {
      return const WifiScanRadioOff();
    }
    if (!result.ok) return const WifiScanNoAdapter();

    final points = parseNetshNetworks(result.stdout);
    return points.isEmpty ? const WifiScanNoNetworks() : WifiScanOk(points);
  }

  /// Parse `nmcli -t -f BSSID,SIGNAL,CHAN,SSID dev wifi list`.
  ///
  /// Two traps in that format. `-t` escapes the colons *inside* the BSSID as
  /// `\:` while still using a bare colon as the field separator, so a naive
  /// `split(':')` shreds every row. And SIGNAL is NetworkManager's 0–100
  /// quality, not dBm: NM maps dBm onto that scale by clamping to −100…−40 and
  /// scaling, so the exact inverse is `dBm = round(quality × 0.6) − 100`.
  /// Checked against `iw scan dump` on a live 12-network scan: 40→−76, 59→−65,
  /// 70→−58, 87→−48, all within a dB. The clamp means anything stronger than
  /// −40 dBm reports −40, which is harmless — a service that sees −40 already
  /// knows the radio is on top of you.
  @visibleForTesting
  static List<WifiAccessPoint> parseNmcliList(String stdout) {
    final points = <WifiAccessPoint>[];
    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) continue;
      final fields = line.split(_nmcliFieldSeparator);
      if (fields.length < 3) continue;
      final mac = _normaliseMac(fields[0].replaceAll(r'\:', ':'));
      if (mac == null) continue;
      final quality = int.tryParse(fields[1].trim());
      if (quality == null) continue;
      final ssid = fields.length > 3
          ? fields.sublist(3).join(':').replaceAll(r'\:', ':')
          : '';
      if (_optedOut(ssid)) continue;
      final dbm = (quality * 0.6).round() - 100;
      if (dbm < minimumUsefulDbm) continue;
      points.add(
        WifiAccessPoint(
          macAddress: mac,
          signalStrengthDbm: dbm,
          channel: int.tryParse(fields[2].trim()),
        ),
      );
    }
    return points;
  }

  /// A colon that is not preceded by a backslash — nmcli's real field split.
  static final RegExp _nmcliFieldSeparator = RegExp(r'(?<!\\):');

  /// Parse `netsh wlan show networks mode=bssid`.
  ///
  /// The output is a nested block: one `SSID N : name` header, then a
  /// `BSSID N`/`Signal`/`Channel` triple per radio underneath it. Signal is a
  /// quality percentage; Microsoft documents the mapping as linear over
  /// −100…−50 dBm, giving `dBm = quality / 2 − 100`.
  @visibleForTesting
  static List<WifiAccessPoint> parseNetshNetworks(String stdout) {
    final points = <WifiAccessPoint>[];
    var ssid = '';
    String? mac;
    int? dbm;
    int? channel;

    void flush() {
      final pending = mac;
      final strength = dbm;
      if (pending != null &&
          strength != null &&
          strength >= minimumUsefulDbm &&
          !_optedOut(ssid)) {
        points.add(
          WifiAccessPoint(
            macAddress: pending,
            signalStrengthDbm: strength,
            channel: channel,
          ),
        );
      }
      mac = null;
      dbm = null;
      channel = null;
    }

    for (final line in stdout.split('\n')) {
      final separator = line.indexOf(':');
      if (separator < 0) continue;
      final key = line.substring(0, separator).trim().toLowerCase();
      final value = line.substring(separator + 1).trim();

      if (key.startsWith('ssid') && !key.startsWith('bssid')) {
        flush();
        ssid = value;
      } else if (key.startsWith('bssid')) {
        flush();
        mac = _normaliseMac(value);
      } else if (key == 'signal') {
        final quality = int.tryParse(value.replaceAll('%', '').trim());
        if (quality != null) dbm = (quality / 2).round() - 100;
      } else if (key == 'channel') {
        channel = int.tryParse(value);
      }
    }
    flush();
    return points;
  }

  /// Pull the first wireless interface name out of `iw dev`.
  @visibleForTesting
  static String? parseIwInterfaceName(String stdout) {
    for (final line in stdout.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('Interface ')) continue;
      final name = trimmed.substring('Interface '.length).trim();
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  /// Parse `iw dev <if> scan dump`: `BSS aa:bb:…(on wlan0)` headers with an
  /// indented `signal: -65.00 dBm`, `DS Parameter set: channel 6` and
  /// `SSID: name` underneath.
  @visibleForTesting
  static List<WifiAccessPoint> parseIwScanDump(String stdout) {
    final points = <WifiAccessPoint>[];
    String? mac;
    int? dbm;
    int? channel;
    var ssid = '';

    void flush() {
      final pending = mac;
      final strength = dbm;
      if (pending != null &&
          strength != null &&
          strength >= minimumUsefulDbm &&
          !_optedOut(ssid)) {
        points.add(
          WifiAccessPoint(
            macAddress: pending,
            signalStrengthDbm: strength,
            channel: channel,
          ),
        );
      }
      mac = null;
      dbm = null;
      channel = null;
      ssid = '';
    }

    for (final line in stdout.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('BSS ')) {
        flush();
        final candidate = trimmed.substring(4).split('(').first.trim();
        mac = _normaliseMac(candidate);
      } else if (trimmed.startsWith('signal:')) {
        final value = double.tryParse(
          trimmed.substring('signal:'.length).replaceAll('dBm', '').trim(),
        );
        if (value != null) dbm = value.round();
      } else if (trimmed.startsWith('DS Parameter set: channel ')) {
        channel = int.tryParse(
          trimmed.substring('DS Parameter set: channel '.length).trim(),
        );
      } else if (trimmed.startsWith('SSID: ')) {
        ssid = trimmed.substring('SSID: '.length).trim();
      }
    }
    flush();
    return points;
  }

  /// The `_nomap` opt-out: a network whose SSID ends in `_nomap` has asked not
  /// to be used for geolocation. It is the convention every positioning
  /// service honours, and honouring it here means the request never carries
  /// the network in the first place.
  static bool _optedOut(String ssid) => ssid.toLowerCase().endsWith('_nomap');

  static final RegExp _macPattern = RegExp(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$');

  static String? _normaliseMac(String raw) {
    final candidate = raw.trim().toLowerCase().replaceAll('-', ':');
    return _macPattern.hasMatch(candidate) ? candidate : null;
  }
}
