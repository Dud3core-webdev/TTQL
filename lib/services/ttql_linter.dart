import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_binary_logical_expression.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_diagnostic.dart';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_group_expression.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';
import 'package:ttql/models/ttql_script_node.dart';
import 'package:ttql/models/ttql_unary_logical_expression.dart';
import 'package:ttql/services/ttql_lexer.dart';
import 'package:ttql/services/ttql_parser.dart';

/// Analyzes TTQL scripts for syntax errors, mutation violations, and non-existent schema entities.
class TtqlLinter {
  final TtqlEnvironmentContext? environmentContext;

  const TtqlLinter({this.environmentContext});

  /// Lints the source script and returns all discovered diagnostics.
  List<TtqlDiagnostic> lint(String source) {
    final List<TtqlDiagnostic> diagnostics = [];
    if (source.trim().isEmpty) return diagnostics;

    try {
      final tokens = TtqlLexer(source).tokenize();

      try {
        final parser = TtqlParser(tokens, environmentContext: environmentContext);
        final ast = parser.parse();

        _validateTypesAndSymbols(ast, diagnostics);

        if (environmentContext != null) {
          _validateSemanticEntities(ast, diagnostics);
        }
      } on TtqlParseException catch (e) {
        diagnostics.add(TtqlDiagnostic(
          message: e.message,
          line: e.line,
          column: e.column,
          severity: 'error',
        ));
      }
    } on TtqlSecurityException catch (e) {
      diagnostics.add(TtqlDiagnostic(
        message: e.message,
        line: 1,
        column: 1,
        severity: 'error',
      ));
    } on TtqlParseException catch (e) {
      diagnostics.add(TtqlDiagnostic(
        message: e.message,
        line: e.line,
        column: e.column,
        severity: 'error',
      ));
    } catch (e) {
      diagnostics.add(TtqlDiagnostic(
        message: e.toString(),
        line: 1,
        column: 1,
        severity: 'error',
      ));
    }

    return diagnostics;
  }

  void _validateSemanticEntities(TtqlScriptNode ast, List<TtqlDiagnostic> diagnostics) {
    final env = environmentContext!;

    final List<TtqlQueryInvocationNode> allQueries = List.from(ast.rootInvocations);
    for (final join in ast.joins) {
      allQueries.add(join.queryInvocation);
    }

    for (final query in allQueries) {
      if (query.engineType == DbEngineType.redis) continue;

      final connExpr = query.connectionId;
      final targetTable = query.targetTableOrCollection.replaceAll("'", "").replaceAll('"', '').trim();

      final desc = env.resolveAlias(connExpr);
      if (desc != null && desc.engineType != DbEngineType.redis && desc.tableNames.isNotEmpty) {
        if (!desc.tableNames.contains(targetTable)) {
          diagnostics.add(TtqlDiagnostic(
            message: 'Table or collection "$targetTable" does not exist in database "${desc.alias}". Available: ${desc.tableNames.join(", ")}',
            line: 1,
            column: 1,
            severity: 'error',
          ));
        }
      }
    }
  }

  void _validateTypesAndSymbols(TtqlScriptNode ast, List<TtqlDiagnostic> diagnostics) {
    final List<TtqlExpression> expressionsToCheck = [];
    for (final q in ast.rootInvocations) {
      if (q.wherePredicate?.rootExpression != null) {
        expressionsToCheck.add(q.wherePredicate!.rootExpression!);
      }
    }
    for (final j in ast.joins) {
      if (j.queryInvocation.wherePredicate?.rootExpression != null) {
        expressionsToCheck.add(j.queryInvocation.wherePredicate!.rootExpression!);
      }
    }

    void checkExpression(TtqlExpression expr) {
      if (expr is TtqlComparisonExpression) {
        if (expr.operator == 'IN' || expr.operator == 'NOT IN') {
          final right = expr.rightOperand;
          if (right is! List && !expr.isRightOperandFieldReference) {
            final declaredVal = ast.declaredConstants[right.toString()];
            if (declaredVal != null && declaredVal is! List) {
              diagnostics.add(TtqlDiagnostic(
                message: 'Operator "${expr.operator}" expects a list, but constant "$right" is not a list.',
                line: 1,
                column: 1,
                severity: 'error',
              ));
            }
          }
        }
      } else if (expr is TtqlBinaryLogicalExpression) {
        checkExpression(expr.left);
        checkExpression(expr.right);
      } else if (expr is TtqlUnaryLogicalExpression) {
        checkExpression(expr.operand);
      } else if (expr is TtqlGroupExpression) {
        checkExpression(expr.inner);
      }
    }

    for (final expr in expressionsToCheck) {
      checkExpression(expr);
    }
  }
}
