import 'package:ttql/constants/ttql_constants.dart';
import 'package:ttql/models/ttql_binary_logical_expression.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_dependency_binding.dart';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_group_expression.dart';
import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';
import 'package:ttql/models/ttql_query_plan.dart';
import 'package:ttql/models/ttql_script_node.dart';
import 'package:ttql/models/ttql_unary_logical_expression.dart';
import 'package:ttql/models/ttql_where_predicate_node.dart';

/// Transforms a validated [TtqlScriptNode] into a Directed Acyclic Graph (DAG)
/// of execution stages with Phase B thread throttling (<= 3 concurrent queries per batch).
class TtqlDagPlanner {
  final TtqlEnvironmentContext? environmentContext;

  const TtqlDagPlanner({this.environmentContext});

  /// Compiles the AST into a sequential FIFO [TtqlQueryPlan].
  TtqlQueryPlan plan(TtqlScriptNode script) {
    final Map<int, List<TtqlPlannedStep>> stages = {};
    int currentStageIndex = 0;

    final Map<String, String> columnToStagingTable = {};
    final Map<String, int> stagingTableToStageIndex = {};
    final Map<String, String> aliasToStagingTable = {};

    final List<TtqlQueryInvocationNode> rootQueries = List.from(script.rootInvocations);

    if (rootQueries.isEmpty) {
      throw const TtqlExecutionException('TTQL script does not contain any database queries.');
    }

    final int batchSize = TtqlConstants.maxConcurrentQueriesPerBatch;
    for (int i = 0; i < rootQueries.length; i += batchSize) {
      final end = (i + batchSize < rootQueries.length) ? i + batchSize : rootQueries.length;
      final batch = rootQueries.sublist(i, end);

      final List<TtqlPlannedStep> stageSteps = [];
      for (int stepIdx = 0; stepIdx < batch.length; stepIdx++) {
        final query = batch[stepIdx];
        final stepNumber = i + stepIdx;
        final resolvedConnId = _resolveConnectionId(query.connectionId, script);
        final safeTableName = query.targetTableOrCollection.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
        final stagingTable = '${TtqlConstants.stagingTablePrefix}${currentStageIndex}_$safeTableName';
        TtqlWherePredicateNode? rawPredicate = query.wherePredicate;
        final resolvedPredicate = _resolvePredicateConstants(rawPredicate, script.declaredConstants);

        final connDesc = environmentContext?.resolveAlias(resolvedConnId);
        final effectiveEngine = connDesc?.engineType ?? query.engineType;
        final effectiveAlias = query.entityAlias ?? rawPredicate?.entityAlias ?? 'row';

        aliasToStagingTable[stagingTable] = stagingTable;
        aliasToStagingTable[query.targetTableOrCollection] = stagingTable;
        aliasToStagingTable[effectiveAlias] = stagingTable;
        for (final entry in script.entityAliases.entries) {
          if (entry.value == query.targetTableOrCollection) {
            aliasToStagingTable[entry.key] = stagingTable;
          }
        }

        final plannedStep = TtqlPlannedStep(
          stepId: 'step_${currentStageIndex}_$stepNumber',
          stageIndex: currentStageIndex,
          connectionId: resolvedConnId,
          engineType: effectiveEngine,
          targetTableOrCollection: query.targetTableOrCollection,
          projectedColumns: List<String>.from(query.projectedColumns),
          stagingTableName: stagingTable,
          entityAlias: effectiveAlias,
          wherePredicate: resolvedPredicate,
        );

        stageSteps.add(plannedStep);

        for (final col in query.projectedColumns) {
          columnToStagingTable[col] = stagingTable;
          stagingTableToStageIndex[stagingTable] = currentStageIndex;
        }
      }

      stages[currentStageIndex] = stageSteps;
      currentStageIndex++;
    }

    // Process Sequential Dependent Joins
    for (int joinIdx = 0; joinIdx < script.joins.length; joinIdx++) {
      final join = script.joins[joinIdx];
      final target = join.queryInvocation;
      final resolvedConnId = _resolveConnectionId(target.connectionId, script);
      final safeTableName = target.targetTableOrCollection.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final stagingTable = '${TtqlConstants.stagingTablePrefix}${currentStageIndex}_$safeTableName';

      final joinAlias = target.entityAlias ?? target.wherePredicate?.entityAlias ?? join.parentEntityAlias;

      final List<TtqlDependencyBinding> bindings = [];
      String? parentStagingTable;
      String? parentJoinCol;
      String? localJoinCol;

      TtqlWherePredicateNode? directFilterPredicate;

      if (target.wherePredicate != null) {
        final resolvedPredicate = _resolvePredicateConstants(target.wherePredicate, script.declaredConstants);
        final root = resolvedPredicate?.rootExpression;

        if (root != null) {
          final terms = _extractAndTerms(root);
          final joinTerms = terms.where((t) => _hasFieldReference(t)).toList();
          final filterTerms = terms.where((t) => !_hasFieldReference(t)).toList();

          for (final jTerm in joinTerms) {
            final comp = _findFirstComparison(jTerm);
            if (comp != null && comp.isRightOperandFieldReference && comp.rightFieldEntityAlias != null) {
              final parentCol = comp.rightOperand.toString().contains('.')
                  ? comp.rightOperand.toString().split('.').last
                  : comp.rightOperand.toString();
              localJoinCol = comp.fieldName;
              parentJoinCol = parentCol;

              final resolvedParentAlias = script.entityAliases[comp.rightFieldEntityAlias] ?? comp.rightFieldEntityAlias;
              parentStagingTable = aliasToStagingTable[comp.rightFieldEntityAlias] ??
                  aliasToStagingTable[resolvedParentAlias] ??
                  aliasToStagingTable[join.parentEntityAlias] ??
                  columnToStagingTable[parentCol];

              final rootStagingTable = stages[0]?.first.stagingTableName ?? '${TtqlConstants.stagingTablePrefix}0';
              parentStagingTable ??= rootStagingTable;

              bindings.add(TtqlDependencyBinding(
                sourceStagingTable: parentStagingTable,
                sourceColumn: parentCol,
                targetFilterField: localJoinCol,
              ));
            }
          }

          if (filterTerms.isNotEmpty) {
            final combinedFilterExpr = _combineAndTerms(filterTerms)!;
            directFilterPredicate = TtqlWherePredicateNode(
              entityAlias: target.wherePredicate!.entityAlias,
              rootExpression: combinedFilterExpr,
            );
          }
        } else if (target.wherePredicate!.isRightOperandFieldReference) {
          final parentCol = target.wherePredicate!.rightOperand.toString().contains('.')
              ? target.wherePredicate!.rightOperand.toString().split('.').last
              : target.wherePredicate!.rightOperand.toString();
          localJoinCol = target.wherePredicate!.fieldName;
          parentJoinCol = parentCol;

          final rootStagingTable = stages[0]?.first.stagingTableName ?? '${TtqlConstants.stagingTablePrefix}0';
          final parentAlias = target.wherePredicate!.rightFieldEntityAlias ?? join.parentEntityAlias;
          final resolvedParentAlias = script.entityAliases[parentAlias] ?? parentAlias;
          parentStagingTable = aliasToStagingTable[parentAlias] ??
              aliasToStagingTable[resolvedParentAlias] ??
              columnToStagingTable[parentCol] ??
              rootStagingTable;

          bindings.add(TtqlDependencyBinding(
            sourceStagingTable: parentStagingTable,
            sourceColumn: parentCol,
            targetFilterField: localJoinCol,
          ));
        } else {
          directFilterPredicate = resolvedPredicate;
        }
      }

      final joinConnDesc = environmentContext?.resolveAlias(resolvedConnId);
      final effectiveJoinEngine = joinConnDesc?.engineType ?? target.engineType;

      final effectiveProjectedCols = List<String>.from(target.projectedColumns);
      if (effectiveProjectedCols.isNotEmpty && localJoinCol != null && !effectiveProjectedCols.contains(localJoinCol)) {
        effectiveProjectedCols.add(localJoinCol);
      }

      if (parentStagingTable != null && parentJoinCol != null) {
        for (final stageList in stages.values) {
          for (final stp in stageList) {
            if (stp.stagingTableName == parentStagingTable) {
              if (stp.projectedColumns.isNotEmpty && !stp.projectedColumns.contains(parentJoinCol)) {
                stp.projectedColumns.add(parentJoinCol);
              }
            }
          }
        }
      }

      final plannedStep = TtqlPlannedStep(
        stepId: 'step_${currentStageIndex}_join_$joinIdx',
        stageIndex: currentStageIndex,
        connectionId: resolvedConnId,
        engineType: effectiveJoinEngine,
        targetTableOrCollection: target.targetTableOrCollection,
        projectedColumns: effectiveProjectedCols,
        stagingTableName: stagingTable,
        entityAlias: joinAlias,
        wherePredicate: directFilterPredicate,
        injectedDependencies: bindings,
        joinType: join.joinType,
        parentStagingTable: parentStagingTable,
        parentJoinColumn: parentJoinCol,
        localJoinColumn: localJoinCol,
      );

      stages[currentStageIndex] = [plannedStep];

      aliasToStagingTable[stagingTable] = stagingTable;
      aliasToStagingTable[target.targetTableOrCollection] = stagingTable;
      aliasToStagingTable[joinAlias] = stagingTable;
      for (final entry in script.entityAliases.entries) {
        if (entry.value == target.targetTableOrCollection) {
          aliasToStagingTable[entry.key] = stagingTable;
        }
      }

      for (final col in effectiveProjectedCols) {
        columnToStagingTable[col] = stagingTable;
        stagingTableToStageIndex[stagingTable] = currentStageIndex;
      }

      currentStageIndex++;
    }

    return TtqlQueryPlan(stages: stages);
  }

  static List<TtqlExpression> _extractAndTerms(TtqlExpression expr) {
    if (expr is TtqlBinaryLogicalExpression && expr.operator == 'AND') {
      return [..._extractAndTerms(expr.left), ..._extractAndTerms(expr.right)];
    }
    return [expr];
  }

  static bool _hasFieldReference(TtqlExpression expr) {
    if (expr is TtqlComparisonExpression) {
      return expr.isRightOperandFieldReference;
    }
    if (expr is TtqlBinaryLogicalExpression) {
      return _hasFieldReference(expr.left) || _hasFieldReference(expr.right);
    }
    if (expr is TtqlUnaryLogicalExpression) {
      return _hasFieldReference(expr.operand);
    }
    if (expr is TtqlGroupExpression) {
      return _hasFieldReference(expr.inner);
    }
    return false;
  }

  static TtqlComparisonExpression? _findFirstComparison(TtqlExpression expr) {
    if (expr is TtqlComparisonExpression) {
      return expr;
    }
    if (expr is TtqlBinaryLogicalExpression) {
      return _findFirstComparison(expr.left) ?? _findFirstComparison(expr.right);
    }
    if (expr is TtqlUnaryLogicalExpression) {
      return _findFirstComparison(expr.operand);
    }
    if (expr is TtqlGroupExpression) {
      return _findFirstComparison(expr.inner);
    }
    return null;
  }

  static TtqlExpression _resolveExpressionConstants(TtqlExpression expr, Map<String, dynamic> constants) {
    if (expr is TtqlComparisonExpression) {
      if (!expr.isRightOperandFieldReference && constants.containsKey(expr.rightOperand)) {
        final constVal = constants[expr.rightOperand];
        return TtqlComparisonExpression(
          fieldName: expr.fieldName,
          operator: expr.operator,
          rightOperand: constVal,
          isRightOperandFieldReference: false,
          rightFieldEntityAlias: null,
        );
      }
      return expr;
    }
    if (expr is TtqlBinaryLogicalExpression) {
      return TtqlBinaryLogicalExpression(
        left: _resolveExpressionConstants(expr.left, constants),
        operator: expr.operator,
        right: _resolveExpressionConstants(expr.right, constants),
      );
    }
    if (expr is TtqlUnaryLogicalExpression) {
      return TtqlUnaryLogicalExpression(
        operator: expr.operator,
        operand: _resolveExpressionConstants(expr.operand, constants),
      );
    }
    if (expr is TtqlGroupExpression) {
      return TtqlGroupExpression(_resolveExpressionConstants(expr.inner, constants));
    }
    return expr;
  }

  static TtqlExpression? _combineAndTerms(List<TtqlExpression> terms) {
    if (terms.isEmpty) return null;
    var result = terms.first;
    for (int i = 1; i < terms.length; i++) {
      result = TtqlBinaryLogicalExpression(
        left: result,
        operator: 'AND',
        right: terms[i],
      );
    }
    return result;
  }

  TtqlWherePredicateNode? _resolvePredicateConstants(
    TtqlWherePredicateNode? predicate,
    Map<String, dynamic> constantValues,
  ) {
    if (predicate == null) return null;
    final resolvedRoot = _resolveExpressionConstants(predicate.rootExpression, constantValues);

    return TtqlWherePredicateNode(
      entityAlias: predicate.entityAlias,
      rootExpression: resolvedRoot,
    );
  }

  String _resolveConnectionId(String expression, TtqlScriptNode script) {
    if (expression.contains('.')) {
      final parts = expression.split('.');
      final first = parts.first;

      if (script.connectionAliases.containsKey(first)) {
        final targetConnName = script.connectionAliases[first]!;
        if (environmentContext != null) {
          final desc = environmentContext!.resolveAlias(targetConnName);
          if (desc != null) return desc.id;
        }
        return targetConnName;
      }

      if (environmentContext != null) {
        final desc = environmentContext!.resolveAlias(first);
        if (desc != null) return desc.id;
      }

      if (first == TtqlConstants.envIdentifier && parts.length >= 3) {
        final dbName = parts[2];
        if (environmentContext != null) {
          final desc = environmentContext!.resolveAlias(dbName);
          if (desc != null) return desc.id;
        }
        return dbName;
      }
    }

    final clean = expression.replaceAll('\'', '').replaceAll('"', '').trim();
    if (script.connectionAliases.containsKey(clean)) {
      final targetConnName = script.connectionAliases[clean]!;
      if (environmentContext != null) {
        final desc = environmentContext!.resolveAlias(targetConnName);
        if (desc != null) return desc.id;
      }
      return targetConnName;
    }

    if (environmentContext != null) {
      final desc = environmentContext!.resolveAlias(clean);
      if (desc != null) return desc.id;
    }
    return clean;
  }
}
