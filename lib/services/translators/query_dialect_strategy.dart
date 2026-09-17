import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/services/translators/mongo_query_dialect.dart';
import 'package:ttql/services/translators/redis_query_dialect.dart';
import 'package:ttql/services/translators/sql_query_dialect.dart';

/// Strategy interface for translating abstract planned execution steps into
/// target-database-specific query strings or JSON payloads.
abstract class QueryDialectStrategy {
  const QueryDialectStrategy();

  /// Compiles [step] into a target-engine executable query payload string.
  String buildQuery({
    required TtqlPlannedStep step,
    required List<dynamic> Function(String stagingTable, String column) foreignKeyLookup,
    required int maxRows,
  });

  /// Factory method to obtain the appropriate [QueryDialectStrategy] for [engineType].
  static QueryDialectStrategy forEngine(DbEngineType engineType) {
    switch (engineType) {
      case DbEngineType.mongodb:
        return const MongoQueryDialect();
      case DbEngineType.redis:
        return const RedisQueryDialect();
      default:
        return const SqlQueryDialect();
    }
  }
}
