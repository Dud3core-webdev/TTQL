import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_expression.dart';

/// Represents a filter predicate `.where((alias) => <expression>)`.
/// Uses a unified, composite [TtqlExpression] root tree for all boolean conditions.
class TtqlWherePredicateNode extends TtqlAstNode {
  final String entityAlias;
  final TtqlExpression rootExpression;

  const TtqlWherePredicateNode({
    required this.entityAlias,
    required this.rootExpression,
  });

  /// First comparison expression if root is a comparison, for backward-compatible inspections.
  TtqlComparisonExpression? get _firstComparison {
    final expr = rootExpression;
    if (expr is TtqlComparisonExpression) return expr;
    return null;
  }

  String get fieldName => _firstComparison?.fieldName ?? '';
  String get operator => _firstComparison?.operator ?? '=';
  dynamic get rightOperand => _firstComparison?.rightOperand;
  bool get isRightOperandFieldReference => _firstComparison?.isRightOperandFieldReference ?? false;
  String? get rightFieldEntityAlias => _firstComparison?.rightFieldEntityAlias;

  @override
  Map<String, dynamic> toJson() {
    return {
      'entityAlias': entityAlias,
      'rootExpression': rootExpression.toJson(),
    };
  }
}
