import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_where_predicate_node.dart';

/// AST Node representing individual database query invocation in an execution stage.
class TtqlQueryInvocationNode extends TtqlAstNode {
  final DbEngineType engineType;
  final String connectionId;
  final String targetTableOrCollection;
  final List<String> projectedColumns;
  final TtqlWherePredicateNode? wherePredicate;

  const TtqlQueryInvocationNode({
    required this.engineType,
    required this.connectionId,
    required this.targetTableOrCollection,
    required this.projectedColumns,
    this.wherePredicate,
  });

  List<String> get projectedProperties => projectedColumns;

  @override
  Map<String, dynamic> toJson() {
    return {
      'engineType': engineType.name,
      'connectionId': connectionId,
      'targetTableOrCollection': targetTableOrCollection,
      'projectedColumns': projectedColumns,
      if (wherePredicate != null) 'wherePredicate': wherePredicate!.toJson(),
    };
  }
}
