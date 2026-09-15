/// Base exception for all TTQL errors.
abstract class TtqlException implements Exception {
  final String message;
  final int line;
  final int column;

  const TtqlException(this.message, {this.line = 1, this.column = 1});

  @override
  String toString() => 'TtqlException: $message (Line $line, Column $column)';
}

/// Exception thrown when TTQL syntax or lexing rules are violated.
class TtqlParseException extends TtqlException {
  const TtqlParseException(super.message, {super.line = 1, super.column = 1});

  @override
  String toString() => 'TtqlParseException: $message (Line $line, Column $column)';
}

/// Exception thrown when TTQL security invariants (e.g. read-only rules) are violated.
class TtqlSecurityException extends TtqlException {
  final String keyword;

  const TtqlSecurityException(super.message, {required this.keyword, super.line = 1, super.column = 1});

  @override
  String toString() => 'TtqlSecurityException: $message (Keyword: $keyword)';
}

/// Exception thrown when query execution or dependency resolution fails during staging.
class TtqlExecutionException extends TtqlException {
  final Object? cause;

  const TtqlExecutionException(super.message, {this.cause, super.line = 1, super.column = 1});

  @override
  String toString() => 'TtqlExecutionException: $message${cause != null ? ' (Cause: $cause)' : ''}';
}
