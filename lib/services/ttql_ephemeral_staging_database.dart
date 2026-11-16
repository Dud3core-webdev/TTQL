import 'package:sqlite3/sqlite3.dart';
import 'package:ttql/models/ttql_binary_logical_expression.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_group_expression.dart';
import 'package:ttql/models/ttql_order_by_node.dart';
import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/models/ttql_projection_item.dart';
import 'package:ttql/models/ttql_unary_logical_expression.dart';

/// Ephemeral SQLite `:memory:` database manager for cross-database data staging and synthetic joining.
/// Strictly disposable to guarantee zero memory leaks after query evaluation.
class TtqlEphemeralStagingDatabase {
  Database? _db;
  final Map<String, int> _stagedRowCounts = {};
  final Map<String, List<String>> _stagedTableColumns = {};

  TtqlEphemeralStagingDatabase() {
    _db = sqlite3.openInMemory();
  }

  bool get isDisposed => _db == null;
  Map<String, int> get stagedRowCounts => Map.unmodifiable(_stagedRowCounts);

  /// Creates a staging table in the in-memory SQLite database.
  void createStagingTable(String tableName, List<String> columns) {
    _ensureNotDisposed();
    _stagedTableColumns[tableName] = columns;

    if (columns.isEmpty) {
      _db!.execute('CREATE TABLE IF NOT EXISTS "$tableName" (_raw_payload TEXT);');
      return;
    }

    final colDefs = columns.map((col) => '"$col"').join(', ');
    _db!.execute('CREATE TABLE IF NOT EXISTS "$tableName" ($colDefs);');
  }

  /// Ingests a batch of normalized row maps into the specified staging table within a single transaction.
  void insertStagingRows(String tableName, List<Map<String, dynamic>> rows, {List<String>? fallbackColumns}) {
    _ensureNotDisposed();
    if (rows.isEmpty) {
      createStagingTable(tableName, fallbackColumns ?? []);
      return;
    }

    final Set<String> detectedColumns = {};
    for (final row in rows) {
      detectedColumns.addAll(row.keys);
    }
    createStagingTable(tableName, detectedColumns.toList());

    final colList = detectedColumns.toList();
    final colNamesEscaped = colList.map((c) => '"$c"').join(', ');
    final placeholders = List.filled(colList.length, '?').join(', ');
    final insertSql = 'INSERT INTO "$tableName" ($colNamesEscaped) VALUES ($placeholders)';

    final statement = _db!.prepare(insertSql);
    try {
      _db!.execute('BEGIN TRANSACTION;');
      for (final row in rows) {
        final values = detectedColumns.map((col) {
          final val = row[col];
          if (val == null) return null;
          if (val is num || val is bool) return val;
          return val.toString();
        }).toList();

        statement.execute(values);
      }
      _db!.execute('COMMIT;');
      _stagedRowCounts[tableName] = (_stagedRowCounts[tableName] ?? 0) + rows.length;
    } catch (e) {
      try {
        _db!.execute('ROLLBACK;');
      } catch (_) {}
      throw TtqlExecutionException('Failed to insert rows into ephemeral SQLite staging table "$tableName"', cause: e);
    } finally {
      statement.dispose();
    }
  }

  /// Extracts distinct foreign key values from a staging table for state injection into downstream stages.
  List<dynamic> queryForeignKeys(String stagingTable, String columnName) {
    _ensureNotDisposed();
    try {
      final resultSet = _db!.select(
        'SELECT DISTINCT "$columnName" as fk_val FROM "$stagingTable" WHERE "$columnName" IS NOT NULL AND "$columnName" != \'\';',
      );
      final List<dynamic> results = [];
      for (final row in resultSet) {
        results.add(row['fk_val']);
      }
      return results;
    } catch (e) {
      throw TtqlExecutionException(
        'Failed to query foreign keys "$columnName" from staging table "$stagingTable"',
        cause: e,
      );
    }
  }

  List<String> _findCommonColumns(String tableA, String tableB) {
    final colsA = _stagedTableColumns[tableA] ?? [];
    final colsB = _stagedTableColumns[tableB] ?? [];
    return colsA.where((c) => colsB.contains(c)).toList();
  }

  String? _resolveColumnStagingTable(
    String colName,
    List<TtqlPlannedStep> allSteps, {
    String? entityAlias,
  }) {
    final lowerCol = colName.toLowerCase();
    bool hasColumn(Iterable<String> cols) {
      if (cols.contains(colName)) return true;
      return cols.any((c) => c.toLowerCase() == lowerCol);
    }

    if (entityAlias != null) {
      for (final step in allSteps) {
        if (step.entityAlias == entityAlias ||
            step.targetTableOrCollection == entityAlias ||
            step.stagingTableName.endsWith('_$entityAlias')) {
          final stagedCols = _stagedTableColumns[step.stagingTableName] ?? step.projectedColumns;
          if (stagedCols.isEmpty || hasColumn(stagedCols)) {
            return step.stagingTableName;
          }
        }
      }
    }

    for (final step in allSteps) {
      final stagedCols = _stagedTableColumns[step.stagingTableName] ?? [];
      if (hasColumn(stagedCols)) {
        return step.stagingTableName;
      }
    }

    for (final step in allSteps) {
      if (hasColumn(step.projectedColumns)) {
        return step.stagingTableName;
      }
    }

    return null;
  }

  String _renderExpression(TtqlExpression expr) {
    if (expr is TtqlBinaryLogicalExpression) {
      final left = _renderExpression(expr.left);
      final right = _renderExpression(expr.right);
      return '($left ${expr.operator} $right)';
    } else if (expr is TtqlUnaryLogicalExpression) {
      final child = _renderExpression(expr.operand);
      return '(NOT $child)';
    } else if (expr is TtqlGroupExpression) {
      final inner = _renderExpression(expr.inner);
      return '($inner)';
    } else if (expr is TtqlComparisonExpression) {
      final field = expr.fieldName.contains('(') ? expr.fieldName : '"${expr.fieldName}"';
      final val = expr.rightOperand;
      if (val == null) {
        if (expr.operator == '=') return '$field IS NULL';
        if (expr.operator == '!=') return '$field IS NOT NULL';
      }
      final formatted = (val is num || val is bool) ? '$val' : "'${val.toString().replaceAll("'", "''")}'";
      return '$field ${expr.operator} $formatted';
    }
    return '';
  }

  /// Executes the final synthetic relational join across staged tables in the ephemeral SQLite database.
  List<Map<String, dynamic>> executeFinalSyntheticJoin(
    List<TtqlPlannedStep> allSteps, {
    List<TtqlOrderByNode>? orderBys,
    TtqlOrderByNode? orderBy,
    int? limit,
    int? offset,
    List<String>? groupByColumns,
    TtqlExpression? havingPredicate,
    List<TtqlProjectionItem>? projections,
  }) {
    _ensureNotDisposed();

    if (allSteps.isEmpty) return [];

    final rootStep = allSteps.first;
    final joinSteps = allSteps.skip(1).toList();

    final buffer = StringBuffer();
    buffer.write('SELECT ');

    // 1. Projections
    if (projections != null && projections.isNotEmpty) {
      final List<String> renderedProjs = [];
      for (final p in projections) {
        if (p is TtqlColumnProjection) {
          final targetTable = _resolveColumnStagingTable(p.columnName, allSteps, entityAlias: p.entityAlias);
          final tablePrefix = (allSteps.length > 1 && targetTable != null) ? '"$targetTable".' : '';
          final colExpr = '$tablePrefix"${p.columnName}"';
          if (p.alias != null && p.alias != p.columnName) {
            renderedProjs.add('$colExpr AS "${p.alias}"');
          } else {
            renderedProjs.add(colExpr);
          }
        } else if (p is TtqlAggregateProjection) {
          final fn = p.functionName;
          final arg = p.argumentColumn;
          final String argSql;
          if (arg == null || arg == '*') {
            argSql = '*';
          } else {
            final targetTable = _resolveColumnStagingTable(arg, allSteps, entityAlias: p.entityAlias);
            final tablePrefix = (allSteps.length > 1 && targetTable != null) ? '"$targetTable".' : '';
            argSql = '$tablePrefix"$arg"';
          }
          final aggExpr = '$fn($argSql)';
          if (p.alias != null) {
            renderedProjs.add('$aggExpr AS "${p.alias}"');
          } else {
            renderedProjs.add('$aggExpr AS "${p.outputName}"');
          }
        }
      }
      buffer.write(renderedProjs.join(', '));
    } else {
      if (allSteps.length == 1) {
        buffer.write('*');
      } else {
        final List<String> selectCols = [];
        selectCols.add('"${rootStep.stagingTableName}".*');
        for (final jStep in joinSteps) {
          selectCols.add('"${jStep.stagingTableName}".*');
        }
        buffer.write(selectCols.join(', '));
      }
    }

    // 2. FROM clause
    buffer.write(' FROM "${rootStep.stagingTableName}"');

    // 3. JOIN clauses
    for (final jStep in joinSteps) {
      final jt = jStep.joinType?.toLowerCase();
      final String joinTypeSql;
      if (jt == 'leftjoin') {
        joinTypeSql = 'LEFT JOIN';
      } else if (jt == 'rightjoin') {
        joinTypeSql = 'RIGHT JOIN';
      } else if (jt == 'fullouterjoin') {
        joinTypeSql = 'FULL OUTER JOIN';
      } else {
        joinTypeSql = 'INNER JOIN';
      }
      final parentTable = jStep.parentStagingTable ?? rootStep.stagingTableName;
      var parentCol = jStep.parentJoinColumn;
      var localCol = jStep.localJoinColumn;

      if (parentCol == null || localCol == null) {
        final commonCols = _findCommonColumns(parentTable, jStep.stagingTableName);
        if (commonCols.length == 1) {
          parentCol = commonCols.first;
          localCol = commonCols.first;
        } else if (commonCols.isEmpty) {
          throw TtqlExecutionException(
            'Cannot execute join for "${jStep.stagingTableName}": No join condition or common columns found between "$parentTable" and "${jStep.stagingTableName}".',
          );
        } else {
          throw TtqlExecutionException(
            'Ambiguous join between "$parentTable" and "${jStep.stagingTableName}": Multiple common columns found (${commonCols.join(", ")}). Specify an explicit join predicate in the query.',
          );
        }
      }

      buffer.write(' $joinTypeSql "${jStep.stagingTableName}" ON "${jStep.stagingTableName}"."$localCol" = "$parentTable"."$parentCol"');
    }

    // 4. GROUP BY
    if (groupByColumns != null && groupByColumns.isNotEmpty) {
      final List<String> gCols = [];
      for (final g in groupByColumns) {
        final parts = g.split('.');
        final colName = parts.last;
        final ent = parts.length > 1 ? parts.first : null;
        final targetTable = _resolveColumnStagingTable(colName, allSteps, entityAlias: ent);
        final prefix = (allSteps.length > 1 && targetTable != null) ? '"$targetTable".' : '';
        gCols.add('$prefix"$colName"');
      }
      buffer.write(' GROUP BY ${gCols.join(', ')}');
    }

    // 5. HAVING
    if (havingPredicate != null) {
      final havingSql = _renderExpression(havingPredicate);
      if (havingSql.isNotEmpty) {
        buffer.write(' HAVING $havingSql');
      }
    }

    // 6. ORDER BY
    final effectiveOrderBys = (orderBys != null && orderBys.isNotEmpty)
        ? orderBys
        : (orderBy != null ? [orderBy] : <TtqlOrderByNode>[]);

    if (effectiveOrderBys.isNotEmpty) {
      final List<String> orderClauses = [];
      for (final ob in effectiveOrderBys) {
        final dir = ob.direction;
        final targetTable = _resolveColumnStagingTable(ob.fieldName, allSteps, entityAlias: ob.entityAlias);
        if (targetTable != null && allSteps.length > 1) {
          orderClauses.add('"$targetTable"."${ob.fieldName}" $dir');
        } else {
          orderClauses.add('"${ob.fieldName}" $dir');
        }
      }
      buffer.write(' ORDER BY ${orderClauses.join(', ')}');
    }

    // 7. LIMIT & OFFSET
    if (limit != null && limit > 0) {
      buffer.write(' LIMIT $limit');
      if (offset != null && offset > 0) {
        buffer.write(' OFFSET $offset');
      }
    } else if (offset != null && offset > 0) {
      buffer.write(' LIMIT -1 OFFSET $offset');
    }

    return _runSelect(buffer.toString());
  }

  List<Map<String, dynamic>> _runSelect(String querySql) {
    try {
      final ResultSet resultSet = _db!.select(querySql);
      final List<Map<String, dynamic>> results = [];
      for (final Row row in resultSet) {
        final Map<String, dynamic> rowMap = {};
        for (final col in resultSet.columnNames) {
          rowMap[col] = row[col];
        }
        results.add(rowMap);
      }
      return results;
    } catch (e) {
      throw TtqlExecutionException('Failed to execute synthetic join query in ephemeral SQLite: $querySql', cause: e);
    }
  }

  List<Map<String, dynamic>> queryAllRows(String stagingTable) {
    _ensureNotDisposed();
    try {
      final ResultSet resultSet = _db!.select('SELECT * FROM "$stagingTable";');
      final List<Map<String, dynamic>> results = [];
      for (final Row row in resultSet) {
        final Map<String, dynamic> rowMap = {};
        for (final col in resultSet.columnNames) {
          rowMap[col] = row[col];
        }
        results.add(rowMap);
      }
      return results;
    } catch (e) {
      throw TtqlExecutionException('Failed to read rows from staging table "$stagingTable"', cause: e);
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
    _stagedRowCounts.clear();
  }

  void _ensureNotDisposed() {
    if (_db == null) {
      throw const TtqlExecutionException('Ephemeral staging SQLite database has been disposed.');
    }
  }
}
