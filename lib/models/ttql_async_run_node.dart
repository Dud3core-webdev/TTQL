import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';
import 'package:ttql/models/ttql_where_predicate_node.dart';

/// AST Node for parallel execution block `declare asyncRun(() => { ... })`.
class TtqlAsyncRunNode extends TtqlAstNode {
  final List<TtqlQueryInvocationNode> invocations;

  const TtqlAsyncRunNode({
    required this.invocations,
  });

  List<TtqlQueryInvocationNode> get queries => invocations;
  TtqlWherePredicateNode? get wherePredicate => invocations.firstOrNull?.wherePredicate;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'asyncRun',
      'invocations': invocations.map((i) => i.toJson()).toList(),
    };
  }
}
