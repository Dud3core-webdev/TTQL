import 'package:ttql/models/ttql_binary_logical_expression.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_group_expression.dart';
import 'package:ttql/models/ttql_unary_logical_expression.dart';

/// Visitor that translates TTQL expression trees into MongoDB Query Language (MQL) filter maps.
class MongoExpressionVisitor {
  const MongoExpressionVisitor();

  /// Translates an expression tree into a Mongo filter map.
  static Map<String, dynamic> translate(TtqlExpression expr) {
    const visitor = MongoExpressionVisitor();
    return visitor._visit(expr);
  }

  Map<String, dynamic> _visit(TtqlExpression expr) {
    if (expr is TtqlBinaryLogicalExpression) {
      final leftMap = _visit(expr.left);
      final rightMap = _visit(expr.right);
      final opKey = expr.operator == 'AND' ? r'$and' : r'$or';
      return {
        opKey: [leftMap, rightMap],
      };
    } else if (expr is TtqlUnaryLogicalExpression) {
      final childMap = _visit(expr.operand);
      return {
        r'$nor': [childMap],
      };
    } else if (expr is TtqlGroupExpression) {
      return _visit(expr.inner);
    } else if (expr is TtqlComparisonExpression) {
      final field = expr.fieldName;
      final val = expr.rightOperand;

      switch (expr.operator) {
        case '=':
          return {field: val};
        case '!=':
          return {
            field: {r'$ne': val}
          };
        case '<':
          return {
            field: {r'$lt': val}
          };
        case '<=':
          return {
            field: {r'$lte': val}
          };
        case '>':
          return {
            field: {r'$gt': val}
          };
        case '>=':
          return {
            field: {r'$gte': val}
          };
        case 'LIKE':
          final pattern = _sqlLikeToRegexPattern(val.toString());
          return {
            field: {r'$regex': pattern, r'$options': 'i'}
          };
        case 'NOT LIKE':
          final pattern = _sqlLikeToRegexPattern(val.toString());
          return {
            field: {
              r'$not': {r'$regex': pattern, r'$options': 'i'}
            }
          };
        case 'IN':
          final inList = val is List ? val : [val];
          return {
            field: {r'$in': inList}
          };
        case 'NOT IN':
          final notInList = val is List ? val : [val];
          return {
            field: {r'$nin': notInList}
          };
        default:
          return {field: val};
      }
    }
    return {};
  }

  static String _sqlLikeToRegexPattern(String sqlPattern) {
    final startsWithWildcard = sqlPattern.startsWith('%');
    final endsWithWildcard = sqlPattern.endsWith('%');

    var core = sqlPattern;
    if (startsWithWildcard) {
      core = core.substring(1);
    }
    if (endsWithWildcard && core.isNotEmpty) {
      core = core.substring(0, core.length - 1);
    }

    final buffer = StringBuffer();
    for (int i = 0; i < core.length; i++) {
      final char = core[i];
      if (char == '%') {
        buffer.write('.*');
      } else if (char == '_') {
        buffer.write('.');
      } else if (r'\^$.*+?()[]{}|'.contains(char)) {
        buffer.write(r'\');
        buffer.write(char);
      } else {
        buffer.write(char);
      }
    }

    final escapedCore = buffer.toString();

    if (startsWithWildcard && endsWithWildcard) {
      return escapedCore;
    } else if (startsWithWildcard) {
      return '$escapedCore\$';
    } else if (endsWithWildcard) {
      return '^$escapedCore';
    } else {
      return '^$escapedCore\$';
    }
  }
}
