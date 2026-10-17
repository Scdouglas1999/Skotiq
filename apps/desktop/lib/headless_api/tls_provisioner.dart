// first-run self-signed certificate provisioning for headless mode.
//
// Why this exists: shipping TLS-by-default requires a cert/key pair the
// operator does not have to generate themselves. The pairing code, the
// bearer token, and every WebSocket frame all travel in cleartext over plain
// HTTP today (audit F-1/F-2/F-9 in 01-connection-auth.md). When the operator
// opts in with `--tls`, this provisioner creates an RSA-2048 keypair and a
// 10-year self-signed X.509 cert under `$APPDATA/server.{crt,key}`, then
// returns a Dart `SecurityContext` the headless server can hand to
// `shelf_io.serve(..., securityContext:)`.
//
// Why self-signed: the brief explicitly chose this over a public CA — the
// server is a LAN-only daemon. The cert's SubjectPublicKeyInfo SHA-256 is
// exposed by `HeadlessApiServer._serverFingerprint` so QR / first-connect
// flows can pin the public key; phones never trust the cert chain.
//
// File permissions: on Linux/macOS we `chmod 600` the private key. Windows
// inherits the user-private app-data ACLs from the parent directory.

import 'dart:async';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart' as butils;
import 'package:pointycastle/export.dart' as pc;

/// Result of running [provisionTlsContext]: a [SecurityContext] suitable for
/// `shelf_io.serve`, plus the cert's public-key fingerprint that the
/// headless server pins into `/api/info` for client-side trust.
class TlsProvisionResult {
  final SecurityContext securityContext;

  /// SHA-256 hex digest of the cert's SubjectPublicKeyInfo DER. Stable
  /// across server restarts (it depends only on the key file, not on
  /// runtime state), so QR codes and first-connect TOFU records pin
  /// against this. 64 lowercase hex chars.
  final String publicKeyFingerprintSha256;

  /// Absolute path of the resolved cert PEM file. Useful for the operator
  /// banner so they can `scp` it to clients.
  final String certificatePath;

  /// Absolute path of the resolved private-key PEM file. NOT logged or
  /// exposed; only retained here for the operator banner.
  final String privateKeyPath;

  /// Validity window of the cert as `(notBefore, notAfter)` UTC.
  final ({DateTime notBefore, DateTime notAfter}) validity;

  TlsProvisionResult({
    required this.securityContext,
    required this.publicKeyFingerprintSha256,
    required this.certificatePath,
    required this.privateKeyPath,
    required this.validity,
  });
}

/// Generate or load a self-signed TLS cert and return a configured
/// [SecurityContext]. Existing on-disk cert/key files at the supplied paths
/// (or the default `$APPDATA/server.{crt,key}` when null) are reused
/// verbatim. New files are created with RSA-2048 / SHA-256 / 10-year
/// validity, and SubjectAltName entries covering `127.0.0.1`, `localhost`,
/// and every non-loopback IPv4 of the host.
Future<TlsProvisionResult> provisionTlsContext({
  required String appDataDirectory,
  String? certPath,
  String? keyPath,
}) async {
  final resolvedCert = certPath ?? _defaultPath(appDataDirectory, 'server.crt');
  final resolvedKey = keyPath ?? _defaultPath(appDataDirectory, 'server.key');

  final certFile = File(resolvedCert);
  final keyFile = File(resolvedKey);

  if (!await certFile.exists() || !await keyFile.exists()) {
    await _generateSelfSignedPair(certFile: certFile, keyFile: keyFile);
  }

  final certPem = await certFile.readAsString();
  final parsed = butils.X509Utils.x509CertificateFromPem(certPem);

  // SubjectPublicKeyInfo SHA-256 is the right anchor for client-side
  // pinning — it survives certificate re-issuance as long as the keypair
  // is reused, and it is what HPKP-style pin pages digest.
  // basic_utils stores it as upper-case hex on
  // [SubjectPublicKeyInfo.sha256Thumbprint] (computed via
  // `CryptoUtils.getHash(pubKeySequence.encodedBytes, 'SHA-256')`).
  final spkiInfo = parsed.tbsCertificate?.subjectPublicKeyInfo;
  if (spkiInfo == null) {
    throw StateError(
      'Generated certificate at ${certFile.path} is missing its '
      'SubjectPublicKeyInfo block; refusing to start TLS. Delete server.crt '
      'and server.key and retry so the cert is regenerated.',
    );
  }
  final fingerprintUpper = spkiInfo.sha256Thumbprint;
  if (fingerprintUpper == null || fingerprintUpper.isEmpty) {
    throw StateError(
      'Generated certificate at ${certFile.path} is missing its SPKI '
      'SHA-256 thumbprint; basic_utils returned null. Delete server.crt '
      'and server.key and retry.',
    );
  }
  final fingerprint = fingerprintUpper.toLowerCase();

  final validity = parsed.tbsCertificate?.validity;
  if (validity == null) {
    throw StateError(
      'Generated certificate at ${certFile.path} has no validity block; '
      'refusing to start TLS. Delete server.crt and server.key and retry.',
    );
  }

  final context = SecurityContext(withTrustedRoots: false);
  context.useCertificateChain(resolvedCert);
  context.usePrivateKey(resolvedKey);

  return TlsProvisionResult(
    securityContext: context,
    publicKeyFingerprintSha256: fingerprint,
    certificatePath: resolvedCert,
    privateKeyPath: resolvedKey,
    validity: (notBefore: validity.notBefore, notAfter: validity.notAfter),
  );
}

String _defaultPath(String appData, String filename) {
  // Normalise trailing separators so Windows backslashes and POSIX slashes
  // both join cleanly. We deliberately stay on the platform separator the
  // caller passed in (no path package dependency at this layer).
  final sep = Platform.pathSeparator;
  final trimmed = appData.endsWith(sep)
      ? appData.substring(0, appData.length - 1)
      : appData;
  return '$trimmed$sep$filename';
}

Future<void> _generateSelfSignedPair({
  required File certFile,
  required File keyFile,
}) async {
  await certFile.parent.create(recursive: true);

  // 1. RSA-2048 keypair. Why 2048: LetsEncrypt minimum, OWASP 2024-floor,
  // and keeps generation under ~1 s on a Raspberry Pi 4.
  final keyPair = butils.CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final publicKey = keyPair.publicKey as pc.RSAPublicKey;
  final privateKey = keyPair.privateKey as pc.RSAPrivateKey;

  // 2. SAN list — every address a phone might use to reach this host.
  final sans = <String>{'localhost', '127.0.0.1'};
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          sans.add(addr.address);
        }
      }
    }
  } catch (e) {
    // Network enumeration can fail (no interfaces up yet, sandbox). The
    // cert is still valid for loopback. Surface to stderr so the operator
    // knows their LAN IP is not in the SAN list and can reissue later.
    stderr.writeln(
      '[TLS] WARNING: NetworkInterface.list failed during cert generation '
      '($e); SANs limited to localhost/127.0.0.1. Delete server.crt + '
      'server.key after the network is up to reissue with LAN IPs.',
    );
  }

  // 3. CSR with CN=Skotiq Headless. We use this as scaffolding for the
  // self-signed cert (basic_utils' generateSelfSignedCertificate takes a
  // CSR as input).
  final attributes = <String, String>{'CN': 'Skotiq Headless', 'O': 'Skotiq'};
  final csrPem = butils.X509Utils.generateRsaCsrPem(
    attributes,
    privateKey,
    publicKey,
    san: sans.toList(),
  );

  // 4. Issue a self-signed cert from the CSR. 3650 days = 10 years; matches
  // typical embedded-device self-signed lifetimes and outlives any token
  // rotation the operator is likely to perform.
  final certPem = butils.X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    3650,
    sans: sans.toList(),
  );

  // 5. Persist. Private key gets 0600 on POSIX.
  await certFile.writeAsString(certPem, flush: true);
  await keyFile.writeAsString(
    butils.CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
    flush: true,
  );
  await _restrictKeyPermissions(keyFile);
}

Future<void> _restrictKeyPermissions(File keyFile) async {
  if (Platform.isWindows) {
    // Rely on the per-user app-data ACL. There is no portable POSIX-style
    // chmod on NTFS without icacls; the application-support dir is
    // already user-private so the key file inherits that protection.
    return;
  }
  try {
    final result = await Process.run('chmod', ['600', keyFile.path]);
    if (result.exitCode != 0) {
      stderr.writeln(
        '[TLS] WARNING: chmod 600 ${keyFile.path} failed: ${result.stderr}',
      );
    }
  } catch (e) {
    stderr.writeln('[TLS] WARNING: could not restrict key permissions: $e');
  }
}
