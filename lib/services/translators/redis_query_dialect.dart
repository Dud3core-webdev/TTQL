import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/services/translators/query_dialect_strategy.dart';

/// Strategy for compiling query payloads targeting Redis key stores.
class RedisQueryDialect extends QueryDialectStrategy {
  const RedisQueryDialect();

  @override
  String buildQuery({
    required TtqlPlannedStep step,
    required List<dynamic> Function(String stagingTable, String column) foreignKeyLookup,
    required int maxRows,
  }) {
    final cleanPattern = step.targetTableOrCollection.replaceAll("'", "").replaceAll('"', '').trim();
    final pattern = cleanPattern.isNotEmpty ? cleanPattern : '*';
    return 'KEYS $pattern';
  }
}
