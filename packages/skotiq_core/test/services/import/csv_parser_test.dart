import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/import/csv_parser.dart';

void main() {
  group('CsvParser parse', () {
    test('parses simple comma-separated rows', () {
      final rows = CsvParser.parse('a,b,c\n1,2,3\n');
      expect(rows, [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('handles quoted fields with commas', () {
      final rows = CsvParser.parse('"a,b","c","d,e"\n');
      expect(rows, [
        ['a,b', 'c', 'd,e'],
      ]);
    });

    test('handles escaped quotes ("")', () {
      final rows = CsvParser.parse('"He said ""hi""","bye"\n');
      expect(rows, [
        ['He said "hi"', 'bye'],
      ]);
    });

    test('handles CRLF line endings', () {
      final rows = CsvParser.parse('a,b\r\n1,2\r\n');
      expect(rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('handles quoted newlines inside field', () {
      final rows = CsvParser.parse('"first\nline","x"\n"y","z"\n');
      expect(rows, [
        ['first\nline', 'x'],
        ['y', 'z'],
      ]);
    });

    test('skips entirely empty rows', () {
      final rows = CsvParser.parse('a,b\n\n1,2\n');
      expect(rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('handles trailing row without newline', () {
      final rows = CsvParser.parse('a,b\n1,2');
      expect(rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });
  });

  group('CsvParser stringify', () {
    test('round-trips basic rows', () {
      final original = [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ];
      final csv = CsvParser.stringify(original);
      final reparsed = CsvParser.parse(csv);
      expect(reparsed, original);
    });

    test('quotes fields with commas', () {
      final csv = CsvParser.stringify([
        ['has,comma', 'normal'],
      ]);
      expect(csv, '"has,comma",normal');
    });

    test('escapes inner quotes', () {
      final csv = CsvParser.stringify([
        ['hi "bob"', 'x'],
      ]);
      expect(csv, '"hi ""bob""",x');
    });
  });
}
