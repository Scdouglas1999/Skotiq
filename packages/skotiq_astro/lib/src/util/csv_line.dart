/// Split one comma-separated line into trimmed cells, honoring double quotes
/// around cells that contain commas.
List<String> splitCsvLine(String line) {
  // Catalog rows are almost all unquoted: skip the per-character walk.
  if (!line.contains('"')) {
    final cells = line.split(',');
    for (var i = 0; i < cells.length; i++) {
      cells[i] = cells[i].trim();
    }
    return cells;
  }
  final cells = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final char = line.codeUnitAt(i);
    if (char == 0x22) {
      inQuotes = !inQuotes;
    } else if (char == 0x2C && !inQuotes) {
      cells.add(current.toString().trim());
      current.clear();
    } else {
      current.writeCharCode(char);
    }
  }
  cells.add(current.toString().trim());
  return cells;
}
