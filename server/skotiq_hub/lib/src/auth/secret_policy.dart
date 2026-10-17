/// Minimum-strength policy for the operator-supplied hub secret.
///
/// The secret is doubly load-bearing: it seeds the SHA-256 server fingerprint
/// AND is the bootstrap admin account's password. A guessable value (the classic
/// `change-me` placeholder, or any short/low-entropy string) therefore hands an
/// attacker full admin access. The entrypoint refuses to start when this returns
/// a non-null reason.
library;

/// The minimum length an operator-supplied secret must have.
const int minSecretLength = 24;

/// The minimum number of distinct characters a secret must contain, a cheap
/// proxy for entropy that rejects `aaaaaaaa...` and other low-variety strings.
const int minSecretDistinctChars = 8;

/// Obvious placeholders that must never reach production, matched case-insensitively
/// after trimming. Not exhaustive — the length/variety checks catch the rest.
const Set<String> _knownWeakSecrets = <String>{
  'change-me',
  'changeme',
  'change_me',
  'secret',
  'password',
  'admin',
  'skotiq',
  'test',
  'hub',
};

/// Returns a human-readable reason the [secret] is too weak to start with, or
/// null if it is acceptable. The reason is phrased to slot after
/// "SKOTIQ_HUB_SECRET ..." in an error message.
String? secretWeakness(String secret) {
  final s = secret.trim();
  if (s.isEmpty) return 'must not be empty';
  if (_knownWeakSecrets.contains(s.toLowerCase())) {
    return 'is a well-known placeholder and is not allowed';
  }
  if (s.length < minSecretLength) {
    return 'is too short (need at least $minSecretLength characters, got '
        '${s.length})';
  }
  final distinct = s.split('').toSet().length;
  if (distinct < minSecretDistinctChars) {
    return 'has too little variety (need at least $minSecretDistinctChars '
        'distinct characters, got $distinct)';
  }
  return null;
}
