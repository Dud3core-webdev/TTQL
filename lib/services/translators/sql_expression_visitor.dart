import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_binary_logical_expression.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_group_expression.dart';
import 'package:ttql/models/ttql_unary_logical_expression.dart';

/// Result produced by visiting a TTQL expression tree for SQL generation.
class SqlExpressionResult {
  final String sqlClause;
  final List<dynamic> bindings;

  const SqlExpressionResult({
    required this.sqlClause,
    required this.bindings,
  });
}

/// Dialect-aware visitor that translates TTQL expressions into SQL WHERE clauses
/// with parameterized query bindings.
class SqlExpressionVisitor {
  final DbEngineType engineType;
  final List<dynamic> bindings = [];
  int _paramIndex = 1;

  SqlExpressionVisitor(this.engineType);

  /// Returns the identifier quote character for [engineType].
  ///
  /// Oracle and Cassandra/ScyllaDB use unquoted identifiers so unquoted DDL
  /// names fold to their native case without requiring exact case matching.
  static String identifierQuoteForEngine(DbEngineType engineType) {
    if (engineType == DbEngineType.mysql || engineType == DbEngineType.planetscale) {
      return '`';
    }
    if (engineType == DbEngineType.oracle || engineType == DbEngineType.cassandra) {
      return '';
    }
    return '"';
  }

  /// Translates an expression tree into a [SqlExpressionResult].
  static SqlExpressionResult translate(TtqlExpression expr, DbEngineType engineType) {
    final visitor = SqlExpressionVisitor(engineType);
    final sql = visitor._visit(expr);
    return SqlExpressionResult(
      sqlClause: sql,
      bindings: visitor.bindings,
    );
  }

  String _nextPlaceholder() {
    if (engineType == DbEngineType.postgres ||
        engineType == DbEngineType.cockroachdb ||
        engineType == DbEngineType.yugabytedb) {
      return '\$${_paramIndex++}';
    }
    return '?';
  }

  String _visit(TtqlExpression expr) {
    if (expr is TtqlBinaryLogicalExpression) {
      final leftSql = _visit(expr.left);
      final opSql = expr.operator;
      final rightSql = _visit(expr.right);
      return '($leftSql $opSql $rightSql)';
    } else if (expr is TtqlUnaryLogicalExpression) {
      final childSql = _visit(expr.operand);
      return '(NOT $childSql)';
    } else if (expr is TtqlGroupExpression) {
      final innerSql = _visit(expr.inner);
      return '($innerSql)';
    } else if (expr is TtqlComparisonExpression) {
      final quote = identifierQuoteForEngine(engineType);
      final fieldCol = '$quote${expr.fieldName}$quote';

      if (expr.isRightOperandFieldReference) {
        final rightCol = '$quote${expr.rightOperand}$quote';
        return '$fieldCol ${expr.operator} $rightCol';
      }

      final val = expr.rightOperand;
      if (val == null) {
        if (expr.operator == '=') {
          return '$fieldCol IS NULL';
        } else if (expr.operator == '!=') {
          return '$fieldCol IS NOT NULL';
        }
      }

      if (expr.operator == 'IN' || expr.operator == 'NOT IN') {
        final op = expr.operator;
        if (val is List) {
          if (val.isEmpty) {
            return expr.operator == 'IN' ? '1=0' : '1=1';
          }
          final placeholders = val.map((item) {
            bindings.add(item);
            return _nextPlaceholder();
          }).join(', ');
          return '$fieldCol $op ($placeholders)';
        } else {
          final placeholder = _nextPlaceholder();
          bindings.add(val);
          return '$fieldCol $op ($placeholder)';
        }
      }

      if (expr.operator == 'LIKE' || expr.operator == 'NOT LIKE') {
        final op = expr.operator;
        final placeholder = _nextPlaceholder();
        bindings.add(val);
        return '$fieldCol $op $placeholder';
      }

      final placeholder = _nextPlaceholder();
      bindings.add(val);
      return '$fieldCol ${expr.operator} $placeholder';
    }
    return '';
  }
}
