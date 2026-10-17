/// RFC-4180-compliant CSV parser.
///
/// Handles:
/// * Quoted fields containing commas, newlines, and embedded `""` escapes.
/// * Both LF and CRLF line endings.
/// * Trailing newline (no empty row appended).
/// * Mixed quoted / unquoted fields on the same row.
///
/// Returns one `List<String>` per data row. Empty trailing rows are stripped
/// so callers can iterate without filtering.
class CsvParser {
  /// Parse [content] into rows-of-cells. Throws no exceptions — malformed
  /// quoting is tolerated by treating the unterminated field as terminating
  /// at end-of-input.
  static List<List<String>> parse(String content) {
    final rows = <List<String>>[];
    var current = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;
    var i = 0;

    void finishCell() {
      current.add(cell.toString());
      cell.clear();
    }

    void finishRow() {
      finishCell();
      // Skip rows that are entirely empty (a blank line in the middle of the
      // file should not be treated as a row of nothing).
      if (current.length == 1 && current.first.isEmpty) {
        current = <String>[];
        return;
      }
      rows.add(current);
      current = <String>[];
    }

    while (i < content.length) {
      final ch = content[i];
      if (inQuotes) {
        if (ch == '"') {
          // Either an escaped `""` or the end of the quoted field.
          if (i + 1 < content.length && content[i + 1] == '"') {
            cell.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        cell.write(ch);
        i++;
        continue;
      }
      // Outside quotes.
      if (ch == '"') {
        // Opening quote — must be at the start of a cell to be honored as
        // such. If there's content already in the buffer, treat as a literal.
        if (cell.isEmpty) {
          inQuotes = true;
          i++;
          continue;
        }
        cell.write(ch);
        i++;
        continue;
      }
      if (ch == ',') {
        finishCell();
        i++;
        continue;
      }
      if (ch == '\n') {
        finishRow();
        i++;
        continue;
      }
      if (ch == '\r') {
        // Treat \r\n as a single line terminator. Bare \r is also a row
        // separator (legacy Mac).
        finishRow();
        i++;
        if (i < content.length && content[i] == '\n') i++;
        continue;
      }
      cell.write(ch);
      i++;
    }

    // Flush any trailing cell / row that wasn't terminated by a newline.
    if (cell.isNotEmpty || current.isNotEmpty) {
      finishRow();
    }
    return rows;
  }

  /// Serialize a list of rows into RFC-4180 CSV text. Fields containing
  /// commas, quotes, or newlines are quoted with `"` and embedded quotes
  /// doubled.
  static String stringify(List<List<String>> rows) {
    final buf = StringBuffer();
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        if (c > 0) buf.write(',');
        buf.write(_escape(row[c]));
      }
      if (r < rows.length - 1) buf.write('\r\n');
    }
    return buf.toString();
  }

  static String _escape(String field) {
    final needsQuote =
        field.contains(',') ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r');
    if (!needsQuote) return field;
    final escaped = field.replaceAll('"', '""');
    return '"$escaped"';
  }
}
