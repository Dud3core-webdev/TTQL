import 'package:ttql/models/ttql_expression.dart';

/// Represents a single comparison expression (`left operator right`).
class TtqlComparisonExpression extends TtqlExpression {
  final String fieldName;
  final String operator;
  final dynamic rightOperand;
  final bool isRightOperandFieldReference;
  final String? rightFieldEntityAlias;
  final String? entityAlias;
  final int line;
  final int column;

  const TtqlComparisonExpression({
    required this.fieldName,
    required this.operator,
    required this.rightOperand,
    this.isRightOperandFieldReference = false,
    this.rightFieldEntityAlias,
    this.entityAlias,
    this.line = 1,
    this.column = 1,
  });

  String? get rightOperandFieldName => isRightOperandFieldReference
      ? rightOperand.toString().split('.').last
      : null;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'comparison',
      'fieldName': fieldName,
      'operator': operator,
      'rightOperand': rightOperand,
      'isRightOperandFieldReference': isRightOperandFieldReference,
      if (rightFieldEntityAlias != null) 'rightFieldEntityAlias': rightFieldEntityAlias,
      if (entityAlias != null) 'entityAlias': entityAlias,
    };
  }
}

abstract class TtqlComparisonOperator {
  static const String isEqual = '=';
  static const String notEqual = '!=';
  static const String greaterThan = '>';
  static const String greaterThanOrEqual = '>=';
  static const String lessThan = '<';
  static const String lessThanOrEqual = '<=';
  static const String like = 'LIKE';
  static const String notLike = 'NOT LIKE';
  static const String inList = 'IN';
  static const String notInList = 'NOT IN';
}

abstract class TtqlLogicalOperator {
  static const String and = 'AND';
  static const String or = 'OR';
  static const String not = 'NOT';
}
