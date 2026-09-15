/// Token produced by [TtqlLexer].
enum TtqlTokenType {
  keyword,
  identifier,
  stringLiteral,
  numberLiteral,
  booleanLiteral,
  operator,
  punctuation,
  eof;

  static TtqlTokenType get notEqual => operator;
  static TtqlTokenType get lessThan => operator;
  static TtqlTokenType get lessThanOrEqual => operator;
  static TtqlTokenType get greaterThan => operator;
  static TtqlTokenType get greaterThanOrEqual => operator;
  static TtqlTokenType get keywordAnd => keyword;
}

class TtqlToken {
  final TtqlTokenType type;
  final String value;
  final int line;
  final int column;
  final int offset;

  const TtqlToken({
    required this.type,
    required this.value,
    required this.line,
    required this.column,
    required this.offset,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'value': value,
      'line': line,
      'column': column,
      'offset': offset,
    };
  }

  @override
  String toString() => '$type($value) @ L$line:$column';
}
