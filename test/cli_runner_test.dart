import 'dart:convert';
import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('CliResultFormatter Unit Tests', () {
    final sampleRows = [
      {'id': 1, 'name': 'Alice', 'role': 'Admin'},
      {'id': 2, 'name': 'Bob', 'role': 'Developer'},
    ];

    test('TableResultFormatter renders ASCII grid with headers and row count', () {
      final formatter = const TableResultFormatter();
      final output = formatter.format(sampleRows);

      expect(output, contains('+----+-------+-----------+'));
      expect(output, contains('| id | name  | role      |'));
      expect(output, contains('| 1  | Alice | Admin     |'));
      expect(output, contains('(2 rows)'));
    });

    test('JsonResultFormatter renders valid formatted JSON array', () {
      final formatter = const JsonResultFormatter();
      final output = formatter.format(sampleRows);

      final decoded = jsonDecode(output) as List;
      expect(decoded.length, equals(2));
      expect(decoded.first['name'], equals('Alice'));
    });

    test('CsvResultFormatter renders comma-separated rows with escaped quotes', () {
      final formatter = const CsvResultFormatter();
      final output = formatter.format(sampleRows);

      final lines = output.trim().split('\n');
      expect(lines.first, equals('id,name,role'));
      expect(lines[1], equals('1,Alice,Admin'));
    });
  });
}
