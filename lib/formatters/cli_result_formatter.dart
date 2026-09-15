import 'dart:convert';

/// Abstract formatter for analytical result sets produced by TTQL execution.
abstract class CliResultFormatter {
  String format(List<Map<String, dynamic>> rows);

  static CliResultFormatter forType(String formatType) {
    switch (formatType.toLowerCase()) {
      case 'json':
        return const JsonResultFormatter();
      case 'csv':
        return const CsvResultFormatter();
      case 'table':
      default:
        return const TableResultFormatter();
    }
  }
}

/// Renders result sets as a clean ASCII tabular grid.
class TableResultFormatter implements CliResultFormatter {
  const TableResultFormatter();

  @override
  String format(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return '(0 rows returned)';
    }

    final headers = rows.first.keys.toList();
    if (headers.isEmpty) {
      return '(Empty schema)';
    }

    final Map<String, int> colWidths = {};
    for (final header in headers) {
      colWidths[header] = header.length;
    }

    for (final row in rows) {
      for (final header in headers) {
        final cellStr = row[header]?.toString() ?? 'NULL';
        if (cellStr.length > colWidths[header]!) {
          colWidths[header] = cellStr.length;
        }
      }
    }

    final StringBuffer buffer = StringBuffer();

    // Border line: +----+------+
    void appendBorder() {
      buffer.write('+');
      for (final header in headers) {
        buffer.write('-' * (colWidths[header]! + 2));
        buffer.write('+');
      }
      buffer.writeln();
    }

    appendBorder();

    // Header row: | col1 | col2 |
    buffer.write('|');
    for (final header in headers) {
      buffer.write(' ');
      buffer.write(header.padRight(colWidths[header]!));
      buffer.write(' |');
    }
    buffer.writeln();

    appendBorder();

    // Data rows
    for (final row in rows) {
      buffer.write('|');
      for (final header in headers) {
        final cellStr = row[header]?.toString() ?? 'NULL';
        buffer.write(' ');
        buffer.write(cellStr.padRight(colWidths[header]!));
        buffer.write(' |');
      }
      buffer.writeln();
    }

    appendBorder();
    buffer.writeln('(${rows.length} ${rows.length == 1 ? 'row' : 'rows'})');

    return buffer.toString();
  }
}

/// Renders result sets as formatted JSON for UNIX composability (`| jq .`).
class JsonResultFormatter implements CliResultFormatter {
  const JsonResultFormatter();

  @override
  String format(List<Map<String, dynamic>> rows) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(rows);
  }
}

/// Renders result sets as Comma-Separated Values (CSV).
class CsvResultFormatter implements CliResultFormatter {
  const CsvResultFormatter();

  @override
  String format(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return '';

    final headers = rows.first.keys.toList();
    final StringBuffer buffer = StringBuffer();

    // Write header
    buffer.writeln(headers.map(_escapeCsv).join(','));

    // Write data rows
    for (final row in rows) {
      final values = headers.map((h) => _escapeCsv(row[h]?.toString() ?? ''));
      buffer.writeln(values.join(','));
    }

    return buffer.toString();
  }

  static String _escapeCsv(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      final escaped = field.replaceAll('"', '""');
      return '"$escaped"';
    }
    return field;
  }
}
