import 'package:ttql/models/ttql_expression.dart';

/// Unary logical operation `NOT (...)`.
class TtqlUnaryLogicalExpression extends TtqlExpression {
  final String operator; // 'NOT'
  final TtqlExpression operand;

  const TtqlUnaryLogicalExpression({
    required this.operator,
    required this.operand,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'unaryLogical',
      'operator': operator,
      'operand': operand.toJson(),
    };
  }
}
