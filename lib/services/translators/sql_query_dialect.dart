import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/services/translators/query_dialect_strategy.dart';
import 'package:ttql/services/translators/sql_expression_visitor.dart';

/// Strategy for compiling query payloads targeting ANSI SQL relational databases
/// (PostgreSQL, MySQL, SQLite, DuckDB, PlanetScale, CockroachDB, YugabyteDB, etc.).
class SqlQueryDialect extends QueryDialectStrategy {
  const SqlQueryDialect();

  @override
  String buildQuery({
    required TtqlPlannedStep step,
    required List<dynamic> Function(String stagingTable, String column) foreignKeyLookup,
    required int maxRows,
  }) {
    final String quote = (step.engineType == DbEngineType.mysql || step.engineType == DbEngineType.planetscale) ? '`' : '"';
    final cleanTable = step.targetTableOrCollection.replaceAll("'", "").replaceAll('"', '').trim();
    final buffer = StringBuffer();
    buffer.write('SELECT ');

    if (step.projectedColumns.isEmpty) {
      buffer.write('*');
    } else {
      buffer.write(step.projectedColumns.map((c) => '$quote$c$quote').join(', '));
    }

    buffer.write(' FROM $quote$cleanTable$quote');

    final List<String> whereClauses = [];

    for (final dep in step.injectedDependencies) {
      final fkValues = foreignKeyLookup(dep.sourceStagingTable, dep.sourceColumn);
      if (fkValues.isEmpty) {
        whereClauses.add('1 = 0');
      } else {
        final formattedValues = fkValues.map((v) => "'${v.toString().replaceAll("'", "''")}'").join(', ');
        whereClauses.add('$quote${dep.targetFilterField}$quote IN ($formattedValues)');
      }
    }

    if (step.wherePredicate != null && !step.wherePredicate!.isRightOperandFieldReference) {
      final result = SqlExpressionVisitor.translate(step.wherePredicate!.rootExpression, step.engineType);
      String rendered = result.sqlClause;
      if (step.engineType == DbEngineType.postgres ||
          step.engineType == DbEngineType.cockroachdb ||
          step.engineType == DbEngineType.yugabytedb) {
        for (int i = 0; i < result.bindings.length; i++) {
          final val = result.bindings[i];
          final formattedVal = val is num ? '$val' : "'${val.toString().replaceAll("'", "''")}'";
          rendered = rendered.replaceAll('\$${i + 1}', formattedVal);
        }
      } else {
        for (final val in result.bindings) {
          final formattedVal = val is num ? '$val' : "'${val.toString().replaceAll("'", "''")}'";
          rendered = rendered.replaceFirst('?', formattedVal);
        }
      }
      whereClauses.add(rendered);
    }

    if (whereClauses.isNotEmpty) {
      buffer.write(' WHERE ${whereClauses.join(' AND ')}');
    }

    buffer.write(' LIMIT $maxRows');
    return buffer.toString();
  }
}
