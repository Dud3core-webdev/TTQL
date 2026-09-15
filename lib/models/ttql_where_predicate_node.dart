import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_expression.dart';

/// Represents a filter predicate `.where((row) => <expression>)`.
class TtqlWherePredicateNode extends TtqlAstNode {
  final String entityAlias;
  final String fieldName;
  final String operator;
  final dynamic rightOperand;
  final bool isRightOperandFieldReference;
  final String? rightFieldEntityAlias;
  final TtqlExpression? rootExpression;

  const TtqlWherePredicateNode({
    required this.entityAlias,
    required this.fieldName,
    required this.operator,
    required this.rightOperand,
    this.isRightOperandFieldReference = false,
    this.rightFieldEntityAlias,
    this.rootExpression,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'entityAlias': entityAlias,
      'fieldName': fieldName,
      'operator': operator,
      'rightOperand': rightOperand,
      'isRightOperandFieldReference': isRightOperandFieldReference,
      if (rightFieldEntityAlias != null) 'rightFieldEntityAlias': rightFieldEntityAlias,
      if (rootExpression != null) 'rootExpression': rootExpression!.toJson(),
    };
  }
}
