import 'package:ttql/models/ttql_expression.dart';

/// Represents a binary logical operation (`AND`, `OR`).
class TtqlBinaryLogicalExpression extends TtqlExpression {
  final TtqlExpression left;
  final String operator; // 'AND' | 'OR'
  final TtqlExpression right;
  final int line;
  final int column;

  const TtqlBinaryLogicalExpression({
    required this.left,
    required this.operator,
    required this.right,
    this.line = 1,
    this.column = 1,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'binaryLogical',
      'left': left.toJson(),
      'operator': operator,
      'right': right.toJson(),
    };
  }
}
