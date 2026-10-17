import 'dart:io';
import 'dart:typed_data';

/// Tag for the three FITS value kinds we emit on writeback. Matching the
/// Rust-side `FitsKeywordUpdate` shape so the two implementations stay
/// interchangeable.
enum FitsKeywordKind { string, integer, floating }

/// One header card to set on an existing FITS file.
///
/// Exactly one of [stringValue], [intValue], or [doubleValue] must be non-null;
/// the writer validates this and throws [ArgumentError] otherwise rather than
/// silently dropping the field.
class FitsKeywordWrite {
  final String keyword;
  final String? comment;
  final String? stringValue;
  final int? intValue;
  final double? doubleValue;

  const FitsKeywordWrite._({
    required this.keyword,
    required this.comment,
    required this.stringValue,
    required this.intValue,
    required this.doubleValue,
  });

  factory FitsKeywordWrite.string(
    String keyword,
    String value, {
    String? comment,
  }) => FitsKeywordWrite._(
    keyword: keyword,
    comment: comment,
    stringValue: value,
    intValue: null,
    doubleValue: null,
  );

  factory FitsKeywordWrite.integer(
    String keyword,
    int value, {
    String? comment,
  }) => FitsKeywordWrite._(
    keyword: keyword,
    comment: comment,
    stringValue: null,
    intValue: value,
    doubleValue: null,
  );

  factory FitsKeywordWrite.floating(
    String keyword,
    double value, {
    String? comment,
  }) => FitsKeywordWrite._(
    keyword: keyword,
    comment: comment,
    stringValue: null,
    intValue: null,
    doubleValue: value,
  );

  FitsKeywordKind get kind {
    if (stringValue != null) return FitsKeywordKind.string;
    if (intValue != null) return FitsKeywordKind.integer;
    return FitsKeywordKind.floating;
  }
}

/// Result of a writeback. Useful for status reporting and for telling whether
/// the operation needed an expensive header-growth pass.
class FitsHeaderWriteResult {
  final int keywordsInjected;
  final int keywordsUpdated;
  final bool headerGrew;
  final int headerBlocks;

  const FitsHeaderWriteResult({
    required this.keywordsInjected,
    required this.keywordsUpdated,
    required this.headerGrew,
    required this.headerBlocks,
  });
}

/// Pure-Dart FITS header keyword writer.
///
/// FITS files are structured as 2880-byte blocks of 36×80-character ASCII
/// cards (FITS Standard 4.4). The header ends with an `END` card and is
/// followed by raw data bytes.
///
/// This writer:
///   * Loads the file
///   * Locates `END`
///   * For each requested keyword: overwrites the existing card if present
///     or appends a new card before `END`
///   * Grows the header to the next 2880-byte block if appended cards run
///     out of free space (and shifts the data section down accordingly)
///   * Writes the result atomically via a sibling `*.nshatmp` file + rename
///
/// Why pure Dart: the writeback runs on every captured frame after
/// photometry; doing it in-process avoids both an FFI round-trip and an
/// FRB regeneration cycle. The Rust-side equivalent
/// (`api_update_fits_keywords` in `bridge/src/api/imaging.rs`) remains the
/// canonical implementation for headless / external callers.
class FitsHeaderWriter {
  static const int blockSize = 2880;
  static const int cardSize = 80;
  static const int cardsPerBlock = 36;

  /// Whitelisted FITS-keyword character set: A–Z, 0–9, `-`, `_`. Per
  /// FITS 4.4.2.1 the keyword field is bytes 1..8.
  static final RegExp _keywordPattern = RegExp(r'^[A-Z0-9_-]{1,8}$');

  /// Apply [updates] to [filePath]. Returns a summary; throws on malformed
  /// FITS, missing `END`, or invalid keywords. **Never silently no-ops** on
  /// errors — silent fallbacks are explicitly forbidden by the project
  /// guidance and would hide data-quality issues for months.
  Future<FitsHeaderWriteResult> updateKeywords(
    String filePath,
    List<FitsKeywordWrite> updates,
  ) async {
    if (updates.isEmpty) {
      return const FitsHeaderWriteResult(
        keywordsInjected: 0,
        keywordsUpdated: 0,
        headerGrew: false,
        headerBlocks: 0,
      );
    }
    // Validate updates up-front so we fail before touching disk.
    for (final u in updates) {
      final values = [
        u.stringValue != null,
        u.intValue != null,
        u.doubleValue != null,
      ].where((v) => v).length;
      if (values != 1) {
        throw ArgumentError(
          'FITS keyword update for `${u.keyword}` must set exactly one of '
          'string/int/double (got $values).',
        );
      }
      final upper = u.keyword.toUpperCase();
      if (!_keywordPattern.hasMatch(upper)) {
        throw ArgumentError(
          'FITS keyword `${u.keyword}` is invalid: must be 1..=8 ASCII '
          'alphanumeric/_- characters (FITS 4.4.2.1).',
        );
      }
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('FITS file not found', filePath);
    }

    final bytes = await file.readAsBytes();
    if (bytes.length < blockSize) {
      throw FormatException(
        'File is too small to be a valid FITS file: ${bytes.length} bytes',
      );
    }

    // Locate END within the header. Header is everything from offset 0 up
    // through the block containing `END`, padded to a 2880-byte multiple.
    final endIndex = _findEndCardIndex(bytes);
    if (endIndex < 0) {
      throw const FormatException('FITS header is missing the END card');
    }

    final headerByteEnd = ((endIndex ~/ cardsPerBlock) + 1) * blockSize;
    final dataStart = headerByteEnd;

    // Pull all card entries up to (and including) END.
    final cards = <String>[];
    for (var i = 0; i < endIndex; i++) {
      final off = i * cardSize;
      cards.add(String.fromCharCodes(bytes.sublist(off, off + cardSize)));
    }
    // We exclude the END card itself; we'll re-append it at the very end.

    var updated = 0;
    var injected = 0;
    for (final u in updates) {
      final card = _formatCard(u);
      final keyUpper = u.keyword.toUpperCase();
      final existingIndex = _findCardIndex(cards, keyUpper);
      if (existingIndex >= 0) {
        cards[existingIndex] = card;
        updated++;
      } else {
        cards.add(card);
        injected++;
      }
    }
    cards.add(_endCard());

    // Pad to the next block boundary. Free cards become 80 spaces each.
    final totalCards = cards.length;
    final blocksNeeded = (totalCards + cardsPerBlock - 1) ~/ cardsPerBlock;
    final paddedCardCount = blocksNeeded * cardsPerBlock;
    final blankCard = ' ' * cardSize;
    while (cards.length < paddedCardCount) {
      cards.add(blankCard);
    }

    final headerBytes = Uint8List(blocksNeeded * blockSize);
    for (var i = 0; i < cards.length; i++) {
      final cardBytes = cards[i].codeUnits;
      // Defensive: any non-ASCII code unit would corrupt the file. We
      // already validate at format-time, so this is a belt-and-braces
      // check that helps the writer notice corruption from upstream
      // edits before it lands on disk.
      for (final c in cardBytes) {
        if (c < 0x20 || c > 0x7E) {
          throw FormatException(
            'Card $i contains non-ASCII byte 0x${c.toRadixString(16)}',
          );
        }
      }
      headerBytes.setRange(i * cardSize, (i + 1) * cardSize, cardBytes);
    }

    final headerGrew = headerByteEnd != headerBytes.length;
    final dataBytes = bytes.sublist(dataStart);

    final output = BytesBuilder(copy: false)
      ..add(headerBytes)
      ..add(dataBytes);

    // Atomic write via sibling temp file. If the rename fails we delete the
    // temp to avoid orphaned debris alongside the user's captures.
    final tmpPath = '$filePath.nshatmp';
    final tmpFile = File(tmpPath);
    try {
      await tmpFile.writeAsBytes(output.toBytes(), flush: true);
      // Windows requires the destination to be absent for `rename`; macOS
      // and Linux replace it atomically. `File.rename` matches both
      // behaviours by deleting+renaming under the hood on Windows.
      await tmpFile.rename(filePath);
    } catch (e) {
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {
          // Best-effort cleanup; surfacing the original error is more useful.
        }
      }
      rethrow;
    }

    return FitsHeaderWriteResult(
      keywordsInjected: injected,
      keywordsUpdated: updated,
      headerGrew: headerGrew,
      headerBlocks: blocksNeeded,
    );
  }

  int _findEndCardIndex(Uint8List bytes) {
    final maxCards = bytes.length ~/ cardSize;
    for (var i = 0; i < maxCards; i++) {
      final off = i * cardSize;
      // Inline byte compare to avoid allocating a String per card.
      if (bytes[off] == 0x45 /* E */ &&
          bytes[off + 1] == 0x4E /* N */ &&
          bytes[off + 2] == 0x44 /* D */ &&
          bytes[off + 3] == 0x20 /* space */ ) {
        // Verify the remainder of the card is blank (FITS 4.4.2.1).
        var blank = true;
        for (var k = 3; k < cardSize; k++) {
          if (bytes[off + k] != 0x20) {
            blank = false;
            break;
          }
        }
        if (blank) return i;
      }
    }
    return -1;
  }

  int _findCardIndex(List<String> cards, String keyUpper) {
    final padded = keyUpper.padRight(8);
    for (var i = 0; i < cards.length; i++) {
      final card = cards[i];
      if (card.length < 8) continue;
      // Per FITS 4.4.2.1 the keyword is bytes 1..8 (0-indexed: 0..7) and
      // is left-justified, padded with spaces.
      if (card.substring(0, 8).toUpperCase() == padded) {
        return i;
      }
    }
    return -1;
  }

  String _endCard() => 'END'.padRight(cardSize, ' ');

  String _formatCard(FitsKeywordWrite u) {
    final key = u.keyword.toUpperCase().padRight(8, ' ');
    final valuePart = _formatValue(u);
    const separator = '= ';
    // Per FITS 4.4.2.4, the value indicator `= ` occupies bytes 9..10.
    // Total card = 8 keyword + 2 indicator + 70 value/comment area = 80.
    const remaining = cardSize - 8 - separator.length;
    var rest = _composeValueAndComment(valuePart, u.comment, remaining);
    if (rest.length > remaining) {
      rest = rest.substring(0, remaining);
    } else if (rest.length < remaining) {
      rest = rest.padRight(remaining, ' ');
    }
    return '$key$separator$rest';
  }

  String _formatValue(FitsKeywordWrite u) {
    switch (u.kind) {
      case FitsKeywordKind.string:
        return _formatFitsString(u.stringValue!);
      case FitsKeywordKind.integer:
        // Right-justify integers in the 20-char fixed-format value field
        // (FITS 4.4.2.4) so older readers tolerate them.
        return u.intValue!.toString().padLeft(20, ' ');
      case FitsKeywordKind.floating:
        return _formatFitsFloat(u.doubleValue!).padLeft(20, ' ');
    }
  }

  String _formatFitsString(String value) {
    // Strings are wrapped in single quotes, with internal `'` doubled.
    // Per FITS 4.4.2.4 the quoted string is padded to ≥ 8 chars between
    // the quotes — gives older readers a predictable layout.
    final escaped = value.replaceAll("'", "''");
    final padded = escaped.length < 8 ? escaped.padRight(8, ' ') : escaped;
    return "'$padded'";
  }

  String _formatFitsFloat(double value) {
    if (value.isNaN || value.isInfinite) {
      // FITS doesn't define NaN/Inf cards — surface this instead of
      // smuggling a sentinel that downstream tools will trust.
      throw ArgumentError('Cannot write non-finite float to FITS: $value');
    }
    // Use scientific notation with enough precision to round-trip a
    // typical photometric measurement (~7 significant figures).
    if (value == 0.0) return '0.0';
    final abs = value.abs();
    if (abs >= 1e-4 && abs < 1e16) {
      // Fixed-point keeps headers human-readable.
      return value
          .toStringAsFixed(6)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '.0');
    }
    return value.toStringAsExponential(7).replaceAll('e', 'E');
  }

  String _composeValueAndComment(String value, String? comment, int budget) {
    if (comment == null || comment.isEmpty) return value;
    const marker = ' / ';
    final cleaned = comment.replaceAll('\n', ' ');
    final composed = '$value$marker$cleaned';
    if (composed.length <= budget) return composed;
    // Truncate the comment to fit; never truncate the value.
    final commentBudget = budget - value.length - marker.length;
    if (commentBudget <= 0) return value; // No room for any comment.
    return '$value$marker${cleaned.substring(0, commentBudget)}';
  }
}
