#!/usr/bin/env python3
"""Make the throwaway key material an OTA rehearsal needs.

  <out>/update_public.b64    base64 raw Ed25519 public key   (the dart-define)
  <out>/update_private.b64   base64 raw 32-byte Ed25519 seed (the CI secret)
  <out>/other_private.b64    a second seed, for "signed with the wrong key"
  <out>/tls/ca.crt           a rehearsal CA the namespace shim trusts
  <out>/tls/srv.crt|srv.key  a server cert for api.github.com, github.com,
                             objects.githubusercontent.com (and 10.0.2.2 for
                             an Android emulator reaching the host)

The formats are exactly what build_update_manifest.dart reads from
SKOTIQ_UPDATE_PRIVATE_KEY and what UpdateVerifier reads from
SKOTIQ_UPDATE_PUBLIC_KEY. Nothing here is ever a release key; keep <out>
outside the repository.
"""

import base64
import datetime
import ipaddress
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

HOSTS = ["api.github.com", "github.com", "objects.githubusercontent.com",
         "localhost"]


def raw_seed(key):
    return key.private_bytes(serialization.Encoding.Raw,
                             serialization.PrivateFormat.Raw,
                             serialization.NoEncryption())


def raw_pub(key):
    return key.public_key().public_bytes(serialization.Encoding.Raw,
                                         serialization.PublicFormat.Raw)


def write(path, data, mode=0o600):
    with open(path, "wb") as fh:
        fh.write(data)
    os.chmod(path, mode)


def main():
    out = sys.argv[1]
    os.makedirs(os.path.join(out, "tls"), exist_ok=True)

    signing = ed25519.Ed25519PrivateKey.generate()
    other = ed25519.Ed25519PrivateKey.generate()
    write(os.path.join(out, "update_public.b64"),
          base64.b64encode(raw_pub(signing)), 0o644)
    write(os.path.join(out, "update_private.b64"),
          base64.b64encode(raw_seed(signing)))
    write(os.path.join(out, "other_private.b64"),
          base64.b64encode(raw_seed(other)))

    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,
                                            "Skotiq OTA rehearsal CA")])
    ca = (x509.CertificateBuilder()
          .subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key())
          .serial_number(x509.random_serial_number())
          .not_valid_before(now - datetime.timedelta(days=1))
          .not_valid_after(now + datetime.timedelta(days=30))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), True)
          .add_extension(x509.KeyUsage(digital_signature=True,
                                       key_cert_sign=True, crl_sign=True,
                                       content_commitment=False,
                                       key_encipherment=False,
                                       data_encipherment=False,
                                       key_agreement=False,
                                       encipher_only=False,
                                       decipher_only=False), True)
          .sign(ca_key, hashes.SHA256()))

    srv_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    sans = [x509.DNSName(h) for h in HOSTS] + [
        x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
        x509.IPAddress(ipaddress.ip_address("10.0.2.2")),
    ]
    srv = (x509.CertificateBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,
                                                       "api.github.com")]))
           .issuer_name(ca_name)
           .public_key(srv_key.public_key())
           .serial_number(x509.random_serial_number())
           .not_valid_before(now - datetime.timedelta(days=1))
           .not_valid_after(now + datetime.timedelta(days=30))
           .add_extension(x509.SubjectAlternativeName(sans), False)
           .add_extension(x509.BasicConstraints(ca=False, path_length=None),
                          True)
           .add_extension(x509.ExtendedKeyUsage(
               [ExtendedKeyUsageOID.SERVER_AUTH]), False)
           .sign(ca_key, hashes.SHA256()))

    tls = os.path.join(out, "tls")
    write(os.path.join(tls, "ca.crt"),
          ca.public_bytes(serialization.Encoding.PEM), 0o644)
    write(os.path.join(tls, "srv.crt"),
          srv.public_bytes(serialization.Encoding.PEM), 0o644)
    write(os.path.join(tls, "srv.key"),
          srv_key.private_bytes(serialization.Encoding.PEM,
                                serialization.PrivateFormat.TraditionalOpenSSL,
                                serialization.NoEncryption()))
    print(f"keys + TLS material written to {out}")


if __name__ == "__main__":
    main()
