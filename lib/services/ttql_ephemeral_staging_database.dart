import 'package:sqlite3/sqlite3.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_order_by_node.dart';
import 'package:ttql/models/ttql_planned_step.dart';

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

  /// Executes the final synthetic relational join across staged tables in the ephemeral SQLite database.
  List<Map<String, dynamic>> executeFinalSyntheticJoin(
    List<TtqlPlannedStep> allSteps, {
    TtqlOrderByNode? orderBy,
    int? limit,
  }) {
    _ensureNotDisposed();

    if (allSteps.isEmpty) return [];

    void appendModifiers(StringBuffer buf, {String? targetStagingTable}) {
      if (orderBy != null) {
        final dir = orderBy.direction;
        if (targetStagingTable != null) {
          buf.write(' ORDER BY "$targetStagingTable"."${orderBy.fieldName}" $dir');
        } else {
          buf.write(' ORDER BY "${orderBy.fieldName}" $dir');
        }
      }
      if (limit != null && limit > 0) {
        buf.write(' LIMIT $limit');
      }
    }

    if (allSteps.length == 1) {
      final table = allSteps.first.stagingTableName;
      final buffer = StringBuffer('SELECT * FROM "$table"');
      appendModifiers(buffer, targetStagingTable: table);
      return _runSelect(buffer.toString());
    }

    final rootStep = allSteps.first;
    final joinSteps = allSteps.skip(1).toList();

    final buffer = StringBuffer();
    buffer.write('SELECT ');

    final List<String> selectCols = [];
    selectCols.add('"${rootStep.stagingTableName}".*');
    for (final jStep in joinSteps) {
      selectCols.add('"${jStep.stagingTableName}".*');
    }
    buffer.write(selectCols.join(', '));
    buffer.write(' FROM "${rootStep.stagingTableName}"');

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
        if (commonCols.contains('customer_id')) {
          parentCol = 'customer_id';
          localCol = 'customer_id';
        } else if (commonCols.contains('order_id')) {
          parentCol = 'order_id';
          localCol = 'order_id';
        } else if (commonCols.isNotEmpty) {
          parentCol = commonCols.first;
          localCol = commonCols.first;
        }
      }

      if (parentCol != null && localCol != null) {
        buffer.write(' $joinTypeSql "${jStep.stagingTableName}" ON "${jStep.stagingTableName}"."$localCol" = "$parentTable"."$parentCol"');
      } else {
        buffer.write(' LEFT JOIN "${jStep.stagingTableName}" ON 1=1');
      }
    }

    String? resolvedOrderTable;
    if (orderBy != null) {
      for (final step in allSteps) {
        final stagedCols = _stagedTableColumns[step.stagingTableName] ?? [];
        if (stagedCols.contains(orderBy.fieldName)) {
          resolvedOrderTable = step.stagingTableName;
          break;
        }
      }

      if (resolvedOrderTable == null) {
        for (final step in allSteps) {
          if (step.projectedColumns.contains(orderBy.fieldName)) {
            resolvedOrderTable = step.stagingTableName;
            break;
          }
        }
      }

      resolvedOrderTable ??= rootStep.stagingTableName;
    }

    appendModifiers(buffer, targetStagingTable: resolvedOrderTable);
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
