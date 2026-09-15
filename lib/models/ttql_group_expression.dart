import 'package:ttql/models/ttql_expression.dart';

/// Parenthesized expression group `(a OR b)`.
class TtqlGroupExpression extends TtqlExpression {
  final TtqlExpression inner;
  final int line;
  final int column;

  const TtqlGroupExpression(
    this.inner, {
    this.line = 1,
    this.column = 1,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'group',
      'expression': inner.toJson(),
    };
  }
}
