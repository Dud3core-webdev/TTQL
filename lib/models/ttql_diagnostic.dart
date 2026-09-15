/// Diagnostic warning or error generated during TTQL linting.
class TtqlDiagnostic {
  final String message;
  final int line;
  final int column;
  final String severity; // 'error' | 'warning' | 'info'

  const TtqlDiagnostic({
    required this.message,
    required this.line,
    required this.column,
    this.severity = 'error',
  });

  Map<String, dynamic> toJson() {
    return {
      'message': message,
      'line': line,
      'column': column,
      'severity': severity,
    };
  }

  @override
  String toString() => '[$severity] L$line:$column $message';
}

abstract class TtqlDiagnosticSeverity {
  static const String error = 'error';
  static const String warning = 'warning';
  static const String info = 'info';
}

