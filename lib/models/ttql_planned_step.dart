import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_dependency_binding.dart';
import 'package:ttql/models/ttql_where_predicate_node.dart';

/// Represents a single discrete query planned within an execution stage.
class TtqlPlannedStep {
  final String stepId;
  final int stageIndex;
  final String connectionId;
  final DbEngineType engineType;
  final String targetTableOrCollection;
  final List<String> projectedColumns;
  final String stagingTableName;
  final String? entityAlias;
  final TtqlWherePredicateNode? wherePredicate;
  final List<TtqlDependencyBinding> injectedDependencies;
  final String? joinType;
  final String? parentStagingTable;
  final String? parentJoinColumn;
  final String? localJoinColumn;

  const TtqlPlannedStep({
    required this.stepId,
    required this.stageIndex,
    required this.connectionId,
    required this.engineType,
    required this.targetTableOrCollection,
    required this.projectedColumns,
    required this.stagingTableName,
    this.entityAlias,
    this.wherePredicate,
    this.injectedDependencies = const [],
    this.joinType,
    this.parentStagingTable,
    this.parentJoinColumn,
    this.localJoinColumn,
  });

  Map<String, dynamic> toJson() {
    return {
      'stepId': stepId,
      'stageIndex': stageIndex,
      'connectionId': connectionId,
      'engineType': engineType.name,
      'targetTableOrCollection': targetTableOrCollection,
      'projectedColumns': projectedColumns,
      'stagingTableName': stagingTableName,
      'wherePredicate': wherePredicate?.toJson(),
      'injectedDependencies': injectedDependencies.map((d) => d.toJson()).toList(),
      'joinType': joinType,
      'parentStagingTable': parentStagingTable,
      'parentJoinColumn': parentJoinColumn,
      'localJoinColumn': localJoinColumn,
    };
  }
}
