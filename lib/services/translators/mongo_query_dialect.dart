import 'dart:convert';
import 'package:ttql/models/ttql_planned_step.dart';
import 'package:ttql/services/translators/mongo_expression_visitor.dart';
import 'package:ttql/services/translators/query_dialect_strategy.dart';

/// Strategy for compiling query payloads targeting MongoDB collections (JSON MQL).
class MongoQueryDialect extends QueryDialectStrategy {
  const MongoQueryDialect();

  @override
  String buildQuery({
    required TtqlPlannedStep step,
    required List<dynamic> Function(String stagingTable, String column) foreignKeyLookup,
    required int maxRows,
  }) {
    final Map<String, dynamic> filter = {};

    for (final dep in step.injectedDependencies) {
      final fkValues = foreignKeyLookup(dep.sourceStagingTable, dep.sourceColumn);
      filter[dep.targetFilterField] = {r'$in': fkValues};
    }

    if (step.wherePredicate != null && !step.wherePredicate!.isRightOperandFieldReference) {
      final translated = MongoExpressionVisitor.translate(step.wherePredicate!.rootExpression);
      if (filter.isNotEmpty) {
        final existing = Map<String, dynamic>.from(filter);
        filter.clear();
        filter[r'$and'] = [existing, translated];
      } else {
        filter.addAll(translated);
      }
    }

    final cleanCollection = step.targetTableOrCollection.replaceAll("'", "").replaceAll('"', '').trim();
    return jsonEncode({
      'collection': cleanCollection,
      'filter': filter,
      'limit': maxRows,
    });
  }
}
