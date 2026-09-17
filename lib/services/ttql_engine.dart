import 'dart:convert';
import 'dart:isolate';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_execution_result.dart';
import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/models/ttql_query_plan.dart';
import 'package:ttql/services/translators/query_dialect_strategy.dart';
import 'package:ttql/services/ttql_connection_provider.dart';
import 'package:ttql/services/ttql_dag_planner.dart';
import 'package:ttql/services/ttql_environment_builder.dart';
import 'package:ttql/services/ttql_ephemeral_staging_database.dart';
import 'package:ttql/services/ttql_lexer.dart';
import 'package:ttql/services/ttql_parser.dart';

/// Core execution engine for TableTalk Query Language (TTQL).
/// Orchestrates the FIFO Directed Acyclic Graph (DAG) staging pipeline,
/// evaluates stages with concurrency throttling (<= 3 queries per batch),
/// and enforces zero memory leaks by immediately disposing the ephemeral SQLite staging database.
class TtqlEngine {
  final TtqlConnectionProvider connectionProvider;

  TtqlEngine({
    TtqlConnectionProvider? connectionProvider,
    TtqlConnectionProvider? poolManager,
  }) : connectionProvider = (connectionProvider ?? poolManager)!;

  /// Executes a raw TTQL script and yields a normalized analytical result set.
  Future<TtqlExecutionResult> executeScript(
    String scriptSource, {
    TtqlEnvironmentContext? environmentContext,
    int maxRowsPerStep = 500,
  }) async {
    final stopwatch = Stopwatch()..start();

    final envContext = environmentContext ?? TtqlEnvironmentBuilder(connectionProvider: connectionProvider).buildContext();

    final lexer = TtqlLexer(scriptSource);
    final tokens = lexer.tokenize();

    final parser = TtqlParser(tokens, environmentContext: envContext);
    final ast = parser.parse();

    final planner = TtqlDagPlanner(environmentContext: envContext);
    final TtqlQueryPlan plan = planner.plan(ast);

    final stagingDb = TtqlEphemeralStagingDatabase();
    final List<TtqlPlannedStep> allSteps = [];

    try {
      final sortedStages = plan.sortedStageIndices;

      for (final stageIndex in sortedStages) {
        final List<TtqlPlannedStep> stageSteps = plan.stages[stageIndex]!;
        allSteps.addAll(stageSteps);

        await Future.wait(
          stageSteps.map((step) => _executeStageStep(step, stagingDb, maxRowsPerStep)),
        );
      }

      final rawJoinedRows = stagingDb.executeFinalSyntheticJoin(
        allSteps,
        orderBys: ast.orderBys,
        orderBy: ast.orderBy,
        limit: ast.limit,
        offset: ast.offset,
        groupByColumns: ast.groupByColumns,
        havingPredicate: ast.havingPredicate,
        projections: ast.projections,
      );

      final List<Map<String, dynamic>> normalizedRows;
      if (rawJoinedRows.length > 200) {
        normalizedRows = await Isolate.run(() => _normalizeResultRows(rawJoinedRows));
      } else {
        normalizedRows = _normalizeResultRows(rawJoinedRows);
      }

      final Set<String> detectedCols = {};
      for (final row in normalizedRows) {
        detectedCols.addAll(row.keys);
      }

      stopwatch.stop();

      return TtqlExecutionResult(
        columns: detectedCols.toList(),
        rows: normalizedRows,
        totalRowCount: normalizedRows.length,
        executionDurationMs: stopwatch.elapsedMilliseconds,
        stagesExecuted: sortedStages.length,
        stagingTableCounts: stagingDb.stagedRowCounts,
      );
    } finally {
      stagingDb.dispose();
    }
  }

  Future<void> _executeStageStep(
    TtqlPlannedStep step,
    TtqlEphemeralStagingDatabase stagingDb,
    int maxRows,
  ) async {
    final String queryPayload = _buildAdapterQuery(step, stagingDb, maxRows);

    try {
      final results = await connectionProvider.executeQueryOnConnection(
        step.connectionId,
        queryPayload,
        maxRows: maxRows,
      );

      stagingDb.insertStagingRows(
        step.stagingTableName,
        results,
        fallbackColumns: step.projectedColumns,
      );
    } catch (e) {
      throw TtqlExecutionException(
        'Failed to execute TTQL step "${step.stepId}" on connection "${step.connectionId}": $e',
        cause: e,
      );
    }
  }

  String _buildAdapterQuery(
    TtqlPlannedStep step,
    TtqlEphemeralStagingDatabase stagingDb,
    int maxRows,
  ) {
    final strategy = QueryDialectStrategy.forEngine(step.engineType);
    return strategy.buildQuery(
      step: step,
      foreignKeyLookup: stagingDb.queryForeignKeys,
      maxRows: maxRows,
    );
  }

  static List<Map<String, dynamic>> _normalizeResultRows(List<Map<String, dynamic>> rawRows) {
    final List<Map<String, dynamic>> normalized = [];
    for (final row in rawRows) {
      final Map<String, dynamic> cleanRow = {};
      row.forEach((key, val) {
        if (val == null || val is num || val is bool || val is String) {
          cleanRow[key] = val;
        } else if (val is DateTime) {
          cleanRow[key] = val.toIso8601String();
        } else if (val is Map || val is List) {
          cleanRow[key] = jsonEncode(val);
        } else {
          cleanRow[key] = val.toString();
        }
      });
      normalized.add(cleanRow);
    }
    return normalized;
  }
}
